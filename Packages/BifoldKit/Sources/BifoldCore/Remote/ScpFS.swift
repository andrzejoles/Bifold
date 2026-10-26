import Foundation
import Synchronization

/// Wspólny interfejs serwerów (rclone i SCP) dla komend, edycji zdalnej i agenta.
public protocol RemoteFileProvider: FileSystemProvider {
    var connection: RemoteConnection { get }
    var root: VFSPath { get }
    /// Pobranie do katalogu tymczasowego (podgląd, edycja, odczyt dla agenta).
    func download(_ path: VFSPath) async throws -> URL
    func upload(_ local: URL, to path: VFSPath) async throws
}

extension RemoteFS: RemoteFileProvider {}

/// Serwer przez klasyczny protokół SCP (`scp -O`) i polecenia powłoki przez SSH — dla systemów bez
/// SFTP lub ze starym OpenSSH (np. AIX 6.1). Listing z `ls -la`, kopiowanie plik po pliku z jawną
/// nazwą docelową (działa też dla nazw w ISO-8859-2). Identyfikator jak w RemoteFS: `remote:<alias>`.
public final class ScpFS: RemoteFileProvider, ExtractingProvider {
    public let id: ProviderID
    public let connection: RemoteConnection
    public let session: SSHSession
    /// Katalog na serwerze odpowiadający korzeniowi (`/` w panelu).
    public let base: String
    public let capabilities: ProviderCapabilities = [.read, .write]

    init(connection: RemoteConnection, session: SSHSession, base: String) {
        self.connection = connection
        self.session = session
        self.base = base
        id = RemoteFS.providerID(connection.alias)
    }

    public static func connect(_ c: RemoteConnection, runDirectory: URL, sshConfigFile: String? = nil, knownHostsFile: String? = nil,
                               secret: @escaping @Sendable () -> String?) async throws -> ScpFS {
        try RemoteFS.validateAlias(c.alias)
        let config = SSHSession.Config(host: c.host, port: c.port, user: c.user, keyFile: c.keyFile, legacyAlgorithms: c.legacyAlgorithms ?? false,
                                       encoding: c.nameEncoding ?? .utf8, configFile: sshConfigFile, knownHostsFile: knownHostsFile)
        let session = try SSHSession(config: config, runDirectory: runDirectory, secret: secret)
        let base = try await runBlocking(qos: .userInitiated) { () -> String in
            try session.connect()
            let start = c.path.trimmingCharacters(in: .whitespaces)
            let r = try session.run(start.isEmpty ? "pwd" : "cd \(SSHSession.shellQuote(start)) && pwd")
            guard r.status == 0 else { throw RemoteError.ssh(r.errorText.isEmpty ? L10n.tr("Brak katalogu \(start)") : r.errorText) }
            return config.encoding.decode(r.output).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ScpFS(connection: c, session: session, base: base.isEmpty ? "/" : base)
    }

    public var root: VFSPath { VFSPath(provider: id, path: "/") }
    public var displayName: String { connection.alias }

    /// Ścieżka absolutna na serwerze.
    public func remotePath(_ path: VFSPath) -> String {
        let inner = String(path.path.dropFirst())
        if inner.isEmpty { return base }
        return base == "/" ? "/" + inner : base + "/" + inner
    }

    func shell(_ command: String, timeout: TimeInterval = 120) throws -> String {
        let r = try session.run("LC_ALL=C; export LC_ALL; " + command, timeout: timeout)
        guard r.status == 0 else {
            let text = session.config.encoding.decode(r.error).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("No such file") || text.contains("does not exist") { throw VFSError.notFound(root) }
            if text.contains("Permission denied") { throw VFSError.permissionDenied(root) }
            throw RemoteError.ssh(text.isEmpty ? "status \(r.status)" : text)
        }
        return session.config.encoding.decode(r.output)
    }

    static let linkMarker = "//BIFOLD-LINKDIRS//"

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        let items = try await runBlocking(qos: .userInitiated) { try self.listSync(directory) }
        return options.includeHidden ? items : items.filter { !$0.isHidden }
    }

    /// Listing (z ukrytymi) — wersja blokująca dla wątków zadań.
    public func listSync(_ directory: VFSPath) throws -> [FileItem] {
        let dir = remotePath(directory)
        // Dowiązania do katalogów osobno: `ls -la` nie mówi, na co wskazuje dowiązanie.
        let command = "cd \(SSHSession.shellQuote(dir)) && ls -la && echo '\(Self.linkMarker)' && for f in .* *; do [ -h \"$f\" ] && [ -d \"$f\" ] && echo \"$f\"; done; true"
        let text = try shell(command)
        let parts = text.components(separatedBy: Self.linkMarker + "\n")
        let linkDirs = Set((parts.count > 1 ? parts[1] : "").split(separator: "\n").map(String.init))
        var items = Self.parseListing(parts[0], in: directory)
        for i in items.indices where items[i].kind == .symlink && linkDirs.contains(items[i].name) {
            items[i].flags.insert(.symlinkToDirectory)
        }
        return items
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        try await runBlocking(qos: .userInitiated) { try self.itemSync(path) }
    }

    public func itemSync(_ path: VFSPath) throws -> FileItem {
        if path.isRoot { return FileItem(path: root, name: connection.alias, kind: .directory) }
        guard let parent = path.parent else { throw VFSError.notFound(path) }
        let remote = SSHSession.shellQuote(remotePath(path))
        let text = try shell("ls -lad \(remote) && if [ -h \(remote) ] && [ -d \(remote) ]; then echo '\(Self.linkMarker)'; fi")
        guard let parsed = Self.parseListing(text, in: parent, keepDots: true).first else { throw VFSError.notFound(path) }
        var item = FileItem(path: path, kind: parsed.kind, size: parsed.size, modified: parsed.modified, permissions: parsed.permissions)
        if text.contains(Self.linkMarker) { item.flags.insert(.symlinkToDirectory) }
        return item
    }

    public func exists(_ path: VFSPath) async -> Bool {
        (try? await item(at: path)) != nil
    }

    // MARK: Parser `ls -la`

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `ls -la` w lokalizacji C (AIX, Linux, BSD): typ i prawa, liczba dowiązań, właściciel, grupa,
    /// rozmiar (albo „główny, poboczny” dla urządzeń), data „Mon DD HH:MM” lub „Mon DD  YYYY”, nazwa.
    public static func parseListing(_ text: String, in dir: VFSPath, now: Date = Date(), keepDots: Bool = false) -> [FileItem] {
        var out: [FileItem] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let currentYear = calendar.component(.year, from: now)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            guard let first = line.first, "-dlcbps".contains(first), !line.hasPrefix("total ") else { continue }
            // Słowa z zakresami (nazwa zaczyna się po trzecim polu daty).
            var words: [(String, Range<String.Index>)] = []
            var i = line.startIndex
            while i < line.endIndex, words.count < 12 {
                while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
                guard i < line.endIndex else { break }
                let start = i
                while i < line.endIndex, line[i] != " " { i = line.index(after: i) }
                words.append((String(line[start..<i]), start..<i))
            }
            guard words.count >= 8, words[0].0.count >= 10 else { continue }
            var m: Int?
            for k in 4..<(words.count - 2) where months.contains(words[k].0) {
                if let d = Int(words[k + 1].0), (1...31).contains(d), words[k + 2].0.contains(":") || Int(words[k + 2].0) != nil {
                    m = k
                    break
                }
            }
            guard let k = m else { continue }
            let nameStart = line.index(after: words[k + 2].1.upperBound)
            guard nameStart <= line.endIndex else { continue }
            var name = String(line[nameStart...])
            let mode = words[0].0
            let kind: FileKind = switch mode.first {
            case "d": .directory
            case "l": .symlink
            case "-": .file
            default: .other
            }
            if kind == .symlink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if keepDots, name.contains("/") { name = (name as NSString).lastPathComponent }
            // Wyjście `ls` z serwera jest niezaufane: nazwa z `/` albo podrzucony wierszem z nową linią
            // `../…` zapisałby przy pobieraniu katalogu plik poza katalogiem docelowym.
            guard isSafeComponentName(name) || (keepDots && (name == "." || name == "..")) else { continue }
            // Urządzenia: „główny, poboczny” zamiast rozmiaru.
            let isDevice = words[k - 1].0.hasSuffix(",") || words[k - 2].0.hasSuffix(",")
            let size = isDevice ? 0 : (Int64(words[k - 1].0) ?? 0)
            let month = months.firstIndex(of: words[k].0)! + 1
            let day = Int(words[k + 1].0)!
            var comps = DateComponents(year: currentYear, month: month, day: day)
            let third = words[k + 2].0
            if let year = Int(third) {
                comps.year = year
            } else {
                let hm = third.split(separator: ":")
                comps.hour = Int(hm.first ?? "0")
                comps.minute = Int(hm.count > 1 ? hm[1] : "0")
            }
            var date = calendar.date(from: comps)
            // Bez roku = ostatnie pół roku; data „w przyszłości” to zeszły rok.
            if Int(third) == nil, let d = date, d > now.addingTimeInterval(86400) {
                comps.year = currentYear - 1
                date = calendar.date(from: comps)
            }
            out.append(FileItem(path: dir.appending(name), kind: kind, size: kind == .directory ? -1 : size, modified: date, permissions: parseMode(mode)))
        }
        return out
    }

    static func parseMode(_ mode: String) -> UInt16 {
        let chars = Array(mode.dropFirst().prefix(9))
        guard chars.count == 9 else { return 0 }
        var bits: UInt16 = 0
        for (i, c) in chars.enumerated() where c != "-" && c != "S" && c != "T" {
            bits |= 1 << UInt16(8 - i)
        }
        if "sS".contains(chars[2]) { bits |= 0o4000 }
        if "sS".contains(chars[5]) { bits |= 0o2000 }
        if "tT".contains(chars[8]) { bits |= 0o1000 }
        return bits
    }

    // MARK: Operacje

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        let url = try await download(path)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try LocalFS().readSync(.local(url), range: range)
    }

    public func download(_ path: VFSPath) async throws -> URL {
        let (temp, items) = try await runBlocking(qos: .userInitiated) {
            try self.extract([path], toTemporaryIn: .local(NSTemporaryDirectory()), isCancelled: { false })
        }
        _ = temp
        return URL(filePath: items[0].path)
    }

    public func upload(_ local: URL, to path: VFSPath) async throws {
        try validateFileName(path.name)
        let remote = remotePath(path)
        try await runBlocking(qos: .userInitiated) { try self.session.scp(upload: local.path, to: remote, isCancelled: { false }, isPaused: { false }) }
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: connection.alias, totalCapacity: 0, availableCapacity: 0, fileSystem: "scp", isInternal: false, isNetwork: true)
    }

    public func createDirectory(_ path: VFSPath) async throws {
        try validateFileName(path.name)
        let p = SSHSession.shellQuote(remotePath(path))
        _ = try await runBlocking(qos: .userInitiated) { try self.shell("mkdir \(p)") }
    }

    public func createFile(_ path: VFSPath, contents: Data) async throws {
        try validateFileName(path.name)
        guard await !exists(path) else { throw VFSError.alreadyExists(path) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "bifold-up-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: path.name)
        try contents.write(to: url)
        try await upload(url, to: path)
    }

    public func rename(_ path: VFSPath, to newName: String) async throws -> VFSPath {
        try validateFileName(newName)
        guard let parent = path.parent, !path.isRoot else { throw VFSError.unsupported("rename /") }
        let target = parent.appending(newName)
        let a = SSHSession.shellQuote(remotePath(path)), b = SSHSession.shellQuote(remotePath(target))
        _ = try await runBlocking(qos: .userInitiated) {
            try self.shell("if [ -e \(b) ] || [ -h \(b) ]; then echo 'File exists' >&2; exit 17; fi; mv \(a) \(b)")
        }
        return target
    }

    /// Serwery nie mają Kosza — usuwanie jest trwałe (z potwierdzeniem w interfejsie).
    public func deletePermanently(_ path: VFSPath) async throws {
        let remote = remotePath(path)
        guard !path.isRoot, remote != "/", remote != base else { throw VFSError.unsupported("delete /") }
        _ = try await runBlocking(qos: .userInitiated) { try self.shell("rm -r -f \(SSHSession.shellQuote(remote))") }
    }

    // MARK: Pobieranie i wysyłanie

    /// Pobiera elementy (katalogi rekurencyjnie, plik po pliku) do nowego katalogu tymczasowego.
    public func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        let temp = directory.appending(".bifold-scp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var items: [VFSPath] = []
        do {
            for p in paths {
                let local = temp.appending(p.name)
                try fetch(p, to: local, isCancelled: isCancelled, isPaused: { false }) { _ in }
                items.append(local)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temp.path)
            throw error
        }
        return (temp, items)
    }

    func fetch(_ path: VFSPath, to local: VFSPath, isCancelled: @escaping @Sendable () -> Bool, isPaused: @escaping @Sendable () -> Bool, done: (Int64) -> Void) throws {
        if isCancelled() { throw VFSError.cancelled }
        let info = try itemSync(path)
        if info.isNavigable {
            try FileManager.default.createDirectory(atPath: local.path, withIntermediateDirectories: false)
            for child in try listSync(path) {
                try fetch(child.path, to: local.appending(child.name), isCancelled: isCancelled, isPaused: isPaused, done: done)
            }
        } else {
            try session.scp(download: remotePath(path), to: local.path, isCancelled: isCancelled, isPaused: isPaused)
            done(max(0, info.size))
        }
    }

    /// Wysyła plik lub katalog (rekurencyjnie) pod ścieżkę `target` na serwerze.
    func send(_ local: VFSPath, to target: VFSPath, isCancelled: @escaping @Sendable () -> Bool, isPaused: @escaping @Sendable () -> Bool, done: (Int64) -> Void) throws {
        if isCancelled() { throw VFSError.cancelled }
        let item = try LocalFS().itemSync(at: local)
        if item.isDirectory {
            _ = try shell("mkdir -p \(SSHSession.shellQuote(remotePath(target)))")
            let children = try FileManager.default.contentsOfDirectory(atPath: local.path).sorted()
            for name in children {
                try send(local.appending(name), to: target.appending(name), isCancelled: isCancelled, isPaused: isPaused, done: done)
            }
        } else if item.kind == .file {
            try session.scp(upload: local.path, to: remotePath(target), isCancelled: isCancelled, isPaused: isPaused)
            done(max(0, item.size))
        }
    }

    public func disconnect() { session.disconnect() }
}

/// Wysyłanie na serwer SCP jako zadanie w tle (pauza = SIGSTOP procesu `scp`, anulowanie = zakończenie).
public struct ScpUpload: Sendable {
    public var fs: ScpFS
    public var sources: [VFSPath]
    public var destination: VFSPath
    public var skipExisting: Bool

    public init(fs: ScpFS, sources: [VFSPath], destination: VFSPath, skipExisting: Bool) {
        self.fs = fs
        self.sources = sources
        self.destination = destination
        self.skipExisting = skipExisting
    }

    public func run(control: JobControl, progress: @Sendable (TransferProgress) -> Void) throws -> [String] {
        var p = TransferProgress()
        p.filesTotal = sources.count
        p.bytesTotal = sources.reduce(0) { $0 + ((try? DirectorySizer.sizeSync(of: $1, isCancelled: { false }))?.bytes ?? 0) }
        let existing = Set(((try? fs.listSync(destination)) ?? []).map(\.name))
        var errors: [String] = []
        for source in sources {
            guard control.checkpoint() else { throw VFSError.cancelled }
            p.currentItem = source.name
            progress(p)
            if existing.contains(source.name) {
                if skipExisting {
                    errors.append(L10n.tr("\(source.name): istnieje na serwerze — pominięto"))
                    p.filesDone += 1
                    continue
                }
                let target = SSHSession.shellQuote(fs.remotePath(destination.appending(source.name)))
                _ = try? fs.shell("rm -r -f \(target)")
            }
            do {
                try fs.send(source, to: destination.appending(source.name), isCancelled: { control.isCancelled }, isPaused: { control.isPaused }) { bytes in
                    p.bytesDone += bytes
                    progress(p)
                }
            } catch VFSError.cancelled {
                throw VFSError.cancelled
            } catch {
                errors.append("\(source.name): \(error.localizedDescription)")
            }
            p.filesDone += 1
            progress(p)
        }
        return errors
    }
}
