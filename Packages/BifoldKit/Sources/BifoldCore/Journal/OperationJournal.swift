import Foundation
import Synchronization

/// Kto wywołał operację.
public enum Invoker: Codable, Sendable, Hashable {
    case user
    case agent(sessionID: String, agentName: String)

    public var isAgent: Bool { if case .agent = self { true } else { false } }

    public var agentSessionID: String? {
        if case let .agent(id, _) = self { id } else { nil }
    }
}

/// Zmiana zapisana w dzienniku razem z danymi potrzebnymi do jej odwrócenia.
public enum JournalAction: Codable, Sendable, Hashable {
    /// Utworzono pusty plik lub katalog. Odwrotność: do Kosza.
    case created(path: VFSPath, isDirectory: Bool)
    /// Skopiowano (`to` nie istniało wcześniej). Odwrotność: `to` do Kosza.
    case copied(from: VFSPath, to: VFSPath)
    /// Przeniesiono lub zmieniono nazwę. Odwrotność: przeniesienie z powrotem.
    case moved(from: VFSPath, to: VFSPath)
    /// Przeniesiono do Kosza. Odwrotność: przywrócenie z Kosza.
    case trashed(original: VFSPath, trashPath: VFSPath)
    /// Usunięto pusty katalog źródłowy po przeniesieniu zawartości. Odwrotność: utworzenie.
    case removedEmptyDirectory(path: VFSPath)
    /// Zmieniono atrybuty. Odwrotność: przywrócenie poprzednich.
    case attributesChanged(path: VFSPath, before: AttributeChange, after: AttributeChange)
    /// Zmieniono tagi Findera. Odwrotność: przywrócenie poprzednich.
    case tagsChanged(path: VFSPath, before: [String], after: [String])
    /// Trwałe usunięcie — nieodwracalne, zapisywane dla porządku.
    case deletedPermanently(path: VFSPath)

    public var isUndoable: Bool {
        if case .deletedPermanently = self { false } else { true }
    }
}

public struct JournalEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var action: JournalAction
    /// Odcisk elementu wynikowego tuż po operacji (do wykrywania późniejszych zmian).
    public var fingerprint: Fingerprint?

    public init(id: UUID = UUID(), date: Date = Date(), action: JournalAction, fingerprint: Fingerprint? = nil) {
        self.id = id
        self.date = date
        self.action = action
        self.fingerprint = fingerprint
    }
}

/// Wpisy jednej komendy (np. jedno F6 na 30 plikach) — cofane razem.
public struct JournalBatch: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var invoker: Invoker
    public var entries: [JournalEntry]
    public var undone: Bool

    public var isUndoable: Bool { !undone && entries.contains { $0.action.isUndoable } }
}

/// Dziennik operacji zmieniających pliki. Trzyma partie w pamięci i dopisuje każdą zmianę
/// do pliku JSONL od razu (odporność na awarię).
public final class OperationJournal: Sendable {
    private struct State {
        var batches: [JournalBatch] = []
        var index: [UUID: Int] = [:]
    }

    private enum Line: Codable {
        case batch(id: UUID, title: String, date: Date, invoker: Invoker)
        case entry(batch: UUID, entry: JournalEntry)
        case undone(batch: UUID)
    }

    private let state = Mutex(State())
    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "bifold.journal")
    public let maxBatchesInMemory: Int

    /// - Parameter fileURL: plik JSONL; `nil` = tylko w pamięci (testy).
    public init(fileURL: URL? = nil, maxBatchesInMemory: Int = 1000) {
        self.fileURL = fileURL
        self.maxBatchesInMemory = maxBatchesInMemory
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            load(from: fileURL)
        }
    }

    public var batches: [JournalBatch] { state.withLock { $0.batches } }

    public func batch(_ id: UUID) -> JournalBatch? {
        state.withLock { s in s.index[id].map { s.batches[$0] } }
    }

    @discardableResult
    public func beginBatch(title: String, invoker: Invoker, id: UUID = UUID()) -> UUID {
        let batch = JournalBatch(id: id, title: title, date: Date(), invoker: invoker, entries: [], undone: false)
        state.withLock { s in
            s.batches.append(batch)
            if s.batches.count > maxBatchesInMemory {
                s.batches.removeFirst(s.batches.count - maxBatchesInMemory)
            }
            s.index = Dictionary(uniqueKeysWithValues: s.batches.enumerated().map { ($1.id, $0) })
        }
        append(.batch(id: id, title: title, date: batch.date, invoker: invoker))
        return id
    }

    public func record(_ action: JournalAction, fingerprint: Fingerprint? = nil, in batchID: UUID) {
        let entry = JournalEntry(action: action, fingerprint: fingerprint)
        state.withLock { s in
            guard let i = s.index[batchID] else { return }
            s.batches[i].entries.append(entry)
        }
        append(.entry(batch: batchID, entry: entry))
    }

    public func markUndone(_ batchID: UUID) {
        state.withLock { s in
            guard let i = s.index[batchID] else { return }
            s.batches[i].undone = true
        }
        append(.undone(batch: batchID))
    }

    /// Ostatnia partia, którą da się cofnąć (opcjonalnie tylko danego wywołującego).
    public func lastUndoable(where predicate: (JournalBatch) -> Bool = { _ in true }) -> JournalBatch? {
        state.withLock { $0.batches.last { $0.isUndoable && predicate($0) } }
    }

    /// Wszystkie niecofnięte partie sesji agenta, od najstarszej.
    public func batches(forAgentSession sessionID: String) -> [JournalBatch] {
        state.withLock { $0.batches.filter { $0.invoker.agentSessionID == sessionID && $0.isUndoable } }
    }

    /// Czeka, aż wszystkie wpisy trafią na dysk.
    public func flush() {
        writeQueue.sync {}
    }

    private func append(_ line: Line) {
        guard let fileURL else { return }
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(line) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }

    private func load(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var s = State()
        for line in data.split(separator: 0x0A) {
            guard let parsed = try? decoder.decode(Line.self, from: Data(line)) else { continue }
            switch parsed {
            case let .batch(id, title, date, invoker):
                s.index[id] = s.batches.count
                s.batches.append(JournalBatch(id: id, title: title, date: date, invoker: invoker, entries: [], undone: false))
            case let .entry(batch, entry):
                if let i = s.index[batch] { s.batches[i].entries.append(entry) }
            case let .undone(batch):
                if let i = s.index[batch] { s.batches[i].undone = true }
            }
        }
        if s.batches.count > maxBatchesInMemory {
            s.batches.removeFirst(s.batches.count - maxBatchesInMemory)
            s.index = Dictionary(uniqueKeysWithValues: s.batches.enumerated().map { ($1.id, $0) })
        }
        state.withLock { $0 = s }
    }
}
