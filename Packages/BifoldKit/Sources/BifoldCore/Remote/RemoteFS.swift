import Foundation

/// Zdalny system plików przez rclone. Agent widzi tylko alias (`ProviderID` = `remote:<alias>`).
public final class RemoteFS: FileSystemProvider {
    public let id: ProviderID
    public let connection: RemoteConnection
    public let rclone: Rclone
    public let capabilities: ProviderCapabilities = [.read, .write]

    public init(connection: RemoteConnection, rclone: Rclone) {
        self.connection = connection
        self.rclone = rclone
        id = Self.providerID(connection.alias)
    }

    /// Tworzy zasób w pamięci procesu rclone (`config/create`, hasło zaciemniane przez rclone)
    /// — nic nie trafia do pliku konfiguracji.
    public static func connect(_ c: RemoteConnection, secret: String?, rclone: Rclone, knownHostsFile: String? = nil, hostKeyAlgorithms: [String] = []) async throws -> RemoteFS {
        try validateAlias(c.alias)
        _ = try await rclone.call("config/create", [
            "name": c.alias, "type": c.kind.backend, "parameters": c.rcloneParameters(secret: secret, knownHostsFile: knownHostsFile, hostKeyAlgorithms: hostKeyAlgorithms),
            "opt": ["obscure": true, "nonInteractive": true],
        ])
        return RemoteFS(connection: c, rclone: rclone)
    }

    public static func validateAlias(_ alias: String) throws {
        guard !alias.isEmpty, alias.count <= 64, alias.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw VFSError.invalidName(alias)
        }
    }

    public static func providerID(_ alias: String) -> ProviderID { ProviderID("remote:\(alias)") }

    public static func alias(of path: VFSPath) -> String? {
        let raw = path.provider.rawValue
        return raw.hasPrefix("remote:") ? String(raw.dropFirst(7)) : nil
    }

    public var root: VFSPath { VFSPath(provider: id, path: "/") }
    /// Nazwa systemu plików rclone (`alias:`). SFTP z katalogiem startowym „/var/log” liczy ścieżki
    /// od korzenia serwera (`alias:/`), inaczej rclone liczyłby je od katalogu domowego.
    public var fs: String { connection.alias + (connection.kind == .sftp && connection.path.hasPrefix("/") ? ":/" : ":") }

    /// Ścieżka po stronie rclone (względem korzenia połączenia).
    public func remotePath(_ path: VFSPath) -> String {
        let base = connection.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let inner = String(path.path.dropFirst())
        return base.isEmpty ? inner : (inner.isEmpty ? base : base + "/" + inner)
    }

    func item(_ e: Rclone.ListEntry, in dir: VFSPath) -> FileItem {
        FileItem(path: dir.appending(e.name), kind: e.isDirectory ? .directory : .file, size: e.isDirectory ? -1 : e.size, modified: e.modified)
    }

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        let entries = try await rclone.list(fs: fs, remote: remotePath(directory))
        // Nazwy od serwera są niezaufane (`..` albo `/` wyprowadziłyby ścieżkę poza katalog).
        let items = entries.filter { isSafeComponentName($0.name) }.map { item($0, in: directory) }
        return options.includeHidden ? items : items.filter { !$0.isHidden }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: root, name: connection.alias, kind: .directory) }
        let r = try await rclone.call("operations/stat", ["fs": fs, "remote": remotePath(path)])
        guard let e = r["item"] as? [String: Any] else { throw VFSError.notFound(path) }
        let isDir = e["IsDir"] as? Bool ?? false
        return FileItem(
            path: path, kind: isDir ? .directory : .file, size: isDir ? -1 : ((e["Size"] as? NSNumber)?.int64Value ?? 0),
            modified: (e["ModTime"] as? String).flatMap(Rclone.parseDate))
    }

    public func exists(_ path: VFSPath) async -> Bool {
        (try? await item(at: path)) != nil
    }

    /// Pobranie do katalogu tymczasowego (podgląd, edycja, odczyt dla agenta).
    public func download(_ path: VFSPath) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bifold-remote-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            _ = try await rclone.call("operations/copyfile", ["srcFs": fs, "srcRemote": remotePath(path), "dstFs": dir.path, "dstRemote": path.name])
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        Quarantine.mark(dir.appending(path: path.name).path)
        return dir.appending(path: path.name)
    }

    /// rclone po cichu zastępuje istniejący cel (`copyfile`, `movefile`), scala katalogi (`sync/move`)
    /// i zgłasza sukces `mkdir` dla istniejącego katalogu — dlatego cel sprawdzany wcześniej.
    func requireAbsent(_ path: VFSPath) async throws {
        if await exists(path) { throw VFSError.alreadyExists(path) }
    }

    public func upload(_ local: URL, to path: VFSPath) async throws {
        _ = try await rclone.call("operations/copyfile", [
            "srcFs": local.deletingLastPathComponent().path, "srcRemote": local.lastPathComponent,
            "dstFs": fs, "dstRemote": remotePath(path),
        ])
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        let url = try await download(path)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try LocalFS().readSync(.local(url), range: range)
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: connection.alias, totalCapacity: 0, availableCapacity: 0, fileSystem: connection.kind.rawValue, isInternal: false, isNetwork: true)
    }

    public func createDirectory(_ path: VFSPath) async throws {
        try validateFileName(path.name)
        try await requireAbsent(path)
        _ = try await rclone.call("operations/mkdir", ["fs": fs, "remote": remotePath(path)])
    }

    public func createFile(_ path: VFSPath, contents: Data) async throws {
        try validateFileName(path.name)
        try await requireAbsent(path)
        let dir = FileManager.default.temporaryDirectory.appending(path: "bifold-up-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: path.name)
        try contents.write(to: url)
        try await upload(url, to: path)
    }

    public func rename(_ path: VFSPath, to newName: String) async throws -> VFSPath {
        try validateFileName(newName)
        guard let parent = path.parent else { throw VFSError.unsupported("rename /") }
        let target = parent.appending(newName)
        if path.name.compare(newName, options: .caseInsensitive) != .orderedSame {
            try await requireAbsent(target)
        } else {
            // Zmiana samej wielkości liter: serwer bez jej rozróżniania widzi cel jako ten sam element
            // (`stat` celu znalazłby źródło), ale serwer, który ją rozróżnia, może mieć osobny element
            // o nowej nazwie — rclone by go zastąpił. Rozstrzyga listing rodzica (porównanie bajtów).
            let entries = try await rclone.list(fs: fs, remote: remotePath(parent))
            if entries.contains(where: { Array($0.name.utf8) == Array(newName.utf8) && Array($0.name.utf8) != Array(path.name.utf8) }) {
                throw VFSError.alreadyExists(target)
            }
        }
        let isDir = (try? await item(at: path))?.isDirectory ?? false
        if isDir {
            _ = try await rclone.call("sync/move", ["srcFs": fs + remotePath(path), "dstFs": fs + remotePath(target), "deleteEmptySrcDirs": true])
        } else {
            _ = try await rclone.call("operations/movefile", ["srcFs": fs, "srcRemote": remotePath(path), "dstFs": fs, "dstRemote": remotePath(target)])
        }
        return target
    }

    /// Serwery nie mają Kosza — usuwanie jest trwałe (z potwierdzeniem w interfejsie).
    public func deletePermanently(_ path: VFSPath) async throws {
        let isDir = (try? await item(at: path))?.isDirectory ?? false
        if isDir {
            _ = try await rclone.call("operations/purge", ["fs": fs, "remote": remotePath(path)])
        } else {
            _ = try await rclone.call("operations/deletefile", ["fs": fs, "remote": remotePath(path)])
        }
    }
}

/// Przesyłanie przez rclone (lokalny ⇄ zdalny, zdalny ⇄ zdalny): zadania asynchroniczne rc
/// (`_async`) z postępem z `core/stats` i anulowaniem `job/stop`.
public struct RcloneTransfer: Sendable {
    public struct Item: Sendable {
        public var srcFs: String
        public var srcRemote: String
        public var isDirectory: Bool
        public var name: String
        public var size: Int64

        public init(srcFs: String, srcRemote: String, isDirectory: Bool, name: String, size: Int64) {
            self.srcFs = srcFs
            self.srcRemote = srcRemote
            self.isDirectory = isDirectory
            self.name = name
            self.size = size
        }
    }

    public var kind: TransferKind
    public var items: [Item]
    public var dstFs: String
    public var dstRemote: String
    /// Cel lokalny (do dziennika — cofnięcie pobrań = Kosz).
    public var localDestination: VFSPath?
    public var skipExisting: Bool

    public init(kind: TransferKind, items: [Item], dstFs: String, dstRemote: String, localDestination: VFSPath?, skipExisting: Bool) {
        self.kind = kind
        self.items = items
        self.dstFs = dstFs
        self.dstRemote = dstRemote
        self.localDestination = localDestination
        self.skipExisting = skipExisting
    }

    func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a.hasSuffix("/") || a.hasSuffix(":") ? a + b : a + "/" + b
    }

    /// Wykonanie (blokujące, na wątku zadania).
    public func run(rclone: Rclone, control: JobControl, journal: OperationJournal?, batchID: UUID?, progress: @Sendable (TransferProgress) -> Void) throws -> [String] {
        var p = TransferProgress()
        p.filesTotal = items.count
        p.bytesTotal = items.reduce(0) { $0 + max(0, $1.size) }
        var errors: [String] = []
        var doneBytes: Int64 = 0
        // Limit prędkości rclone jest wspólny dla procesu — ustala go koordynator ze wszystkich zadań.
        let token = UUID()
        let started = Date().addingTimeInterval(-1)
        var reported = (paused: control.isPaused, limit: control.speedLimit)
        rclone.bandwidth.update(token, paused: reported.paused, limit: reported.limit)
        defer { rclone.bandwidth.remove(token) }
        for item in items {
            guard control.checkpoint() else { throw VFSError.cancelled }
            p.currentItem = item.name
            progress(p)
            let group = "bifold-\(UUID().uuidString.prefix(8))"
            // Anulowanie: to, co rclone zdążył pobrać, zostaje na dysku — też z kwarantanną.
            func stop(_ jobid: Any) {
                _ = try? rclone.callSync("job/stop", ["jobid": jobid])
                if let local = localDestination { Quarantine.mark(local.appending(item.name).path, changedSince: started) }
            }
            var params: [String: Any] = ["_async": true, "_group": group]
            if skipExisting { params["_config"] = ["IgnoreExisting": true] }
            let method: String
            if item.isDirectory {
                method = kind == .copy ? "sync/copy" : "sync/move"
                params["srcFs"] = join(item.srcFs, item.srcRemote)
                params["dstFs"] = join(dstFs, join(dstRemote, item.name))
                if kind == .move { params["deleteEmptySrcDirs"] = true }
            } else {
                method = kind == .copy ? "operations/copyfile" : "operations/movefile"
                params["srcFs"] = item.srcFs
                params["srcRemote"] = item.srcRemote
                params["dstFs"] = dstFs
                params["dstRemote"] = join(dstRemote, item.name)
            }
            do {
                let job = try rclone.callSync(method, params)
                guard let jobid = job["jobid"] else { throw RemoteError.protocolError("jobid") }
                while true {
                    // rclone nie ma pauzy zadania — wstrzymanie zgłaszane koordynatorowi limitu (RcloneBandwidth).
                    let now = (paused: control.isPaused, limit: control.speedLimit)
                    if now != reported {
                        reported = now
                        rclone.bandwidth.update(token, paused: now.paused, limit: now.limit)
                    }
                    if control.isPaused { usleep(200_000); if control.isCancelled { stop(jobid); throw VFSError.cancelled }; continue }
                    if !control.checkpoint() {
                        stop(jobid)
                        throw VFSError.cancelled
                    }
                    let status = try rclone.callSync("job/status", ["jobid": jobid])
                    if let stats = try? rclone.callSync("core/stats", ["group": group]) {
                        let bytes = (stats["bytes"] as? NSNumber)?.int64Value ?? 0
                        p.bytesDone = doneBytes + bytes
                        p.bytesPerSecond = (stats["speed"] as? NSNumber)?.doubleValue ?? 0
                        progress(p)
                    }
                    if status["finished"] as? Bool == true {
                        // Kwarantanna także po częściowym niepowodzeniu (pobrane pliki zostają na dysku);
                        // tylko to, co zapisał rclone (scalany katalog może mieć pliki użytkownika).
                        if let local = localDestination { Quarantine.mark(local.appending(item.name).path, changedSince: started) }
                        if status["success"] as? Bool != true {
                            errors.append("\(item.name): \(status["error"] as? String ?? "?")")
                        } else if let local = localDestination {
                            if let journal, let batchID {
                                journal.record(.copied(from: VFSPath(provider: ProviderID("rclone"), path: "/" + item.srcRemote), to: local.appending(item.name)), in: batchID)
                            }
                        }
                        break
                    }
                    usleep(200_000)
                }
            } catch VFSError.cancelled {
                throw VFSError.cancelled
            } catch {
                errors.append("\(item.name): \(error.localizedDescription)")
            }
            doneBytes += max(0, item.size)
            p.bytesDone = doneBytes
            p.filesDone += 1
            progress(p)
        }
        return errors
    }
}
