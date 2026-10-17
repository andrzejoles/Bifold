import Foundation
import Testing
@testable import BifoldCore

/// Delegat testowy: zapisuje konflikty i zwraca zadaną decyzję.
final class RecordingDelegate: TransferDelegate, @unchecked Sendable {
    let lock = NSLock()
    var conflicts: [FileConflict] = []
    let decision: ConflictDecision
    let errorDecision: ErrorDecision

    init(_ decision: ConflictDecision, error: ErrorDecision = .skip) {
        self.decision = decision
        self.errorDecision = error
    }

    func resolveConflict(_ conflict: FileConflict) async -> ConflictDecision {
        lock.withLock { conflicts.append(conflict) }
        return decision
    }

    func resolveError(path: VFSPath, error: VFSError) async -> ErrorDecision { errorDecision }
}

@Suite struct TransferEngineTests {
    func run(_ request: TransferRequest, delegate: (any TransferDelegate)? = nil, journal: OperationJournal? = nil) throws -> TransferEngine {
        let batch = journal?.beginBatch(title: "t", invoker: .user)
        let engine = TransferEngine(request: request, delegate: delegate, journal: journal, batchID: batch)
        try engine.run()
        return engine
    }

    @Test func copiesTreePreservingMetadata() throws {
        let tmp = try TempDir()
        let date = Date(timeIntervalSince1970: 1_400_000_000)
        try tmp.file("src/a.txt", "AAA", modified: date)
        try tmp.file("src/sub/b.txt", "BB")
        setxattr(tmp.url.appending(path: "src/a.txt").path, "pl.test.attr", "wartosc", 7, 0, 0)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: tmp.url.appending(path: "src/sub").path)
        let dst = try tmp.dir("dst")

        let journal = OperationJournal()
        let engine = try run(TransferRequest(kind: .copy, sources: [tmp.path.appending("src")], destinationDirectory: dst), journal: journal)
        #expect(engine.errors.isEmpty)
        #expect(try tmp.read("dst/src/a.txt") == "AAA")
        #expect(try tmp.read("dst/src/sub/b.txt") == "BB")
        #expect(tmp.exists("src/a.txt"))
        let copied = try LocalFS().itemSync(at: dst.appending("src/a.txt"))
        #expect(copied.modified == date)
        var buf = [CChar](repeating: 0, count: 32)
        #expect(getxattr(copied.path.path, "pl.test.attr", &buf, 32, 0, 0) == 7)
        #expect(try LocalFS().itemSync(at: dst.appending("src/sub")).modified == date)
        // Jeden wpis dla całego nowego poddrzewa.
        #expect(journal.batches[0].entries.map(\.action) == [.copied(from: tmp.path.appending("src"), to: dst.appending("src"))])
        // Brak plików tymczasowych.
        #expect(try LocalFS().listSync(dst.appending("src")).allSatisfy { !$0.name.contains("bifold-partial") })
    }

    @Test func planCountsAndConflicts() throws {
        let tmp = try TempDir()
        try tmp.file("src/a.txt", "12345")
        try tmp.file("src/d/b.txt", "123")
        try tmp.file("one.txt", "1")
        try tmp.file("dst/one.txt", "old")
        try tmp.file("dst/d/b.txt", "old")
        let plan = try TransferEngine.plan(TransferRequest(
            kind: .copy, sources: [tmp.path.appending("src/a.txt"), tmp.path.appending("src/d"), tmp.path.appending("one.txt")],
            destinationDirectory: tmp.path.appending("dst")))
        #expect(plan.totalBytes == 9)
        #expect(plan.fileCount == 3)
        #expect(Set(plan.conflicts) == [tmp.path.appending("dst/one.txt"), tmp.path.appending("dst/d/b.txt")])
        #expect(plan.operations.count == 3)
    }

    @Test func refusesCopyIntoItself() throws {
        let tmp = try TempDir()
        try tmp.file("a/b/c.txt")
        #expect(throws: VFSError.destinationInsideSource(tmp.path.appending("a"))) {
            try TransferEngine.plan(TransferRequest(kind: .copy, sources: [tmp.path.appending("a")], destinationDirectory: tmp.path.appending("a/b")))
        }
    }

    @Test func copyOntoItselfCreatesNumberedCopy() throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "x")
        _ = try run(TransferRequest(kind: .copy, sources: [tmp.path.appending("a.txt")], destinationDirectory: tmp.path))
        #expect(tmp.exists("a (2).txt"))
    }

    @Test func conflictResolutions() throws {
        let tmp = try TempDir()
        try tmp.file("src/x.txt", "nowy", modified: Date(timeIntervalSince1970: 2_000_000_000))
        let dst = tmp.path.appending("dst")
        let req = TransferRequest(kind: .copy, sources: [tmp.path.appending("src/x.txt")], destinationDirectory: dst)

        try tmp.file("dst/x.txt", "stary")
        let skip = RecordingDelegate(ConflictDecision(.skip))
        _ = try run(req, delegate: skip)
        #expect(try tmp.read("dst/x.txt") == "stary")
        #expect(skip.conflicts.count == 1)

        _ = try run(req, delegate: RecordingDelegate(ConflictDecision(.rename)))
        #expect(try tmp.read("dst/x (2).txt") == "nowy")

        let journal = OperationJournal()
        _ = try run(req, delegate: RecordingDelegate(ConflictDecision(.overwrite)), journal: journal)
        #expect(try tmp.read("dst/x.txt") == "nowy")
        // Nadpisany plik trafił do Kosza i jest w dzienniku.
        guard case let .trashed(original, trashPath) = journal.batches[0].entries[0].action else {
            Issue.record("brak wpisu trashed"); return
        }
        #expect(original == dst.appending("x.txt"))
        #expect(FileManager.default.fileExists(atPath: trashPath.path))
        try? FileManager.default.removeItem(atPath: trashPath.path)

        // overwriteOlder: docelowy jest nowszy → pominięcie.
        try tmp.file("src/y.txt", "starszy", modified: Date(timeIntervalSince1970: 1_000_000_000))
        try tmp.file("dst/y.txt", "nowszy", modified: Date(timeIntervalSince1970: 1_500_000_000))
        _ = try run(TransferRequest(kind: .copy, sources: [tmp.path.appending("src/y.txt")], destinationDirectory: dst), delegate: RecordingDelegate(ConflictDecision(.overwriteOlder)))
        #expect(try tmp.read("dst/y.txt") == "nowszy")
    }

    @Test func applyToAllAsksOnce() throws {
        let tmp = try TempDir()
        for i in 0..<5 {
            try tmp.file("src/\(i).txt", "new")
            try tmp.file("dst/\(i).txt", "old")
        }
        let delegate = RecordingDelegate(ConflictDecision(.overwrite, applyToAll: true))
        let sources = (0..<5).map { tmp.path.appending("src/\($0).txt") }
        _ = try run(TransferRequest(kind: .copy, sources: sources, destinationDirectory: tmp.path.appending("dst")), delegate: delegate)
        #expect(delegate.conflicts.count == 1)
        #expect(try (0..<5).allSatisfy { try tmp.read("dst/\($0).txt") == "new" })
    }

    @Test func moveSameVolumeAndMerge() throws {
        let tmp = try TempDir()
        try tmp.file("src/d/a.txt", "a")
        try tmp.file("src/d/b.txt", "b")
        try tmp.file("dst/d/old.txt", "o")
        let journal = OperationJournal()
        _ = try run(TransferRequest(kind: .move, sources: [tmp.path.appending("src/d")], destinationDirectory: tmp.path.appending("dst")), journal: journal)
        #expect(!tmp.exists("src/d"))
        #expect(tmp.exists("dst/d/a.txt") && tmp.exists("dst/d/b.txt") && tmp.exists("dst/d/old.txt"))
        let actions = journal.batches[0].entries.map(\.action)
        #expect(actions.contains(.removedEmptyDirectory(path: tmp.path.appending("src/d"))))
        #expect(actions.filter { if case .moved = $0 { true } else { false } }.count == 2)
    }

    @Test func moveWithRename() throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        _ = try run(TransferRequest(kind: .move, sources: [tmp.path.appending("a.txt")], destinationDirectory: tmp.path, newName: "b.txt"))
        #expect(!tmp.exists("a.txt") && tmp.exists("b.txt"))
    }

    @Test func errorsAreCollectedAndSkipped() throws {
        let tmp = try TempDir()
        try tmp.file("src/ok.txt", "ok")
        try tmp.file("src/secret.txt", "s")
        chmod(tmp.url.appending(path: "src/secret.txt").path, 0o000)
        defer { chmod(tmp.url.appending(path: "src/secret.txt").path, 0o644) }
        let dst = try tmp.dir("dst")
        let engine = try run(TransferRequest(kind: .copy, sources: [tmp.path.appending("src/secret.txt"), tmp.path.appending("src/ok.txt")], destinationDirectory: dst),
                             delegate: RecordingDelegate(ConflictDecision(.skip), error: .skip))
        #expect(engine.errors.count == 1)
        #expect(tmp.exists("dst/ok.txt"))
        #expect(try LocalFS().listSync(dst).map(\.name) == ["ok.txt"])
    }

    @Test func progressReachesTotal() throws {
        let tmp = try TempDir()
        try tmp.file("src/a.bin", String(repeating: "x", count: 100_000))
        let last = Mutexed(TransferProgress())
        let engine = TransferEngine(
            request: TransferRequest(kind: .copy, sources: [tmp.path.appending("src")], destinationDirectory: try tmp.dir("dst")),
            onProgress: { p in last.set(p) })
        try engine.run()
        #expect(last.get().bytesDone == 100_000)
        #expect(last.get().bytesTotal == 100_000)
        #expect(last.get().filesDone == 1)
    }
}

final class Mutexed<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}

/// Duży plik na innym woluminie wymusza prawdziwe kopiowanie (bez klonowania APFS),
/// więc działa callback postępu. Tu używamy obrazu RAM-dysku, jeśli się da; w przeciwnym razie
/// testujemy JobControl bezpośrednio.
@Suite struct JobControlTests {
    @Test func speedLimitThrottles() {
        let control = JobControl(speedLimit: 1_000_000)
        let start = ContinuousClock.now
        for _ in 0..<5 { control.consume(100_000) }
        // 500 kB przy 1 MB/s ≈ 0,5 s
        #expect((ContinuousClock.now - start).seconds >= 0.4)
    }

    @Test func pauseBlocksUntilResume() async throws {
        let control = JobControl()
        control.pause()
        let resumed = Mutexed(false)
        let thread = Thread {
            control.checkpoint()
            resumed.set(true)
        }
        thread.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(resumed.get() == false)
        control.resume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(resumed.get() == true)
    }

    @Test func cancelUnblocksPause() async throws {
        let control = JobControl()
        control.pause()
        let result = Mutexed<Bool?>(nil)
        Thread { result.set(control.checkpoint()) }.start()
        try await Task.sleep(for: .milliseconds(100))
        control.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(result.get() == false)
    }
}

/// Prawdziwe kopiowanie danych (bez klonu): pauza, limit prędkości i anulowanie w callbacku `copyfile`.
@Suite(.serialized) struct CopyfileCallbackTests {
    func bigFile(_ tmp: TempDir, mb: Int) throws -> VFSPath {
        let url = tmp.url.appending(path: "src/big.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: mb * 1024 * 1024))
        return .local(url)
    }

    @Test func speedLimitAppliesInsideCopy() throws {
        let tmp = try TempDir()
        let src = try bigFile(tmp, mb: 8)
        let control = JobControl(speedLimit: 16 * 1024 * 1024)
        let engine = TransferEngine(request: TransferRequest(kind: .copy, sources: [src], destinationDirectory: try tmp.dir("dst")), control: control)
        engine.allowClone = false
        let start = ContinuousClock.now
        try engine.run()
        // 8 MB przy 16 MB/s ≈ 0,5 s
        #expect((ContinuousClock.now - start).seconds >= 0.35)
        #expect(try LocalFS().itemSync(at: tmp.path.appending("dst/big.bin")).size == 8 * 1024 * 1024)
    }

    @Test func cancelDuringCopyRemovesPartial() async throws {
        let tmp = try TempDir()
        let src = try bigFile(tmp, mb: 32)
        let control = JobControl(speedLimit: 8 * 1024 * 1024)
        let dst = try tmp.dir("dst")
        let engine = TransferEngine(request: TransferRequest(kind: .copy, sources: [src], destinationDirectory: dst), control: control)
        engine.allowClone = false
        let outcome = Mutexed<String>("")
        let thread = Thread {
            do { try engine.run(); outcome.set("done") } catch { outcome.set("\(error)") }
        }
        thread.start()
        try await Task.sleep(for: .milliseconds(400))
        // W trakcie: plik tymczasowy istnieje, docelowy jeszcze nie.
        let during = try LocalFS().listSync(dst).map(\.name)
        #expect(during.count == 1 && during[0].contains("bifold-partial"))
        control.cancel()
        for _ in 0..<50 where outcome.get().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(outcome.get() == "\(VFSError.cancelled)")
        #expect(try LocalFS().listSync(dst).isEmpty)
    }

    @Test func pauseStopsProgress() async throws {
        let tmp = try TempDir()
        let src = try bigFile(tmp, mb: 16)
        let control = JobControl(speedLimit: 8 * 1024 * 1024)
        let progress = Mutexed(TransferProgress())
        let engine = TransferEngine(request: TransferRequest(kind: .copy, sources: [src], destinationDirectory: try tmp.dir("dst")), control: control, onProgress: { progress.set($0) })
        engine.allowClone = false
        let finished = Mutexed(false)
        Thread { try? engine.run(); finished.set(true) }.start()
        try await Task.sleep(for: .milliseconds(300))
        control.pause()
        try await Task.sleep(for: .milliseconds(200))
        let paused = progress.get().bytesDone
        try await Task.sleep(for: .milliseconds(500))
        #expect(progress.get().bytesDone == paused)
        #expect(paused > 0 && paused < 16 * 1024 * 1024)
        control.setSpeedLimit(0)
        control.resume()
        for _ in 0..<100 where !finished.get() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(finished.get())
        #expect(progress.get().bytesDone == 16 * 1024 * 1024)
    }
}
