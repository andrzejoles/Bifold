import Foundation
import Testing
@testable import BifoldCore

/// Sumy kontrolne, dzielenie i łączenie plików: FIFO, katalogi i pliki bez praw nie blokują ani nie
/// przerywają całej operacji.
@Suite struct ChecksumTests {
    /// Jeden nieczytelny wpis (FIFO, katalog, brak praw) jest `invalid`; reszta sprawdzana dalej.
    @Test func verifyMarksUnreadableEntriesInvalid() throws {
        let tmp = try TempDir()
        try tmp.file("dobry.txt", "abc")
        #expect(mkfifo(tmp.url.appending(path: "kolejka").path, 0o600) == 0)
        try tmp.dir("katalog")
        try tmp.file("zakazany.txt", "x")
        #expect(chmod(tmp.url.appending(path: "zakazany.txt").path, 0) == 0)
        defer { chmod(tmp.url.appending(path: "zakazany.txt").path, 0o600) }
        let md5 = "900150983cd24fb0d6963f7d28e17f72"
        try tmp.file("sumy.md5", Checksums.format([(md5, "kolejka"), (md5, "katalog"), (md5, "zakazany.txt"), (md5, "dobry.txt"), (md5, "brak.txt")]))

        let results = ResultBox<[Checksums.VerifyResult]>()
        let errors = ResultBox<String>()
        let sumFile = tmp.path.appending("sumy.md5")
        #expect(finishes(within: .seconds(3), unblocking: tmp.url.appending(path: "kolejka").path) {
            do { results.value = try Checksums.verify(checksumFile: sumFile) } catch { errors.value = "\(error)" }
        })
        #expect(errors.value == nil)
        #expect(results.value?.map(\.status) == [.invalid, .invalid, .invalid, .ok, .missing])
    }

    /// Anulowanie dalej przerywa weryfikację.
    @Test func verifyStillPropagatesCancellation() throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "abc")
        try tmp.file("sumy.md5", Checksums.format([("00", "a.txt")]))
        #expect(throws: VFSError.cancelled) { try Checksums.verify(checksumFile: tmp.path.appending("sumy.md5"), isCancelled: { true }) }
    }

    @Test func splitRejectsFIFO() throws {
        let tmp = try TempDir()
        let fifo = tmp.url.appending(path: "kolejka").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let out = try tmp.dir("czesci")
        let failed = Flag()
        #expect(finishes(within: .seconds(3), unblocking: fifo) {
            if (try? FileSplitter.split(.local(fifo), partSize: 10, into: out)) == nil { failed.set() }
        }, "split zablokował się na FIFO")
        #expect(failed.value)
        #expect(try tmp.names("czesci").isEmpty)
    }

    /// Plik sum obok części będący FIFO: łączenie kończy się bez weryfikacji, zamiast czekać
    /// (`String(contentsOfFile:)` zwraca dla FIFO błąd od razu — test pilnuje, żeby tak zostało).
    @Test func joinIgnoresFIFOChecksumFile() throws {
        let tmp = try TempDir()
        let part = try tmp.file("x.bin.001", "abc")
        let fifo = tmp.url.appending(path: "x.bin.sha256").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let target = tmp.path.appending("x.bin")
        let verified = ResultBox<Bool?>()
        let errors = ResultBox<String>()
        #expect(finishes(within: .seconds(3), unblocking: fifo) {
            do { verified.value = try FileSplitter.join([part], into: target) } catch { errors.value = "\(error)" }
        }, "join zablokował się na FIFO")
        #expect(errors.value == nil)
        #expect(verified.value == .some(nil))
        #expect(try tmp.read("x.bin") == "abc")
    }
}
