import Darwin
import Foundation
import Testing
@testable import BifoldCore

let rclonePath: String? = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"].first { FileManager.default.isExecutableFile(atPath: $0) }

/// Lokalny serwer `rclone serve <proto>` na losowym porcie.
final class TestServer {
    let process = Process()
    let port: Int
    let root: TempDir

    init(_ proto: String, user: String = "u", pass: String = "tajne") throws {
        root = try TempDir()
        port = Int.random(in: 21000...39000)
        process.executableURL = URL(filePath: rclonePath!)
        process.arguments = ["serve", proto, root.url.path, "--addr", "127.0.0.1:\(port)", "--user", user, "--pass", pass, "--config", ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Czekamy, aż port zacznie przyjmować połączenia.
        for _ in 0..<100 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            close(fd)
            if ok { return }
            usleep(50_000)
        }
    }

    deinit { process.terminate() }
}

@Suite(.serialized, .enabled(if: rclonePath != nil)) struct RemoteTests {
    func rclone() throws -> Rclone {
        let r = Rclone(executable: rclonePath!, socket: URL(filePath: "/tmp/bfr-\(UUID().uuidString.prefix(6)).sock"))
        try r.start()
        return r
    }

    @Test(arguments: ["sftp", "ftp", "webdav"])
    func browseAndModify(proto: String) async throws {
        let server = try TestServer(proto)
        try server.root.file("dane/raport.txt", "zawartość")
        let rc = try rclone()
        defer { rc.stop() }
        let kind: RemoteKind = proto == "sftp" ? .sftp : (proto == "ftp" ? .ftp : .webdav)
        let host = proto == "webdav" ? "http://127.0.0.1:\(server.port)" : "127.0.0.1"
        let conn = RemoteConnection(alias: "test-\(proto)", kind: kind, host: host, port: proto == "webdav" ? nil : server.port, user: "u")
        let fs = try await RemoteFS.connect(conn, secret: "tajne", rclone: rc)
        let root = try await fs.list(fs.root, options: ListOptions())
        #expect(root.map(\.name) == ["dane"])
        let dane = try #require(root.first)
        #expect(dane.isDirectory)
        let files = try await fs.list(dane.path, options: ListOptions())
        #expect(files.map(\.name) == ["raport.txt"] && files[0].size == "zawartość".utf8.count)
        #expect(String(decoding: try await fs.readContents(files[0].path, range: nil), as: UTF8.self) == "zawartość")

        try await fs.createDirectory(fs.root.appending("nowy"))
        try await fs.createFile(fs.root.appending("nowy/plik.txt"), contents: Data("x".utf8))
        #expect(try server.root.read("nowy/plik.txt") == "x")
        let renamed = try await fs.rename(fs.root.appending("nowy/plik.txt"), to: "inny.txt")
        #expect(renamed.name == "inny.txt" && server.root.exists("nowy/inny.txt"))
        try await fs.deletePermanently(fs.root.appending("nowy"))
        #expect(!server.root.exists("nowy"))
        // Agent widzi tylko alias.
        #expect(fs.root.description == "remote:test-\(proto):/")
    }

    @Test func wrongPasswordFails() async throws {
        let server = try TestServer("sftp")
        let rc = try rclone()
        defer { rc.stop() }
        let fs = try await RemoteFS.connect(RemoteConnection(alias: "zle", kind: .sftp, host: "127.0.0.1", port: server.port, user: "u"), secret: "zle", rclone: rc)
        await #expect(throws: (any Error).self) { _ = try await fs.list(fs.root, options: ListOptions()) }
    }

    @MainActor @Test func transfersWithProgressAndUndo() async throws {
        let server = try TestServer("sftp")
        try server.root.file("zdalne/a.txt", "AAA")
        try server.root.file("zdalne/pod/b.txt", "BB")
        let rc = try rclone()
        defer { rc.stop() }
        let fs = try await RemoteFS.connect(RemoteConnection(alias: "srv", kind: .sftp, host: "127.0.0.1", port: server.port, user: "u"), secret: "tajne", rclone: rc)
        let local = try TempDir()
        try local.file("wysylka/c.txt", "C")

        // Pobranie katalogu.
        let journal = OperationJournal()
        let queue = JobQueue(journal: journal)
        let download = RcloneTransfer(
            kind: .copy, items: [.init(srcFs: fs.fs, srcRemote: "zdalne", isDirectory: true, name: "zdalne", size: 5)],
            dstFs: local.url.path, dstRemote: "", localDestination: local.path, skipExisting: false)
        let job = queue.enqueue(.rclone(download, rc), title: "pobierz")
        #expect(await queue.wait(for: job) == .completed)
        #expect(try local.read("zdalne/pod/b.txt") == "BB")
        #expect(job.progress.filesDone == 1)

        // Wysłanie pliku.
        let upload = RcloneTransfer(
            kind: .copy, items: [.init(srcFs: local.url.path + "/wysylka", srcRemote: "c.txt", isDirectory: false, name: "c.txt", size: 1)],
            dstFs: fs.fs, dstRemote: "zdalne", localDestination: nil, skipExisting: false)
        #expect(await queue.wait(for: queue.enqueue(.rclone(upload, rc), title: "wyślij")) == .completed)
        #expect(try server.root.read("zdalne/c.txt") == "C")

        // Cofnięcie pobrania = do Kosza.
        let plan = UndoPlanner.plan(for: [journal.batches[0]])
        #expect(plan.conflicts.isEmpty)
        _ = UndoPlanner.execute(plan, journal: journal)
        #expect(!local.exists("zdalne"))
    }

    @Test func inMemoryConfigOnly() async throws {
        let rc = try rclone()
        defer { rc.stop() }
        _ = try await RemoteFS.connect(RemoteConnection(alias: "pamiec", kind: .sftp, host: "example.invalid", user: "u"), secret: "SEKRET-123", rclone: rc)
        let dump = try await rc.call("config/dump", [:])
        // Hasło zaciemnione (obscure), nigdy jawne; brak pliku konfiguracji.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: dump), as: UTF8.self)
        #expect(!text.contains("SEKRET-123"))
        let paths = try await rc.call("config/paths", [:])
        let configPath = paths["config"] as? String ?? ""
        #expect(configPath.isEmpty || !FileManager.default.fileExists(atPath: configPath))
        #expect(throws: VFSError.self) { try RemoteFS.validateAlias("zły alias/") }
    }
}
