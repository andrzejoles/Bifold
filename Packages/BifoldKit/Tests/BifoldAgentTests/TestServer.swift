import Darwin
import Foundation

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

