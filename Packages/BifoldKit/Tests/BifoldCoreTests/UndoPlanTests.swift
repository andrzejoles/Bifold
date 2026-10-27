import Foundation
import Testing
@testable import BifoldCore

/// Plan i wykonanie cofania: brakujące elementy, symulacja wcześniejszych kroków.
@Suite struct UndoPlanTests {
    static func transfer(_ kind: TransferKind, _ sources: [VFSPath], to dir: VFSPath, journal: OperationJournal, title: String) throws -> JournalBatch {
        let batch = journal.beginBatch(title: title, invoker: .agent(sessionID: "s1", agentName: "test"))
        try TransferEngine(request: TransferRequest(kind: kind, sources: sources, destinationDirectory: dir), journal: journal, batchID: batch).run()
        return try #require(journal.batch(batch))
    }

    /// Element w Koszu odłączonego woluminu (katalog nadrzędny nie istnieje) — partia zostaje cofalna,
    /// bo po podłączeniu woluminu da się go przywrócić.
    @Test func missingItemOnDetachedVolumeKeepsBatchUndoable() throws {
        let tmp = try TempDir()
        let journal = OperationJournal()
        let batch = journal.beginBatch(title: "F8", invoker: .user)
        let trashPath = tmp.path.appending("Volumes/USB/.Trashes/501/a.txt")
        journal.record(.trashed(original: tmp.path.appending("a.txt"), trashPath: trashPath), in: batch)
        let plan = UndoPlanner.plan(for: [try #require(journal.batch(batch))])
        #expect(plan.conflicts == [.missing(trashPath)])
        let result = UndoPlanner.execute(plan, journal: journal)
        #expect(result.performed == 0)
        #expect(journal.batch(batch)?.undone == false)
        #expect(journal.batch(batch)?.pendingEntries.count == 1)
        #expect(journal.lastUndoable()?.id == batch)

        // Kosz istnieje, elementu w nim nie ma (opróżniony) — krok liczy się jak wykonany (D55).
        try tmp.dir("Kosz")
        let emptied = journal.beginBatch(title: "F8 2", invoker: .user)
        journal.record(.trashed(original: tmp.path.appending("b.txt"), trashPath: tmp.path.appending("Kosz/b.txt")), in: emptied)
        _ = UndoPlanner.execute(UndoPlanner.plan(for: [try #require(journal.batch(emptied))]), journal: journal)
        #expect(journal.batch(emptied)?.undone == true)
    }

    /// Agent kopiuje katalog X (partia 1), przenosi do niego plik i katalog (partie 2, 3), a jeden plik
    /// z kopii trafia do „Kosza” (partia 4). Cofnięcie sesji: kroki późniejszych partii przywracają stan
    /// X sprzed nich, więc kopia nie jest „zmieniona”.
    @Test func sessionUndoCountsCopiedDirectoryAfterEarlierSteps() throws {
        let tmp = try TempDir()
        try tmp.file("src/X/a.txt", "a")
        try tmp.file("src/X/sub/b.txt", "b")
        try tmp.file("f.txt", "f")
        try tmp.file("D/1.txt", "1")
        try tmp.file("D/2.txt", "2")
        try tmp.dir("dst")
        try tmp.dir("kosz")
        let journal = OperationJournal()
        let b1 = try Self.transfer(.copy, [tmp.path.appending("src/X")], to: tmp.path.appending("dst"), journal: journal, title: "kopia")
        #expect(b1.entries.first?.itemCount == 3)
        let x = tmp.path.appending("dst/X")
        let b2 = try Self.transfer(.move, [tmp.path.appending("f.txt")], to: x, journal: journal, title: "plik do X")
        let b3 = try Self.transfer(.move, [tmp.path.appending("D")], to: x, journal: journal, title: "katalog do X")
        let b4id = journal.beginBatch(title: "do kosza", invoker: .agent(sessionID: "s1", agentName: "test"))
        try FileManager.default.moveItem(atPath: x.appending("a.txt").path, toPath: tmp.url.appending(path: "kosz/a.txt").path)
        journal.record(.trashed(original: x.appending("a.txt"), trashPath: tmp.path.appending("kosz/a.txt")), in: b4id)
        let b4 = try #require(journal.batch(b4id))

        let plan = UndoPlanner.plan(for: [b1, b2, b3, b4])
        #expect(plan.conflicts.isEmpty, "\(plan.conflicts)")
        #expect(plan.steps.last?.action == .trash(x))

        // Cudzy plik dopisany do X (spoza planu) dalej jest konfliktem.
        try tmp.file("dst/X/obcy.txt", "?")
        #expect(UndoPlanner.plan(for: [b1, b2, b3, b4]).conflicts == [.modified(x)])
    }
}
