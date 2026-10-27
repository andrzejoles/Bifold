import Foundation
import Synchronization
@testable import BifoldCore

/// Katalog tymczasowy usuwany po teście.
final class TempDir {
    let url: URL
    var path: VFSPath { .local(url) }

    init() throws {
        let base = URL(filePath: realPath(NSTemporaryDirectory())!)
        url = base.appending(path: "bifold-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Zdejmij blokady, żeby dało się usunąć.
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let rel as String in e { chflags(url.appending(path: rel).path, 0) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ name: String, _ contents: String = "", modified: Date? = nil) throws -> VFSPath {
        let u = url.appending(path: name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: u)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path) }
        return .local(u)
    }

    @discardableResult
    func dir(_ name: String) throws -> VFSPath {
        let u = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return .local(u)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: url.appending(path: name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: name).path)
    }

    /// Czy wolumin katalogu tymczasowego nie rozróżnia wielkości liter (domyślny APFS).
    var isCaseInsensitive: Bool {
        let probe = url.appending(path: "CaseProbe-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: probe.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: url.appending(path: probe.lastPathComponent.lowercased()).path)
    }

    /// Nazwy w katalogu (względem katalogu tymczasowego).
    func names(_ dir: String = "") throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.isEmpty ? url.path : url.appending(path: dir).path))
    }
}

/// Uruchamia `body` na osobnym wątku i czeka najwyżej `limit`. Jeśli się nie skończy (blokada na FIFO),
/// otwiera FIFO do zapisu i zamyka je — czytelnik dostaje koniec pliku, więc wątek i procesy nie zostają.
/// Gdy `body` blokuje się na czymś innym niż FIFO, odblokowywanie trwa najwyżej `unblockLimit`
/// (test kończy się porażką zamiast wisieć; wątek zostaje do końca procesu testów).
func finishes(within limit: Duration, unblocking fifo: String, unblockLimit: Duration = .seconds(5), _ body: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { body(); done.signal() }
    func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    if done.wait(timeout: .now() + seconds(limit)) == .success { return true }
    let giveUp = ContinuousClock.now + unblockLimit
    while done.wait(timeout: .now() + 0.05) == .timedOut, ContinuousClock.now < giveUp {
        let fd = open(fifo, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
    }
    return false
}

final class Flag: Sendable {
    private let state = Atomic<Bool>(false)
    var value: Bool { state.load(ordering: .relaxed) }
    func set() { state.store(true, ordering: .relaxed) }
}
