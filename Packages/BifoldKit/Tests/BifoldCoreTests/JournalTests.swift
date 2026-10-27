import Foundation
import Testing
@testable import BifoldCore

/// Dziennik operacji: przycinanie w pamięci i na dysku.
@Suite struct JournalTests {
    static func record(_ count: Int, in batch: UUID, of journal: OperationJournal, prefix: String) {
        for i in 0..<count { journal.record(.created(path: .local("/x/\(prefix)-\(i)"), isDirectory: false), in: batch) }
    }

    /// Trwające zadanie (np. F6 na wielu plikach) + nowa partia (F7): partia zadania nie może zniknąć,
    /// inaczej dalsze wpisy i `endBatch` trafiają w próżnię, a operacji nie da się cofnąć.
    @Test func runningBatchSurvivesInMemoryTrimming() {
        let journal = OperationJournal(maxEntries: 50)
        let running = journal.beginBatch(title: "F6", invoker: .user, finished: false)
        Self.record(60, in: running, of: journal, prefix: "a")
        journal.beginBatch(title: "F7", invoker: .user)
        Self.record(60, in: running, of: journal, prefix: "b")
        journal.beginBatch(title: "F7 2", invoker: .user)
        #expect(journal.batch(running)?.entries.count == 120)
        journal.endBatch(running)
        #expect(journal.batch(running)?.isUndoable == true)
        #expect(journal.lastUndoable { $0.id == running } != nil)
    }

    /// Limit liczby partii też nie usuwa trwającego zadania.
    @Test func runningBatchSurvivesBatchCountLimit() {
        let journal = OperationJournal(maxBatchesInMemory: 2)
        let running = journal.beginBatch(title: "kopiowanie", invoker: .user, finished: false)
        for i in 0..<5 { journal.beginBatch(title: "p\(i)", invoker: .user) }
        #expect(journal.batches.first?.id == running)
        #expect(journal.batches.map(\.title) == ["kopiowanie", "p3", "p4"])
        journal.record(.created(path: .local("/x/y"), isDirectory: false), in: running)
        journal.endBatch(running)
        #expect(journal.batch(running)?.isUndoable == true)
    }

    /// Zakończona operacja ponad limit wpisów nie znika po dowolnej małej operacji.
    @Test func newestFinishedBatchSurvivesNextSmallOperation() {
        let journal = OperationJournal(maxEntries: 50)
        let big = journal.beginBatch(title: "duża", invoker: .user)
        Self.record(500, in: big, of: journal, prefix: "a")
        let small = journal.beginBatch(title: "F7", invoker: .user)
        Self.record(1, in: small, of: journal, prefix: "b")
        #expect(journal.batch(big)?.entries.count == 500)
        #expect(journal.lastUndoable { $0.id == big } != nil)
        // Dopiero kolejna partia (duża przestaje być najnowszą zakończoną) może ją usunąć.
        journal.beginBatch(title: "F7 2", invoker: .user)
        #expect(journal.batch(big) == nil)
        #expect(journal.batches.map(\.title) == ["F7", "F7 2"])
    }

    /// Przycięcie przy starcie się nie udało (katalog bez prawa zapisu), a ostatni wiersz był ucięty:
    /// musi dostać znak nowej linii, inaczej skleja się z następnym dopisanym wierszem.
    @Test func truncatedLineIsTerminatedWhenCompactionFails() throws {
        let tmp = try TempDir()
        let dir = try tmp.dir("dziennik")
        let file = URL(filePath: dir.path).appending(path: "ops.jsonl")
        let first = OperationJournal(fileURL: file)
        first.beginBatch(title: "p1", invoker: .user)
        first.beginBatch(title: "p2", invoker: .user)
        first.flush()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"batch\":{\"id\":\"".utf8))
        try handle.close()

        // Nowy plik obok nie powstanie — przycięcie (limit 1 partii) się nie uda.
        #expect(chmod(dir.path, 0o500) == 0)
        defer { chmod(dir.path, 0o700) }
        let second = OperationJournal(fileURL: file, maxBatchesInMemory: 1)
        #expect(second.batches.map(\.title) == ["p2"])
        second.beginBatch(title: "p3", invoker: .user)
        second.flush()
        chmod(dir.path, 0o700)
        #expect(OperationJournal(fileURL: file).batches.map(\.title) == ["p1", "p2", "p3"])
        #expect(try tmp.names("dziennik") == ["ops.jsonl"])
    }
}
