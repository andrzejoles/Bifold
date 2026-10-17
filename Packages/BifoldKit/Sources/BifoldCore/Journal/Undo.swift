import Darwin
import Foundation

public enum UndoConflict: Sendable, Hashable {
    /// Element do cofnięcia zniknął.
    case missing(VFSPath)
    /// Element zmienił się od czasu operacji (rozmiar, data, inode).
    case modified(VFSPath)
    /// Miejsce, do którego trzeba przywrócić element, jest zajęte.
    case occupied(VFSPath)
    /// Operacji nie da się odwrócić (np. trwałe usunięcie).
    case irreversible(VFSPath)

    public var path: VFSPath {
        switch self {
        case .missing(let p), .modified(let p), .occupied(let p), .irreversible(let p): p
        }
    }

    public var message: String {
        switch self {
        case .missing(let p): L10n.tr("Element nie istnieje: \(p.description)")
        case .modified(let p): L10n.tr("Element zmienił się od czasu operacji: \(p.description)")
        case .occupied(let p): L10n.tr("Miejsce docelowe jest zajęte: \(p.description)")
        case .irreversible(let p): L10n.tr("Operacji nie da się cofnąć: \(p.description)")
        }
    }
}

public enum UndoStepAction: Sendable, Hashable {
    case trash(VFSPath)
    case move(from: VFSPath, to: VFSPath)
    case createDirectory(VFSPath)
    case setAttributes(VFSPath, AttributeChange)
    case setTags(VFSPath, [String])
    case none
}

public struct UndoStep: Sendable, Hashable {
    public var batchID: UUID
    public var original: JournalAction
    public var action: UndoStepAction
    public var conflict: UndoConflict?

    public var preview: PlannedOperation {
        switch action {
        case .trash(let p): PlannedOperation(kind: "trash", source: p, destination: nil, conflict: conflict != nil)
        case let .move(from, to): PlannedOperation(kind: "move", source: from, destination: to, conflict: conflict != nil)
        case .createDirectory(let p): PlannedOperation(kind: "mkdir", source: nil, destination: p, isDirectory: true, conflict: conflict != nil)
        case .setAttributes(let p, _): PlannedOperation(kind: "setAttributes", source: p, destination: nil, conflict: conflict != nil)
        case .setTags(let p, _): PlannedOperation(kind: "setTags", source: p, destination: nil, conflict: conflict != nil)
        case .none: PlannedOperation(kind: "none", source: nil, destination: nil, conflict: true)
        }
    }
}

/// Plan cofnięcia jednej lub wielu partii (kroki w odwrotnej kolejności).
public struct UndoPlan: Sendable, Hashable {
    public var batches: [UUID]
    public var steps: [UndoStep]
    public var conflicts: [UndoConflict] { steps.compactMap(\.conflict) }
    public var isEmpty: Bool { steps.isEmpty }
}

public struct UndoResult: Sendable {
    public var performed: Int
    public var skipped: [UndoConflict]
    public var errors: [(VFSPath, VFSError)]
}

public enum UndoPlanner {
    /// Buduje plan dla partii (podanych od najstarszej). Kroki są w odwrotnej kolejności wykonania.
    /// Sprawdzenie konfliktów uwzględnia skutki wcześniejszych kroków planu (symulacja zajętości).
    public static func plan(for batches: [JournalBatch]) -> UndoPlan {
        var steps: [UndoStep] = []
        var simulated = Simulation()
        for batch in batches.reversed() where batch.isUndoable {
            for entry in batch.entries.reversed() {
                steps.append(step(for: entry, batchID: batch.id, sim: &simulated))
            }
        }
        return UndoPlan(batches: batches.map(\.id), steps: steps)
    }

    /// Stan „po wykonaniu wcześniejszych kroków” — ścieżki zwolnione i zajęte przez plan.
    struct Simulation {
        var freed: Set<VFSPath> = []
        var occupied: Set<VFSPath> = []

        func exists(_ p: VFSPath) -> Bool {
            if occupied.contains(p) { return true }
            if freed.contains(p) || freed.contains(where: { p.isDescendant(of: $0) }) { return false }
            var st = stat()
            return lstat(p.path, &st) == 0
        }

        mutating func free(_ p: VFSPath) { freed.insert(p); occupied.remove(p) }
        mutating func occupy(_ p: VFSPath) { occupied.insert(p); freed.remove(p) }
    }

    static func step(for entry: JournalEntry, batchID: UUID, sim: inout Simulation) -> UndoStep {
        let fs = LocalFS()
        func current(_ p: VFSPath) -> FileItem? { sim.occupied.contains(p) ? nil : (try? fs.itemSync(at: p)) }
        func changed(_ p: VFSPath) -> Bool {
            guard let fp = entry.fingerprint, let item = current(p) else { return false }
            // Data katalogu zmienia się razem z zawartością — porównujemy tylko inode.
            if item.isDirectory { return fp.inode != 0 && fp.inode != item.inode }
            return !fp.matches(item.fingerprint)
        }
        /// Katalog utworzony przez operację można usunąć tylko, jeśli (po wcześniejszych krokach)
        /// jest pusty — inaczej zabralibyśmy do Kosza cudze pliki.
        func hasForeignContents(_ p: VFSPath) -> Bool {
            guard let children = try? fs.listSync(p) else { return false }
            return children.contains { sim.exists($0.path) }
        }

        var action: UndoStepAction = .none
        var conflict: UndoConflict?
        switch entry.action {
        case let .created(path, isDirectory):
            action = .trash(path)
            if !sim.exists(path) { conflict = .missing(path) }
            else if changed(path) || (isDirectory && hasForeignContents(path)) { conflict = .modified(path) }
            if conflict == nil { sim.free(path) }
        case let .copied(_, to):
            action = .trash(to)
            if !sim.exists(to) { conflict = .missing(to) } else if changed(to) { conflict = .modified(to) }
            if conflict == nil { sim.free(to) }
        case let .moved(from, to):
            action = .move(from: to, to: from)
            if !sim.exists(to) { conflict = .missing(to) }
            else if changed(to) { conflict = .modified(to) }
            else if sim.exists(from) { conflict = .occupied(from) }
            if conflict == nil { sim.free(to); sim.occupy(from) }
        case let .trashed(original, trashPath):
            action = .move(from: trashPath, to: original)
            if !sim.exists(trashPath) { conflict = .missing(trashPath) }
            else if sim.exists(original) { conflict = .occupied(original) }
            if conflict == nil { sim.free(trashPath); sim.occupy(original) }
        case let .removedEmptyDirectory(path):
            action = .createDirectory(path)
            if sim.exists(path) { conflict = .occupied(path) } else { sim.occupy(path) }
        case let .attributesChanged(path, before, _):
            action = .setAttributes(path, before)
            if !sim.exists(path) { conflict = .missing(path) }
        case let .tagsChanged(path, before, _):
            action = .setTags(path, before)
            if !sim.exists(path) { conflict = .missing(path) }
        case let .deletedPermanently(path):
            conflict = .irreversible(path)
        }
        return UndoStep(batchID: batchID, original: entry.action, action: action, conflict: conflict)
    }

    /// Wykonuje plan. Kroki z konfliktem są pomijane, chyba że `force` (wtedy wykonywane są te,
    /// które da się wykonać: np. przywrócenie zmienionego pliku).
    public static func execute(_ plan: UndoPlan, journal: OperationJournal?, force: Bool = false) -> UndoResult {
        let fs = LocalFS()
        var result = UndoResult(performed: 0, skipped: [], errors: [])
        for step in plan.steps {
            if let conflict = step.conflict {
                let forcible: Bool = if case .modified = conflict { true } else { false }
                if !(force && forcible) {
                    result.skipped.append(conflict)
                    continue
                }
            }
            do {
                switch step.action {
                case .trash(let p): _ = try fs.trashSync(p)
                case let .move(from, to): try TransferEngine.moveItem(from: from, to: to)
                case .createDirectory(let p):
                    if mkdir(p.path, 0o755) != 0 { throw VFSError.from(errno: errno, path: p) }
                case let .setAttributes(p, change): try fs.setAttributesSync(p, change)
                case let .setTags(p, tags): try fs.setTagsSync(tags, on: p)
                case .none: continue
                }
                result.performed += 1
            } catch {
                result.errors.append((step.action.primaryPath, VFSError.from(error, path: step.action.primaryPath)))
            }
        }
        for id in plan.batches { journal?.markUndone(id) }
        return result
    }
}

extension UndoStepAction {
    var primaryPath: VFSPath {
        switch self {
        case .trash(let p), .createDirectory(let p), .setAttributes(let p, _), .setTags(let p, _): p
        case .move(let from, _): from
        case .none: .root
        }
    }
}
