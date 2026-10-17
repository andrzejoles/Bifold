import Foundation

/// Pojedyncze, szybkie operacje (bez kolejki) zapisywane w dzienniku.
public struct FileOperations: Sendable {
    public let journal: OperationJournal
    let fs = LocalFS()

    public init(journal: OperationJournal) {
        self.journal = journal
    }

    public func makeDirectory(_ path: VFSPath, invoker: Invoker = .user) async throws {
        try await fs.createDirectory(path)
        let batch = journal.beginBatch(title: L10n.tr("Nowy katalog \(path.name)"), invoker: invoker)
        journal.record(.created(path: path, isDirectory: true), fingerprint: try? fs.itemSync(at: path).fingerprint, in: batch)
    }

    public func createFile(_ path: VFSPath, invoker: Invoker = .user) async throws {
        try await fs.createFile(path, contents: Data())
        let batch = journal.beginBatch(title: L10n.tr("Nowy plik \(path.name)"), invoker: invoker)
        journal.record(.created(path: path, isDirectory: false), fingerprint: try? fs.itemSync(at: path).fingerprint, in: batch)
    }

    @discardableResult
    public func rename(_ path: VFSPath, to newName: String, invoker: Invoker = .user) async throws -> VFSPath {
        let target = try await fs.rename(path, to: newName)
        let batch = journal.beginBatch(title: L10n.tr("Zmiana nazwy \(path.name) → \(newName)"), invoker: invoker)
        journal.record(.moved(from: path, to: target), fingerprint: try? fs.itemSync(at: target).fingerprint, in: batch)
        return target
    }

    public func setAttributes(_ paths: [VFSPath], _ change: AttributeChange, invoker: Invoker = .user) async throws {
        guard !change.isEmpty, !paths.isEmpty else { return }
        let batch = journal.beginBatch(title: L10n.tr("Zmiana atrybutów (\(paths.count))"), invoker: invoker)
        for path in paths {
            let item = try fs.itemSync(at: path)
            let before = AttributeChange(
                permissions: change.permissions.map { _ in item.permissions },
                owner: change.owner.map { _ in item.owner },
                group: change.group.map { _ in item.group },
                modified: change.modified.flatMap { _ in item.modified },
                created: change.created.flatMap { _ in item.created },
                hidden: change.hidden.map { _ in item.flags.contains(.hidden) },
                locked: change.locked.map { _ in item.flags.contains(.locked) })
            try fs.setAttributesSync(path, change)
            journal.record(.attributesChanged(path: path, before: before, after: change), in: batch)
        }
    }

    public func setTags(_ paths: [VFSPath], tags: [String], invoker: Invoker = .user) async throws {
        guard !paths.isEmpty else { return }
        let batch = journal.beginBatch(title: L10n.tr("Zmiana tagów (\(paths.count))"), invoker: invoker)
        for path in paths {
            let before = try fs.tagsSync(of: path)
            try fs.setTagsSync(tags, on: path)
            journal.record(.tagsChanged(path: path, before: before, after: tags), in: batch)
        }
    }

    /// Plan cofnięcia ostatniej partii (opcjonalnie tylko pasującej do warunku).
    public func undoPlanForLast(where predicate: (JournalBatch) -> Bool = { _ in true }) -> UndoPlan? {
        journal.lastUndoable(where: predicate).map { UndoPlanner.plan(for: [$0]) }
    }

    /// Plan cofnięcia całej sesji agenta.
    public func undoPlan(forAgentSession sessionID: String) -> UndoPlan {
        UndoPlanner.plan(for: journal.batches(forAgentSession: sessionID))
    }

    public func execute(_ plan: UndoPlan, force: Bool = false) async -> UndoResult {
        let journal = journal
        return (try? await runBlocking { UndoPlanner.execute(plan, journal: journal, force: force) })
            ?? UndoResult(performed: 0, skipped: [], errors: [])
    }
}
