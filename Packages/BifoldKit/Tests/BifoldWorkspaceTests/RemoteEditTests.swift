import Foundation
import Synchronization
import Testing
@testable import BifoldCore
@testable import BifoldWorkspace

/// Serwer z wolną wysyłką: zapamiętuje treść każdej wysyłki i największą liczbę wysyłek naraz.
/// Wysyłka nie reaguje na anulowanie zadania — jak `scp` w trakcie kopiowania.
final class SlowUploadFS: RemoteFileProvider {
    let id = RemoteFS.providerID("wolny")
    let capabilities: ProviderCapabilities = [.read, .write]
    let connection = RemoteConnection(alias: "wolny", kind: .sftp, host: "127.0.0.1")
    let state = Mutex<(active: Int, maxActive: Int, uploads: [String])>((0, 0, []))
    var root: VFSPath { VFSPath(provider: id, path: "/") }

    func upload(_ local: URL, to path: VFSPath) async throws {
        let text = (try? String(contentsOf: local, encoding: .utf8)) ?? ""
        state.withLock { s in
            s.active += 1
            s.maxActive = max(s.maxActive, s.active)
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.resume() }
        }
        state.withLock { s in
            s.uploads.append(text)
            s.active -= 1
        }
    }

    func download(_ path: VFSPath) async throws -> URL { throw VFSError.unsupported("download") }
    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] { [] }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: .file) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: "wolny", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isInternal: false, isNetwork: true)
    }
}

@MainActor @Suite struct RemoteEditTests {
    /// Zapisy w trakcie wysyłki nie startują drugiej wysyłki tego samego pliku (starsza mogłaby skończyć
    /// się później i wygrać): czekają i scalają się w jedną wysyłkę po bieżącej — na serwerze ląduje
    /// ostatnia treść.
    @Test func uploadsOfOneEditAreSerialized() async throws {
        let tmp = try TempDir()
        let local = tmp.url.appending(path: "plik.txt")
        try Data("0".utf8).write(to: local)
        let fs = SlowUploadFS()
        var reports: [String] = []
        let session = RemoteEditSession(local: local, remote: fs.root.appending("plik.txt"), fs: fs) { reports.append($0) }
        session.delay = .milliseconds(10)

        try Data("1".utf8).write(to: local)
        session.changed()
        #expect(await eventually { fs.state.withLock { $0.active } == 1 }, "pierwsza wysyłka trwa")
        try Data("2".utf8).write(to: local)
        session.changed()
        try await Task.sleep(for: .milliseconds(60))
        try Data("3".utf8).write(to: local)
        session.changed()
        await session.finished()

        let (maxActive, uploads) = fs.state.withLock { ($0.maxActive, $0.uploads) }
        #expect(maxActive == 1, "wysyłki nie nakładają się")
        // Zwykle ["1", "3"] (zapisy „2” i „3” scalone); pod dużym obciążeniem może dojść osobna wysyłka.
        #expect(uploads.first == "1" && uploads.last == "3" && uploads.count <= 3, "\(uploads)")
        #expect(reports.count == uploads.count)
    }
}
