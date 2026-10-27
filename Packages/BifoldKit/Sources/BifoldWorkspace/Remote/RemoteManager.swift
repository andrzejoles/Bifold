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
    /// Bez silnej referencji: `Workspace` trzyma menedżera (`remotes`) i żyje dłużej od niego.
    @ObservationIgnored unowned let workspace: Workspace
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

    /// Czy alias jest zdefiniowany (także gdy nie jest połączony) — ścieżka `remote:<alias>` bez
    /// zarejestrowanego dostawcy nie jest wtedy martwa: `provider(alias)` połączy się ponownie.
    public func isKnown(alias: String) -> Bool { connection(alias) != nil }

    public func save(_ c: RemoteConnection, secret: String?) throws {
        try RemoteFS.validateAlias(c.alias)
        connections.removeAll { $0.alias == c.alias }
        connections.append(c)
        connections.sort { $0.alias < $1.alias }
        if let secret { try keychain.set(secret, for: c.alias) }
        try JSONStore.save(connections, to: url)
        // Zmieniony host/użytkownik: stara sesja SSH (także terminali) nie może zostać, a stary dostawca
        // nie może zostać zarejestrowany — karta łączyłaby się nim ze starym hostem (z nowym hasłem).
        // Trwające łączenie (ze starymi danymi) jest przerywane, zanim zarejestruje dostawcę.
        let interrupted = drop(c.alias)
        // Karty tego połączenia nie zostają bez dostawcy (Ctrl+R „nieobsługiwany dostawca”, Wstecz gubiłby
        // historię): połączenie z nowymi danymi zestawiane od razu w tle — po zakończeniu przerwanego
        // łączenia (jego sprzątanie nie trafi w nowe). Błąd (np. złe hasło) zobaczy karta.
        let id = RemoteFS.providerID(c.alias)
        if (workspace.left.tabs + workspace.right.tabs).contains(where: { $0.usedProviders.contains(id) }) {
            let alias = c.alias
            Task { [weak self] in
                _ = try? await interrupted?.value
                _ = try? await self?.provider(alias)
            }
        }
    }

    public func remove(_ alias: String) throws {
        connections.removeAll { $0.alias == alias }
        keychain.delete(alias)
        drop(alias)
        try JSONStore.save(connections, to: url)
    }

    /// Zapomina połączenie aliasu: przerywa łączenie, zamyka sesję SSH (zadania w tle z nią kończą się
    /// anulowaniem zamiast zestawiać nowe połączenie główne) i wyrejestrowuje dostawcę. Połączenie główne
    /// jest kończone tylko, gdy nie korzysta z niego inny alias. Zwraca przerwane łączenie.
    @discardableResult
    private func drop(_ alias: String) -> Task<any RemoteFileProvider, any Error>? {
        let interrupted = connecting.removeValue(forKey: alias)
        interrupted?.cancel()
        defer { workspace.providers.unregister(RemoteFS.providerID(alias)) }
        let scp = scpSessions.removeValue(forKey: alias)
        let session = sshSessions.removeValue(forKey: alias)
        scp?.session.invalidate()
        session?.invalidate()
        if let session = session ?? scp?.session { unshared(session)?.disconnect() }
        connected.remove(alias)
        return interrupted
    }

    /// Katalog na gniazda (rclone, połączenia główne SSH). Limit sun_path to 104 B, a `ssh` dokleja
    /// do ścieżki 17 znaków — przy długiej ścieżce prywatny katalog 0700 w /tmp (gniazda bez
    /// uwierzytelnienia muszą być niedostępne dla innych użytkowników). Katalog w /tmp ma stałą nazwę
    /// (skrót katalogu danych) i jest usuwany przy `stop()` — wcześniej każdy Workspace zostawiał nowy.
    func socketDirectory() throws -> URL {
        if let socketDir { return socketDir }
        var dir = workspace.paths.run
        if dir.path.utf8.count + 40 > 100 {
            dir = try Self.privateTemporaryDirectory(for: dir.path)
            ownsSocketDir = true
        }
        socketDir = dir
        return dir
    }

    /// `/tmp/bifold-<uid>-<skrót>`: utworzony z 0700 albo istniejący, ale tylko jeśli to zwykły katalog
    /// (nie dowiązanie) bieżącego użytkownika z prawami 0700 — inaczej (np. podrzucony przez innego
    /// użytkownika) nowy katalog o losowej nazwie.
    static func privateTemporaryDirectory(for key: String) throws -> URL {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let stable = "/tmp/bifold-\(getuid())-\(String(hash, radix: 36).prefix(8))"
        for candidate in [stable, "/tmp/bifold-\(getuid())-\(UUID().uuidString.prefix(8))"] {
            if mkdir(candidate, 0o700) == 0 { return URL(filePath: candidate, directoryHint: .isDirectory) }
            var st = stat()
            if errno == EEXIST, lstat(candidate, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 {
                return URL(filePath: candidate, directoryHint: .isDirectory)
            }
        }
        throw VFSError.io(path: .local(stable), code: EEXIST)
    }

    @ObservationIgnored private var socketDir: URL?
    /// Katalog gniazd w /tmp utworzony przez ten menedżer (usuwany przy `stop()`).
    @ObservationIgnored private var ownsSocketDir = false
    @ObservationIgnored private var scpSessions: [String: ScpFS] = [:]
    /// Jedna sesja SSH na serwer (gniazdo połączenia głównego) — wspólna dla SCP i terminali.
    @ObservationIgnored private var sshSessions: [String: SSHSession] = [:]
    /// Trwające łączenie (drugie wywołanie `provider` czeka na to samo zamiast rozłączać pierwsze).
    @ObservationIgnored var connecting: [String: Task<any RemoteFileProvider, any Error>] = [:]
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
        // Nowy proces rclone nie zna wcześniejszych zasobów — ale połączenia SCP (własne sesje SSH) zostają.
        connected = connected.filter { scpSessions[$0] != nil }
        return r
    }

    /// Zasób gotowy do użycia (połączenie tworzone przy pierwszym dostępie).
    public func provider(_ alias: String) async throws -> any RemoteFileProvider {
        guard let c = connection(alias) else { throw RemoteError.unknownRemote(alias) }
        if connected.contains(alias), let p = try? workspace.providers.provider(for: RemoteFS.providerID(alias)) as? any RemoteFileProvider { return p }
        if let pending = connecting[alias] { return try await pending.value }
        let task = Task { try await self.establish(c) }
        connecting[alias] = task
        defer { if connecting[alias] == task { connecting[alias] = nil } }
        return try await task.value
    }

    /// Sesja SSH serwera — jedna na alias (i gniazdo połączenia głównego), wspólna dla SCP i terminala;
    /// po zmianie konfiguracji stara jest zamykana.
    func sshSession(_ c: RemoteConnection) throws -> SSHSession {
        let config = ScpFS.sessionConfig(c, sshConfigFile: sshConfigFile, knownHostsFile: sshKnownHostsFile)
        if let existing = sshSessions[c.alias], existing.config == config { return existing }
        if let old = sshSessions.removeValue(forKey: c.alias) { unshared(old)?.disconnect() }
        let keychain = keychain, alias = c.alias
        let session = try SSHSession(config: config, runDirectory: try socketDirectory(), secret: { keychain.get(alias) })
        sshSessions[c.alias] = session
        return session
    }

    /// Sesja, której połączenie główne można zamknąć: żaden alias nie korzysta już z jej gniazda.
    /// Aliasy tego samego `użytkownik@host:port` dzielą ControlMaster — `ssh -O exit` przy „Rozłącz B”
    /// zakończyłby terminal i pliki aliasu A. `nil` — gniazdo nadal w użyciu.
    private func unshared(_ session: SSHSession) -> SSHSession? {
        let inUse = sshSessions.values.contains { $0.controlPath == session.controlPath }
            || scpSessions.values.contains { $0.session.controlPath == session.controlPath }
        return inUse ? nil : session
    }

    /// Aliasy korzystające z tego samego połączenia głównego SSH co `alias` (łącznie z nim).
    public func aliasesSharingSession(with alias: String) -> Set<String> {
        guard let c = connection(alias), c.kind.usesSSH, let dir = try? socketDirectory() else { return [alias] }
        func path(_ c: RemoteConnection) -> String {
            SSHSession.controlPath(for: ScpFS.sessionConfig(c, sshConfigFile: sshConfigFile, knownHostsFile: sshKnownHostsFile), in: dir)
        }
        let own = path(c)
        return Set(connections.filter { $0.kind.usesSSH && path($0) == own }.map(\.alias)).union([alias])
    }

    private func establish(_ c: RemoteConnection) async throws -> any RemoteFileProvider {
        let alias = c.alias
        if c.kind == .scp {
            scpSessions.removeValue(forKey: alias)
            let session = try sshSession(c)
            let fs = try await ScpFS.connect(c, runDirectory: try socketDirectory(), session: session) { nil }
            // „Rozłącz” w trakcie łączenia: bez rejestracji, połączenie główne zamknięte.
            if Task.isCancelled {
                if sshSessions[alias] === session { sshSessions[alias] = nil }
                if let unused = unshared(session) { _ = try? await runBlocking(qos: .userInitiated) { unused.disconnect() } }
                throw CancellationError()
            }
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
        if Task.isCancelled {
            // Bez usuwania zasobu nowszego łączenia tego aliasu (np. po zapisie zmian połączenia).
            if connecting[alias] == nil, !connected.contains(alias) { _ = try? await rc.call("config/delete", ["name": alias]) }
            throw CancellationError()
        }
        workspace.providers.register(fs)
        connected.insert(alias)
        return fs
    }

    /// Terminal SSH dla połączenia SFTP/SCP: połączenie główne (hasło z Pęku kluczy, bez pytania),
    /// potem `ssh -t` przez nie — w katalogu `directory`, jeśli powłoka serwera na to pozwala.
    public func terminalSpec(_ alias: String, directory: String?) async throws -> TerminalSpec {
        guard let c = connection(alias) else { throw RemoteError.unknownRemote(alias) }
        guard c.kind.usesSSH else { throw RemoteError.ssh(L10n.tr("Terminal SSH działa dla połączeń SFTP i SCP")) }
        let session = try scpSessions[alias]?.session ?? sshSession(c)
        let shell = try await runBlocking(qos: .userInitiated) { () -> String in
            try session.connect()
            // Znacznik: `.bashrc`, który coś wypisuje, nie może zepsuć nazwy powłoki.
            let r = try session.run(SSHSession.markedOutput("echo $SHELL"))
            return SSHSession.textAfterMarker(session.config.encoding.decode(r.output)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let command = SSHSession.loginCommand(directory: directory, shell: shell, encoding: session.config.encoding)
        return TerminalSpec(alias: alias, executable: "/usr/bin/ssh", arguments: session.terminalArguments(remoteCommand: command), term: c.effectiveTerminalType)
    }

    /// Zamyka połączenie: sesję SSH (SCP), zasób w pamięci rclone (SFTP, FTP, WebDAV, chmury),
    /// edycje plików z tego serwera. Karty przenosi wywołujący (komenda `remote.disconnect`).
    public func disconnect(_ alias: String) async {
        connecting.removeValue(forKey: alias)?.cancel()
        let scp = scpSessions.removeValue(forKey: alias)
        let ssh = sshSessions.removeValue(forKey: alias)
        // Zadania w tle (wysyłanie, pobieranie) trzymające tę sesję kończą się anulowaniem — nie zestawią
        // po cichu nowego połączenia głównego.
        scp?.session.invalidate()
        ssh?.invalidate()
        // Zamknięcie połączenia głównego kończy też terminale SSH tego serwera — chyba że z tego samego
        // gniazda korzysta inny alias (ten sam użytkownik@host:port).
        if let session = ssh ?? scp?.session, let unused = unshared(session) {
            _ = try? await runBlocking(qos: .userInitiated) { unused.disconnect() }
        }
        if let rclone, rclone.isRunning, connected.contains(alias) {
            _ = try? await rclone.call("config/delete", ["name": alias])
            _ = try? await rclone.call("fscache/clear", [:])
        }
        for (key, session) in editSessions where RemoteFS.alias(of: session.remote) == alias {
            session.stop()
            editSessions[key] = nil
        }
        workspace.providers.unregister(RemoteFS.providerID(alias))
        connected.remove(alias)
    }

    /// Zasób przez rclone (synchronizacja, wyszukiwanie, przesyłanie między serwerami).
    public func rcloneProvider(_ alias: String) async throws -> RemoteFS {
        guard let fs = try await provider(alias) as? RemoteFS else {
            throw RemoteError.ssh(L10n.tr("Ta operacja nie działa dla połączeń SCP — skopiuj pliki na dysk"))
        }
        return fs
    }

    public func stop() {
        connecting.values.forEach { $0.cancel() }
        connecting = [:]
        sshSessions.values.forEach { $0.disconnect() }
        for fs in scpSessions.values where !sshSessions.values.contains(where: { $0 === fs.session }) { fs.disconnect() }
        scpSessions = [:]
        sshSessions = [:]
        rclone?.stop()
        rclone = nil
        connected = []
        editSessions.values.forEach { $0.stop() }
        editSessions = [:]
        // Własny katalog gniazd w /tmp (połączenia główne już zamknięte) — nie zostaje po zamknięciu.
        if ownsSocketDir, let dir = socketDir {
            try? FileManager.default.removeItem(at: dir)
            socketDir = nil
            ownsSocketDir = false
        }
    }

    /// Czy połączenie ma otwarte edycje plików (agent nie może ich przerwać rozłączeniem).
    public func hasEditSessions(_ alias: String) -> Bool {
        editSessions.values.contains { RemoteFS.alias(of: $0.remote) == alias }
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
        // Ponowna edycja tej samej ścieżki: stara obserwacja kończy się (i jej kopia znika).
        editSessions[path.description]?.stop()
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
    /// Wysyłka zaplanowana po ostatnim zdarzeniu (każdy kolejny zapis ją przesuwa).
    private var pending: Task<Void, Never>?
    /// Trwająca wysyłka. Wysyłki jednej edycji idą po kolei — dwie naraz mogłyby skończyć się w odwrotnej
    /// kolejności i starsza treść wygrałaby na serwerze.
    private var uploading: Task<Void, Never>?
    /// Zapis w trakcie wysyłki: po jej końcu jeszcze jedna (wszystkie takie zapisy razem).
    private var dirty = false
    /// Opóźnienie wysyłki od ostatniego zdarzenia (edytory zapisują w kilku krokach).
    var delay: Duration = .milliseconds(500)

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

    /// Koniec edycji: obserwacja i lokalna kopia (katalog `bifold-remote-…` / `.bifold-scp-…` z
    /// pobrania) znikają. Zaplanowana i trwająca wysyłka ostatniego zapisu jeszcze się wykonają.
    func stop() {
        source?.cancel()
        source = nil
        let dir = local.deletingLastPathComponent()
        let name = dir.lastPathComponent
        guard name.hasPrefix("bifold-remote-") || name.hasPrefix(".bifold-scp-") else { return }
        if pending != nil || uploading != nil {
            Task {
                await finished()
                try? FileManager.default.removeItem(at: dir)
            }
        } else {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Czeka, aż zaplanowane i trwające wysyłki się skończą.
    func finished() async {
        while pending != nil || uploading != nil {
            if let pending { await pending.value } else if let uploading { await uploading.value }
        }
    }

    /// Zdarzenie w katalogu kopii: wysyłka po `delay` od ostatniego.
    func changed() {
        pending?.cancel()
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.flush()
        }
    }

    /// Wysyła bieżącą treść — albo, gdy wysyłka już trwa, zaznacza, że po niej trzeba wysłać jeszcze raz.
    private func flush() {
        guard uploading == nil else {
            dirty = true
            return
        }
        let local = local, remote = remote, fs = fs
        uploading = Task { [weak self] in
            repeat {
                self?.dirty = false
                do {
                    try await fs.upload(local, to: remote)
                    self?.report(L10n.tr("Wysłano \(remote.name) na \(fs.connection.alias)"))
                } catch {
                    self?.report(L10n.tr("Nie udało się wysłać \(remote.name): \(error.localizedDescription)"))
                }
            } while self?.dirty == true
            self?.uploading = nil
        }
    }
}
