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
        // Zadanie blokujące kolejkę (konflikt czeka na decyzję) — inaczej wątek roboczy mógłby
        // wykonać Kosz, zanim test zdąży wstrzymać zadanie.
        try tmp.file("src/b.txt", "b")
        try tmp.file("dst/b.txt", "b")
        let blocker = BlockingDelegate()
        let first = queue.enqueue(.transfer(TransferRequest(kind: .copy, sources: [tmp.path.appending("src/b.txt")], destinationDirectory: tmp.path.appending("dst"))),
                                  title: "blokada", delegate: blocker)
        let job = queue.enqueue(.trash([tmp.path.appending("a.txt")]), title: "Kosz")
        queue.pause(job)
        for _ in 0..<200 where !blocker.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        blocker.release(ConflictDecision(.skip))
        _ = await queue.wait(for: first)
        try await Task.sleep(for: .milliseconds(200))
        #expect(job.state == .paused)
        #expect(tmp.exists("a.txt"))
        queue.resume(job)
        #expect(await queue.wait(for: job) == .completed)
        #expect(!tmp.exists("a.txt"))
        let batchID = try #require(job.batchID)
        if case let .trashed(_, trashPath) = try #require(queue.journal.batch(batchID)).entries[0].action {
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

/// Delegat, który wstrzymuje zadanie na pierwszym konflikcie, dopóki test go nie zwolni.
final class BlockingDelegate: TransferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ConflictDecision, Never>?
    private var waiting = false

    var isWaiting: Bool { lock.withLock { waiting } }

    func resolveConflict(_ conflict: FileConflict) async -> ConflictDecision {
        await withCheckedContinuation { c in
            lock.withLock {
                continuation = c
                waiting = true
            }
        }
    }

    func release(_ decision: ConflictDecision) {
        let c = lock.withLock { () -> CheckedContinuation<ConflictDecision, Never>? in
            defer { continuation = nil; waiting = false }
            return continuation
        }
        c?.resume(returning: decision)
    }

    func resolveError(path: VFSPath, error: VFSError) async -> ErrorDecision { .skip }
}

@MainActor @Suite struct JournalFixesTests {
    /// Cmd+Z w trakcie zadania nie może cofać jego partii (jest już w niej wpis o pierwszym pliku).
    @Test func runningJobBatchIsNotUndoable() async throws {
        let tmp = try TempDir()
        try tmp.file("src/a.txt", "a")
        try tmp.file("src/b.txt", "b")
        try tmp.file("dst/b.txt", "stary")
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        let queue = JobQueue(journal: journal)
        try await ops.makeDirectory(tmp.path.appending("wczesniej"))
        let delegate = BlockingDelegate()
        let job = queue.enqueue(.transfer(TransferRequest(kind: .copy, sources: [tmp.path.appending("src/a.txt"), tmp.path.appending("src/b.txt")],
                                                          destinationDirectory: tmp.path.appending("dst"))), title: "F5", delegate: delegate)
        for _ in 0..<100 where !delegate.isWaiting { try await Task.sleep(for: .milliseconds(20)) }
        #expect(delegate.isWaiting)
        let runningID = try #require(job.batchID)
        let running = try #require(journal.batch(runningID))
        #expect(running.entries.count == 1)
        // Proponowana jest wcześniejsza, zakończona partia — nie trwające kopiowanie.
        #expect(journal.lastUndoable()?.title != "F5")
        #expect(ops.undoPlanForLast()?.batches != [running.id])
        delegate.release(ConflictDecision(.skip))
        #expect(await queue.wait(for: job) == .completed)
        #expect(journal.lastUndoable()?.id == running.id)
    }

    /// Plan cofnięcia 20 000 wpisów: symulacja zajętości bez przeglądania całego zbioru dla każdej ścieżki.
    @Test func undoPlanForLargeBatchIsFast() throws {
        let tmp = try TempDir()
        let dir = try tmp.dir("duzo")
        let count = 20_000
        for i in 0..<count {
            let fd = open(dir.path + "/f\(i)", O_WRONLY | O_CREAT | O_EXCL, 0o644)
            close(fd)
        }
        let journal = OperationJournal()
        let batch = journal.beginBatch(title: "duża kopia", invoker: .user)
        for i in 0..<count { journal.record(.copied(from: .local("/zrodlo/f\(i)"), to: dir.appending("f\(i)")), in: batch) }
        let start = ContinuousClock.now
        let plan = try #require(FileOperations(journal: journal).undoPlanForLast())
        let elapsed = ContinuousClock.now - start
        #expect(plan.steps.count == count && plan.conflicts.isEmpty)
        #expect(elapsed < .seconds(1), "plan trwał \(elapsed)")
    }

    /// Częściowe cofnięcie: partia nie jest oznaczana jako cofnięta; wykonane wpisy tak, a reszta zostaje.
    @Test func partialUndoMarksOnlyPerformedEntries() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        try tmp.file("b.txt", "b")
        let journal = OperationJournal()
        let batch = journal.beginBatch(title: "zmiana nazw", invoker: .user)
        try LocalFS().moveSync(tmp.path.appending("a.txt"), to: tmp.path.appending("a2.txt"))
        journal.record(.moved(from: tmp.path.appending("a.txt"), to: tmp.path.appending("a2.txt")), in: batch)
        try LocalFS().moveSync(tmp.path.appending("b.txt"), to: tmp.path.appending("b2.txt"))
        journal.record(.moved(from: tmp.path.appending("b.txt"), to: tmp.path.appending("b2.txt")), in: batch)
        try tmp.file("a.txt", "zajmuje")

        let ops = FileOperations(journal: journal)
        let first = await ops.execute(try #require(ops.undoPlanForLast()))
        #expect(first.performed == 1 && first.skipped == [.occupied(tmp.path.appending("a.txt"))])
        #expect(tmp.exists("b.txt"))
        // Partia nadal do cofnięcia, ale tylko z pozostałym krokiem.
        try FileManager.default.removeItem(at: tmp.url.appending(path: "a.txt"))
        let second = try #require(ops.undoPlanForLast())
        #expect(second.steps.map(\.action) == [.move(from: tmp.path.appending("a2.txt"), to: tmp.path.appending("a.txt"))])
        let result = await ops.execute(second)
        #expect(result.performed == 1 && result.skipped.isEmpty)
        #expect(try tmp.read("a.txt") == "a")
        #expect(ops.undoPlanForLast() == nil)
    }

    /// Dziennik: przy starcie przycięty do ostatnich partii; częściowe cofnięcie przetrwa ponowne wczytanie.
    @Test func journalIsCompactedOnLoad() async throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "journal/ops.jsonl")
        let journal = OperationJournal(fileURL: file, maxBatchesInMemory: 3)
        for i in 0..<5 {
            let b = journal.beginBatch(title: "p\(i)", invoker: .user)
            journal.record(.created(path: tmp.path.appending("x\(i)"), isDirectory: true), in: b)
        }
        let last = try #require(journal.batches.last)
        journal.markUndone(entries: [last.entries[0].id], in: last.id)
        journal.flush()
        #expect(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count == 11)
        let reloaded = OperationJournal(fileURL: file, maxBatchesInMemory: 3)
        #expect(reloaded.batches.map(\.title) == ["p2", "p3", "p4"])
        #expect(reloaded.batches[2].entries[0].undone)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 7)
        #expect(try tmp.names("journal") == ["ops.jsonl"])
        // Dopisywanie po przycięciu trafia do nowego pliku.
        reloaded.beginBatch(title: "p5", invoker: .user)
        reloaded.flush()
        #expect(OperationJournal(fileURL: file, maxBatchesInMemory: 10).batches.map(\.title) == ["p2", "p3", "p4", "p5"])
    }

    /// Błąd zapisu nie może zastąpić całego dziennika jednym wierszem.
    @Test func unwritableJournalIsNotReplaced() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "ops.jsonl")
        let journal = OperationJournal(fileURL: file)
        journal.beginBatch(title: "pierwsza", invoker: .user)
        journal.flush()
        chmod(file.path, 0o400)
        defer { chmod(file.path, 0o600) }
        let readOnly = OperationJournal(fileURL: file)
        readOnly.beginBatch(title: "druga", invoker: .user)
        readOnly.flush()
        chmod(file.path, 0o600)
        #expect(OperationJournal(fileURL: file).batches.map(\.title) == ["pierwsza"])
    }
}
