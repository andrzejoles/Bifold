import Foundation
import Testing
@testable import BifoldCore

@MainActor @Suite struct JobQueueTests {
    @Test func copyJobCompletesAndIsJournaled() async throws {
        let tmp = try TempDir()
        try tmp.file("src/a.txt", "a")
        let queue = JobQueue(journal: OperationJournal())
        let job = queue.enqueue(.transfer(TransferRequest(kind: .copy, sources: [tmp.path.appending("src/a.txt")], destinationDirectory: try tmp.dir("dst"))), title: "Kopiuj")
        let state = await queue.wait(for: job)
        #expect(state == .completed)
        #expect(tmp.exists("dst/a.txt"))
        #expect(queue.journal.batches.count == 1)
        #expect(job.progress.filesDone == 1)
    }

    @Test func cancelledLargeCopyLeavesNoPartialFile() async throws {
        let tmp = try TempDir()
        // 64 MB z limitem 8 MB/s → ok. 8 s; anulujemy po chwili.
        let big = tmp.url.appending(path: "src/big.bin")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: big.path, contents: Data(count: 64 * 1024 * 1024))
        let dst = try tmp.dir("dst")
        // Kopia na ten sam wolumin APFS byłaby klonem (bez postępu) — wymuszamy brak klonu
        // przez plik w katalogu tymczasowym na RAM? Nie zawsze możliwe; sprawdzamy oba przypadki.
        let queue = JobQueue(journal: OperationJournal())
        let job = queue.enqueue(.transfer(TransferRequest(kind: .copy, sources: [tmp.path.appending("src/big.bin")], destinationDirectory: dst)), title: "Duży", speedLimit: 8 * 1024 * 1024)
        try await Task.sleep(for: .milliseconds(300))
        queue.cancel(job)
        let state = await queue.wait(for: job)
        let names = try LocalFS().listSync(dst).map(\.name)
        #expect(names.allSatisfy { !$0.contains("bifold-partial") })
        if state == .cancelled {
            #expect(names.isEmpty)
        } else {
            // Klon APFS kończy się natychmiast — wtedy kopia jest kompletna.
            #expect(state == .completed && names == ["big.bin"])
        }
    }

    @Test func pauseAndResumeQueuedJob() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        let queue = JobQueue(journal: OperationJournal())
        let job = queue.enqueue(.trash([tmp.path.appending("a.txt")]), title: "Kosz")
        queue.pause(job)
        try await Task.sleep(for: .milliseconds(200))
        #expect(job.state == .paused)
        #expect(tmp.exists("a.txt"))
        queue.resume(job)
        #expect(await queue.wait(for: job) == .completed)
        #expect(!tmp.exists("a.txt"))
        if case let .trashed(_, trashPath) = queue.journal.batches[0].entries[0].action {
            try? FileManager.default.removeItem(atPath: trashPath.path)
        }
    }
}

@MainActor @Suite struct UndoTests {
    @Test func undoMoveRenameTrash() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        try tmp.file("b.txt", "b")
        try tmp.file("src/c.txt", "c")
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        let queue = JobQueue(journal: journal)

        try await ops.rename(tmp.path.appending("a.txt"), to: "a2.txt")
        _ = await queue.wait(for: queue.enqueue(.trash([tmp.path.appending("b.txt")]), title: "Kosz"))
        _ = await queue.wait(for: queue.enqueue(.transfer(TransferRequest(kind: .move, sources: [tmp.path.appending("src/c.txt")], destinationDirectory: try tmp.dir("dst"))), title: "F6"))
        #expect(tmp.exists("dst/c.txt") && !tmp.exists("b.txt") && tmp.exists("a2.txt"))

        // Cofaj po kolei (jak Cmd+Z).
        for _ in 0..<3 {
            let plan = try #require(ops.undoPlanForLast())
            #expect(plan.conflicts.isEmpty)
            let result = await ops.execute(plan)
            #expect(result.errors.isEmpty && result.skipped.isEmpty)
        }
        #expect(tmp.exists("a.txt") && tmp.exists("b.txt") && tmp.exists("src/c.txt"))
        #expect(!tmp.exists("a2.txt") && !tmp.exists("dst/c.txt"))
        #expect(ops.undoPlanForLast() == nil)
    }

    @Test func undoDetectsConflicts() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        try await ops.rename(tmp.path.appending("a.txt"), to: "b.txt")
        // Ktoś utworzył nowy a.txt — miejsce zajęte.
        try tmp.file("a.txt", "inny")
        let plan = try #require(ops.undoPlanForLast())
        #expect(plan.conflicts == [.occupied(tmp.path.appending("a.txt"))])
        let result = await ops.execute(plan)
        #expect(result.performed == 0 && result.skipped.count == 1)
        #expect(try tmp.read("a.txt") == "inny")
    }

    @Test func undoDetectsModifiedFile() async throws {
        let tmp = try TempDir()
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        try await ops.createFile(tmp.path.appending("nowy.txt"))
        try await Task.sleep(for: .milliseconds(20))
        try Data("zmiana".utf8).write(to: tmp.url.appending(path: "nowy.txt"))
        let plan = try #require(ops.undoPlanForLast())
        #expect(plan.conflicts == [.modified(tmp.path.appending("nowy.txt"))])
        // Wymuszenie: plik idzie do Kosza mimo zmiany.
        let result = await ops.execute(plan, force: true)
        #expect(result.performed == 1)
        #expect(!tmp.exists("nowy.txt"))
    }

    @Test func undoCopyMergeAndAttributes() async throws {
        let tmp = try TempDir()
        try tmp.file("src/d/new.txt", "n")
        try tmp.file("dst/d/existing.txt", "e")
        try tmp.file("f.txt", "f")
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        let queue = JobQueue(journal: journal)
        _ = await queue.wait(for: queue.enqueue(.transfer(TransferRequest(kind: .copy, sources: [tmp.path.appending("src/d")], destinationDirectory: tmp.path.appending("dst"))), title: "F5"))
        try await ops.setAttributes([tmp.path.appending("f.txt")], AttributeChange(permissions: 0o600))
        try await ops.setTags([tmp.path.appending("f.txt")], tags: ["Czerwony"])

        for _ in 0..<3 { _ = await ops.execute(try #require(ops.undoPlanForLast())) }
        #expect(!tmp.exists("dst/d/new.txt") && tmp.exists("dst/d/existing.txt"))
        let f = try LocalFS().itemSync(at: tmp.path.appending("f.txt"))
        #expect(f.permissions == 0o644)
        #expect(try LocalFS().tagsSync(of: f.path).isEmpty)
    }

    @Test func agentSessionUndoRestoresInitialState() async throws {
        let tmp = try TempDir()
        try tmp.file("doc/a.txt", "a")
        try tmp.file("doc/b.txt", "b")
        let snapshot = try treeSnapshot(tmp.url)
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        let queue = JobQueue(journal: journal)
        let agent = Invoker.agent(sessionID: "S1", agentName: "claude")

        try await ops.makeDirectory(tmp.path.appending("doc/archiwum"), invoker: agent)
        _ = await queue.wait(for: queue.enqueue(.transfer(TransferRequest(kind: .move, sources: [tmp.path.appending("doc/a.txt")], destinationDirectory: tmp.path.appending("doc/archiwum"))), title: "m", invoker: agent))
        try await ops.rename(tmp.path.appending("doc/b.txt"), to: "B-final.txt", invoker: agent)
        _ = await queue.wait(for: queue.enqueue(.transfer(TransferRequest(kind: .copy, sources: [tmp.path.appending("doc/B-final.txt")], destinationDirectory: tmp.path.appending("doc/archiwum"))), title: "c", invoker: agent))
        // Operacja użytkownika w tym czasie nie jest cofana.
        try await ops.makeDirectory(tmp.path.appending("user-dir"))

        let plan = ops.undoPlan(forAgentSession: "S1")
        #expect(plan.conflicts.isEmpty)
        let result = await ops.execute(plan)
        #expect(result.errors.isEmpty)
        try FileManager.default.removeItem(at: tmp.url.appending(path: "user-dir"))
        #expect(try treeSnapshot(tmp.url) == snapshot)
    }

    @Test func journalPersistsToJSONL() async throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "journal/ops.jsonl")
        let journal = OperationJournal(fileURL: file)
        let ops = FileOperations(journal: journal)
        try await ops.makeDirectory(tmp.path.appending("x"), invoker: .agent(sessionID: "S", agentName: "codex"))
        journal.flush()
        let reloaded = OperationJournal(fileURL: file)
        #expect(reloaded.batches.count == 1)
        #expect(reloaded.batches[0].invoker == .agent(sessionID: "S", agentName: "codex"))
        #expect(reloaded.batches[0].entries.count == 1)
    }

    func treeSnapshot(_ url: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(atPath: url.path)!
        for case let rel as String in e {
            let full = url.appending(path: rel)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
            out[rel] = isDir.boolValue ? "<dir>" : (try? String(contentsOf: full, encoding: .utf8)) ?? "?"
        }
        return out
    }
}
