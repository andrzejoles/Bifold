import BifoldCore
import Foundation
import NetFS
import Observation

/// Połączenia z serwerami: definicje (bez sekretów) w `connections.json`, sekrety w Keychain,
/// rclone uruchamiany przy pierwszym użyciu, zasoby tworzone w jego pamięci.
@MainActor @Observable
public final class RemoteManager {
    public private(set) var connections: [RemoteConnection] = []
    public private(set) var connected: Set<String> = []
    @ObservationIgnored let workspace: Workspace
    @ObservationIgnored public let keychain: KeychainStore
    @ObservationIgnored private var rclone: Rclone?
    @ObservationIgnored private var editSessions: [String: RemoteEditSession] = [:]

    init(workspace: Workspace, keychainService: String) {
        self.workspace = workspace
        keychain = KeychainStore(service: keychainService)
        connections = JSONStore.load([RemoteConnection].self, from: url) ?? []
    }

    var url: URL { workspace.paths.root.appending(path: "connections.json") }

    public func connection(_ alias: String) -> RemoteConnection? { connections.first { $0.alias == alias } }

    public func save(_ c: RemoteConnection, secret: String?) throws {
        try RemoteFS.validateAlias(c.alias)
        connections.removeAll { $0.alias == c.alias }
        connections.append(c)
        connections.sort { $0.alias < $1.alias }
        if let secret { try keychain.set(secret, for: c.alias) }
        try JSONStore.save(connections, to: url)
        connected.remove(c.alias)
    }

    public func remove(_ alias: String) throws {
        connections.removeAll { $0.alias == alias }
        keychain.delete(alias)
        try JSONStore.save(connections, to: url)
        workspace.providers.unregister(RemoteFS.providerID(alias))
        connected.remove(alias)
    }

    public func runningRclone() throws -> Rclone {
        if let rclone, rclone.isRunning { return rclone }
        guard let exe = workspace.settings.toolPath("rclone") else { throw RemoteError.toolMissing }
        var socket = workspace.paths.run.appending(path: "rclone.sock")
        if socket.path.utf8.count > 100 {
            // Limit sun_path (104 B): prywatny katalog 0700 w /tmp (gniazdo bez uwierzytelnienia
            // musi być niedostępne dla innych użytkowników).
            let dir = URL(filePath: "/tmp/bifold-\(getuid())-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            socket = dir.appending(path: "rclone.sock")
        }
        let r = Rclone(executable: exe, socket: socket)
        try r.start()
        rclone = r
        connected = []
        return r
    }

    /// Zasób gotowy do użycia (połączenie tworzone przy pierwszym dostępie).
    public func provider(_ alias: String) async throws -> RemoteFS {
        guard let c = connection(alias) else { throw RemoteError.unknownRemote(alias) }
        if connected.contains(alias), let p = try? workspace.providers.provider(for: RemoteFS.providerID(alias)) as? RemoteFS { return p }
        let rc = try runningRclone()
        let fs = try await RemoteFS.connect(c, secret: keychain.get(alias), rclone: rc)
        workspace.providers.register(fs)
        connected.insert(alias)
        return fs
    }

    public func stop() {
        rclone?.stop()
        rclone = nil
        connected = []
        editSessions.values.forEach { $0.stop() }
        editSessions = [:]
    }

    // MARK: SMB/NFS przez NetFS

    /// Montuje udział SMB/NFS (`smb://host/udzial`, `nfs://…`) i zwraca punkt montowania.
    public func mount(_ urlString: String, user: String?, password: String?) async throws -> VFSPath {
        guard let url = URL(string: urlString) else { throw VFSError.invalidName(urlString) }
        let mountPoint = try await runBlocking(qos: .userInitiated) { () -> String in
            var points: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(url as CFURL, nil, user as CFString?, password as CFString?, nil, nil, &points)
            guard status == 0, let array = points?.takeRetainedValue() as? [String], let first = array.first else {
                throw VFSError.io(path: .local(urlString), code: status)
            }
            return first
        }
        workspace.refreshVolumes()
        return .local(mountPoint)
    }

    // MARK: Edycja plików zdalnych

    /// Pobiera plik, otwiera w edytorze i wysyła po każdym zapisie.
    public func edit(_ path: VFSPath) async throws -> URL {
        guard let alias = RemoteFS.alias(of: path) else { throw VFSError.unsupported("edit") }
        let fs = try await provider(alias)
        let local = try await fs.download(path)
        let session = RemoteEditSession(local: local, remote: path, fs: fs) { [weak self] message in
            self?.workspace.setStatus(message)
        }
        editSessions[path.description] = session
        session.start()
        return local
    }
}

/// Obserwuje lokalną kopię pliku zdalnego i wysyła ją po zapisie.
@MainActor
final class RemoteEditSession {
    let local: URL
    let remote: VFSPath
    let fs: RemoteFS
    let report: (String) -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var lastUpload = Date.distantPast

    init(local: URL, remote: VFSPath, fs: RemoteFS, report: @escaping (String) -> Void) {
        self.local = local
        self.remote = remote
        self.fs = fs
        self.report = report
    }

    func start() {
        // Edytory często zapisują przez zamianę pliku — obserwujemy katalog.
        let fd = open(local.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() { source?.cancel() }

    private func changed() {
        guard Date().timeIntervalSince(lastUpload) > 0.5 else { return }
        lastUpload = Date()
        let local = local, remote = remote, fs = fs
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            do {
                try await fs.upload(local, to: remote)
                report(L10n.tr("Wysłano \(remote.name) na \(fs.connection.alias)"))
            } catch {
                report(L10n.tr("Nie udało się wysłać \(remote.name): \(error.localizedDescription)"))
            }
        }
    }
}
