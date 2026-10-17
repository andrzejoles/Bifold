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
    public static func connect(_ c: RemoteConnection, secret: String?, rclone: Rclone) async throws -> RemoteFS {
        try validateAlias(c.alias)
        _ = try await rclone.call("config/create", [
            "name": c.alias, "type": c.kind.backend, "parameters": c.rcloneParameters(secret: secret),
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
    /// Nazwa systemu plików rclone (`alias:`).
    public var fs: String { connection.alias + ":" }

    /// Ścieżka po stronie rclone (względem korzenia połączenia).
    public func remotePath(_ path: VFSPath) -> String {
        let base = connection.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let inner = String(path.path.dropFirst())
        if base.isEmpty { return inner }
        return inner.isEmpty ? base : base + "/" + inner
    }

    func item(_ e: Rclone.ListEntry, in dir: VFSPath) -> FileItem {
        FileItem(path: dir.appending(e.name), kind: e.isDirectory ? .directory : .file, size: e.isDirectory ? -1 : e.size, modified: e.modified)
    }

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        let entries = try await rclone.list(fs: fs, remote: remotePath(directory))
        let items = entries.map { item($0, in: directory) }
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
        _ = try await rclone.call("operations/copyfile", ["srcFs": fs, "srcRemote": remotePath(path), "dstFs": dir.path, "dstRemote": path.name])
        return dir.appending(path: path.name)
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
        _ = try await rclone.call("operations/mkdir", ["fs": fs, "remote": remotePath(path)])
    }

    public func createFile(_ path: VFSPath, contents: Data) async throws {
        try validateFileName(path.name)
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
        for item in items {
            guard control.checkpoint() else { throw VFSError.cancelled }
            p.currentItem = item.name
            progress(p)
            let group = "bifold-\(UUID().uuidString.prefix(8))"
            _ = try? rclone.callSync("core/bwlimit", ["rate": control.speedLimit > 0 ? "\(control.speedLimit)" : "off"])
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
                let started = try rclone.callSync(method, params)
                guard let jobid = started["jobid"] else { throw RemoteError.protocolError("jobid") }
                var wasPaused = false
                while true {
                    // rclone nie ma pauzy zadania — wstrzymanie = limit 1 B/s, wznowienie = limit z zadania.
                    if control.isPaused != wasPaused {
                        wasPaused = control.isPaused
                        _ = try? rclone.callSync("core/bwlimit", ["rate": wasPaused ? "1" : (control.speedLimit > 0 ? "\(control.speedLimit)" : "off")])
                    }
                    if control.isPaused { usleep(200_000); if control.isCancelled { _ = try? rclone.callSync("job/stop", ["jobid": jobid]); throw VFSError.cancelled }; continue }
                    if !control.checkpoint() {
                        _ = try? rclone.callSync("job/stop", ["jobid": jobid])
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
                        if status["success"] as? Bool != true {
                            errors.append("\(item.name): \(status["error"] as? String ?? "?")")
                        } else if let local = localDestination, let journal, let batchID {
                            journal.record(.copied(from: VFSPath(provider: ProviderID("rclone"), path: "/" + item.srcRemote), to: local.appending(item.name)), in: batchID)
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
