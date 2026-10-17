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
        scpSessions.removeValue(forKey: c.alias)?.disconnect()
    }

    public func remove(_ alias: String) throws {
        connections.removeAll { $0.alias == alias }
        keychain.delete(alias)
        scpSessions.removeValue(forKey: alias)?.disconnect()
        try JSONStore.save(connections, to: url)
        workspace.providers.unregister(RemoteFS.providerID(alias))
        connected.remove(alias)
    }

    /// Katalog na gniazda (rclone, połączenia główne SSH). Limit sun_path to 104 B, a `ssh` dokleja
    /// do ścieżki 17 znaków — przy długiej ścieżce prywatny katalog 0700 w /tmp (gniazda bez
    /// uwierzytelnienia muszą być niedostępne dla innych użytkowników).
    func socketDirectory() throws -> URL {
        if let socketDir { return socketDir }
        var dir = workspace.paths.run
        if dir.path.utf8.count + 40 > 100 {
            dir = URL(filePath: "/tmp/bifold-\(getuid())-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        socketDir = dir
        return dir
    }

    @ObservationIgnored private var socketDir: URL?
    @ObservationIgnored private var scpSessions: [String: ScpFS] = [:]
    /// Testy: własna konfiguracja SSH zamiast ~/.ssh/config i ~/.ssh/known_hosts.
    @ObservationIgnored public var sshConfigFile: String?
    @ObservationIgnored public var sshKnownHostsFile: String?

    public func runningRclone() throws -> Rclone {
        if let rclone, rclone.isRunning { return rclone }
        guard let exe = workspace.settings.toolPath("rclone") else { throw RemoteError.toolMissing }
        let socket = try socketDirectory().appending(path: "rclone.sock")
        let r = Rclone(executable: exe, socket: socket)
        try r.start()
        rclone = r
        connected = []
        return r
    }

    /// Zasób gotowy do użycia (połączenie tworzone przy pierwszym dostępie).
    public func provider(_ alias: String) async throws -> any RemoteFileProvider {
        guard let c = connection(alias) else { throw RemoteError.unknownRemote(alias) }
        if connected.contains(alias), let p = try? workspace.providers.provider(for: RemoteFS.providerID(alias)) as? any RemoteFileProvider { return p }
        if c.kind == .scp {
            let keychain = keychain
            let fs = try await ScpFS.connect(c, runDirectory: try socketDirectory(), sshConfigFile: sshConfigFile, knownHostsFile: sshKnownHostsFile) {
                keychain.get(alias)
            }
            scpSessions[alias]?.disconnect()
            scpSessions[alias] = fs
            workspace.providers.register(fs)
            connected.insert(alias)
            return fs
        }
        let rc = try runningRclone()
        var knownHosts: String?
        var hostKeyAlgorithms: [String] = []
        if c.kind == .sftp {
            let session = try SSHSession(config: .init(host: c.host, port: c.port, user: c.user, keyFile: c.keyFile, legacyAlgorithms: c.legacyAlgorithms ?? false,
                                                       configFile: sshConfigFile, knownHostsFile: sshKnownHostsFile),
                                         runDirectory: try socketDirectory(), secret: { nil })
            hostKeyAlgorithms = try await runBlocking(qos: .userInitiated) {
                try session.recordHostKey()
                return session.knownHostKeyAlgorithms()
            }
            knownHosts = session.knownHostsPath
        }
        let fs = try await RemoteFS.connect(c, secret: keychain.get(alias), rclone: rc, knownHostsFile: knownHosts, hostKeyAlgorithms: hostKeyAlgorithms)
        workspace.providers.register(fs)
        connected.insert(alias)
        return fs
    }

    /// Zasób przez rclone (synchronizacja, wyszukiwanie, przesyłanie między serwerami).
    public func rcloneProvider(_ alias: String) async throws -> RemoteFS {
        guard let fs = try await provider(alias) as? RemoteFS else {
            throw RemoteError.ssh(L10n.tr("Ta operacja nie działa dla połączeń SCP — skopiuj pliki na dysk"))
        }
        return fs
    }

    public func stop() {
        for fs in scpSessions.values { fs.disconnect() }
        scpSessions = [:]
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
    let fs: any RemoteFileProvider
    let report: (String) -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var lastUpload = Date.distantPast

    init(local: URL, remote: VFSPath, fs: any RemoteFileProvider, report: @escaping (String) -> Void) {
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
