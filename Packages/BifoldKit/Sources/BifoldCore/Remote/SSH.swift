import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Uruchamianie programu przez `posix_spawn` z argumentami jako dokładne bajty. `Foundation.Process`
/// zamienia argumenty na NFD, co psuje polskie nazwy na serwerach porównujących bajty (np. AIX).
public enum Spawn {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var error: Data

        public var errorText: String { String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public enum Output: Sendable {
        case capture
        /// Do pliku (procesy, które zostają w tle i trzymałyby otwarty potok, np. `ssh` z ControlPersist).
        case file(String)
    }

    /// Uruchamia i czeka. `isPaused` wstrzymuje proces sygnałem SIGSTOP, `isCancelled` kończy go.
    public static func run(
        _ executable: String, _ args: [[UInt8]], environment: [String: String], output: Output = .capture,
        timeout: TimeInterval = 120, isCancelled: @Sendable () -> Bool = { false }, isPaused: @Sendable () -> Bool = { false }
    ) throws -> Result {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        if case .capture = output {
            guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw VFSError.io(path: .local(executable), code: errno) }
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        switch output {
        case .capture:
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
            posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        case .file(let path):
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Tylko 0–2 przechodzą do procesu potomnego (bez gniazd agenta i innych deskryptorów aplikacji).
        // Domyślne obsługi i pusta maska sygnałów (proces potomny dziedziczyłby blokady wątku).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        func cString(_ bytes: [UInt8]) -> UnsafeMutablePointer<CChar>? {
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
            p[bytes.count] = 0
            return p
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ([Array(executable.utf8)] + args).map(cString) + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { cString(Array("\($0.key)=\($0.value)".utf8)) } + [nil]
        defer { (argv + envp).forEach { $0?.deallocate() } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        if case .capture = output {
            close(outPipe[1])
            close(errPipe[1])
        }
        guard rc == 0 else {
            if case .capture = output { close(outPipe[0]); close(errPipe[0]) }
            throw VFSError.io(path: .local(executable), code: rc)
        }

        let collected = Mutex<(out: Data, err: Data)>((Data(), Data()))
        let group = DispatchGroup()
        if case .capture = output {
            for (fd, isError) in [(outPipe[0], false), (errPipe[0], true)] {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    var data = Data()
                    while true {
                        let n = read(fd, &buffer, buffer.count)
                        if n <= 0 { break }
                        data.append(buffer, count: n)
                    }
                    close(fd)
                    collected.withLock { if isError { $0.err = data } else { $0.out = data } }
                    group.leave()
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var stopped = false
        var status: Int32 = 0
        var cancelled = false
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0, errno != EINTR { break }
            if isCancelled() || Date() > deadline {
                cancelled = isCancelled()
                if stopped { kill(pid, SIGCONT) }
                kill(pid, SIGTERM)
                var waited = 0
                while waitpid(pid, &status, WNOHANG) == 0 {
                    if waited == 100 { kill(pid, SIGKILL) }
                    usleep(20_000)
                    waited += 1
                }
                break
            }
            let pause = isPaused()
            if pause != stopped {
                kill(pid, pause ? SIGSTOP : SIGCONT)
                stopped = pause
            }
            usleep(20_000)
        }
        group.wait()
        if cancelled { throw VFSError.cancelled }
        let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        let (out, err) = collected.withLock { $0 }
        return Result(status: exit, output: out, error: err)
    }
}

/// Kodowanie nazw na serwerze (AIX z polską lokalizacją często używa ISO-8859-2).
public enum NameEncoding: String, Codable, Sendable, CaseIterable {
    case utf8 = "utf-8"
    case latin2 = "iso-8859-2"

    public var displayName: String { self == .utf8 ? "UTF-8" : "ISO-8859-2 (Latin-2)" }

    var encoding: String.Encoding { self == .utf8 ? .utf8 : .isoLatin2 }

    public func encode(_ s: String) throws -> [UInt8] {
        let normalized = s.precomposedStringWithCanonicalMapping
        guard let data = normalized.data(using: encoding) else { throw VFSError.invalidName(s) }
        return Array(data)
    }

    public func decode(_ data: Data) -> String {
        String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Połączenie SSH przez systemowe `ssh`/`scp` z jednym połączeniem głównym (ControlMaster) na serwer.
/// Hasło (lub hasło klucza) trafia do `ssh` jednorazowo przez kolejkę FIFO w prywatnym katalogu —
/// nigdy przez argumenty, zmienne środowiskowe ani pliki.
public final class SSHSession: Sendable {
    public struct Config: Sendable, Hashable {
        public var host: String
        public var port: Int?
        public var user: String
        public var keyFile: String
        /// Stare algorytmy (diffie-hellman-group1/14-sha1, ssh-rsa, CBC) — AIX 6.1 i podobne.
        public var legacyAlgorithms: Bool
        public var encoding: NameEncoding
        /// `nil` = konfiguracja użytkownika (~/.ssh/config, ~/.ssh/known_hosts).
        public var configFile: String?
        public var knownHostsFile: String?

        public init(host: String, port: Int? = nil, user: String = "", keyFile: String = "", legacyAlgorithms: Bool = false,
                    encoding: NameEncoding = .utf8, configFile: String? = nil, knownHostsFile: String? = nil) {
            self.host = host
            self.port = port
            self.user = user
            self.keyFile = keyFile
            self.legacyAlgorithms = legacyAlgorithms
            self.encoding = encoding
            self.configFile = configFile
            self.knownHostsFile = knownHostsFile
        }
    }

    public let config: Config
    let runDirectory: URL
    let controlPath: String
    let secret: @Sendable () -> String?
    static let ssh = "/usr/bin/ssh", scp = "/usr/bin/scp"
    private let startLock = Mutex(())

    public init(config: Config, runDirectory: URL, secret: @escaping @Sendable () -> String?) throws {
        // Bez znaków, które `ssh` mógłby wziąć za opcję albo rozdzielić (wstrzyknięcie opcji).
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:[]"))
        guard !config.host.isEmpty, !config.host.hasPrefix("-"), config.host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw VFSError.invalidName(config.host)
        }
        guard !config.user.hasPrefix("-"), config.user.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "$" }) else {
            throw VFSError.invalidName(config.user)
        }
        self.config = config
        self.runDirectory = runDirectory
        self.secret = secret
        let key = "\(config.user)@\(config.host):\(config.port ?? 22)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        controlPath = runDirectory.appending(path: "ssh-\(hash)").path
    }

    var destination: String { config.user.isEmpty ? config.host : "\(config.user)@\(config.host)" }

    /// Algorytmy obsługiwane przez lokalne `ssh` (`ssh -Q`), żeby nie podać nieznanej nazwy.
    static let supported: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for q in ["kex", "cipher", "key", "mac"] {
            let r = try? Spawn.run(ssh, [Array("-Q".utf8), Array(q.utf8)], environment: [:], timeout: 10)
            out[q] = Set(String(decoding: r?.output ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init))
        }
        return out
    }()

    static func legacyOptions() -> [String] {
        func plus(_ option: String, _ query: String, _ names: [String]) -> [String] {
            let ok = names.filter { supported[query]?.contains($0) ?? false }
            return ok.isEmpty ? [] : ["-o", "\(option)=+\(ok.joined(separator: ","))"]
        }
        return plus("KexAlgorithms", "kex", ["diffie-hellman-group14-sha1", "diffie-hellman-group-exchange-sha1", "diffie-hellman-group1-sha1"])
            + plus("HostKeyAlgorithms", "key", ["ssh-rsa"])
            + plus("PubkeyAcceptedAlgorithms", "key", ["ssh-rsa"])
            + plus("Ciphers", "cipher", ["aes128-cbc", "aes192-cbc", "aes256-cbc", "3des-cbc"])
            + plus("MACs", "mac", ["hmac-sha1", "hmac-md5"])
    }

    /// Ścieżka jako wartość opcji `-o`: `ssh` czyta ją jak wiersz konfiguracji, więc spacja (np.
    /// „Application Support”) ją rozcina — stąd cudzysłów; `%` to znacznik (`%h`), więc `%%`.
    static func pathValue(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "%", with: "%%") + "\""
    }

    /// Opcje wspólne `ssh` i `scp` (port podawany osobno: `-p` / `-P`).
    func commonOptions(master: Bool, batch: Bool = true) -> [String] {
        var o: [String] = []
        if let f = config.configFile { o += ["-F", f] }
        o += ["-o", "ControlPath=\(Self.pathValue(controlPath))", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
              "-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1"]
        // Połączenie główne pisze do pliku dziennika — tam potrzebne są komunikaty negocjacji (INFO).
        o += ["-o", master ? "LogLevel=INFO" : "LogLevel=ERROR"]
        if let k = config.knownHostsFile { o += ["-o", "UserKnownHostsFile=\(Self.pathValue(k))"] }
        if !config.keyFile.isEmpty { o += ["-i", expandTilde(config.keyFile), "-o", "IdentitiesOnly=yes"] }
        if config.legacyAlgorithms { o += Self.legacyOptions() }
        // Polecenia korzystają z połączenia głównego; bez niego nie pytają o nic (BatchMode).
        o += master ? ["-o", "ControlMaster=yes", "-o", "ControlPersist=900"] : ["-o", "ControlMaster=no"] + (batch ? ["-o", "BatchMode=yes"] : [])
        return o
    }

    var environment: [String: String] {
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = sock }
        return env
    }

    public var isConnected: Bool {
        let args = (commonOptions(master: false) + ["-O", "check", destination]).map { Array($0.utf8) }
        return (try? Spawn.run(Self.ssh, args, environment: environment, timeout: 10).status) == 0
    }

    /// Nawiązuje połączenie główne (pierwsze logowanie, także po wygaśnięciu ControlPersist).
    public func connect() throws {
        try startLock.withLock { _ in
            if isConnected { return }
            try startMaster()
        }
    }

    private func startMaster() throws {
        try? FileManager.default.removeItem(atPath: controlPath)
        var env = environment
        let fifo = runDirectory.appending(path: "askpass-\(UUID().uuidString.prefix(8))").path
        let askpass = runDirectory.appending(path: "askpass.sh").path
        let secret = secret()
        let writer = Mutex<Bool>(false)
        if let secret, !secret.isEmpty {
            try Data("#!/bin/sh\nexec /bin/cat -- \"$BIFOLD_ASKPASS_FIFO\"\n".utf8).write(to: URL(filePath: askpass))
            chmod(askpass, 0o700)
            guard mkfifo(fifo, 0o600) == 0 else { throw VFSError.io(path: .local(fifo), code: errno) }
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
            env["BIFOLD_ASKPASS_FIFO"] = fifo
            // Zapis jednorazowy, gdy `ssh` otworzy kolejkę do odczytu; potem kolejka znika.
            let bytes = Array((secret + "\n").utf8)
            Thread.detachNewThread {
                while !writer.withLock({ $0 }) {
                    let fd = open(fifo, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 {
                        _ = fcntl(fd, F_SETFL, 0)
                        bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
                        close(fd)
                        unlink(fifo)
                        return
                    }
                    usleep(20_000)
                }
            }
        }
        defer {
            writer.withLock { $0 = true }
            unlink(fifo)
        }
        let log = runDirectory.appending(path: "ssh-\(UUID().uuidString.prefix(8)).log").path
        defer { unlink(log) }
        var args = commonOptions(master: true)
        if secret == nil || secret!.isEmpty { args += ["-o", "BatchMode=yes"] }
        if let port = config.port { args += ["-p", String(port)] }
        args += ["-N", "-f", destination]
        let r = try Spawn.run(Self.ssh, args.map { Array($0.utf8) }, environment: env, output: .file(log), timeout: 60)
        guard r.status == 0 else {
            let message = (try? String(contentsOfFile: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteError.ssh(Self.explain(message))
        }
    }

    static func explain(_ message: String) -> String {
        if message.contains("no matching") || message.contains("Unable to negotiate") {
            return message + " — " + L10n.tr("włącz „Zgodność ze starymi serwerami” w połączeniu")
        }
        if message.contains("Permission denied") { return L10n.tr("Odmowa dostępu (sprawdź użytkownika, hasło albo klucz)") }
        if message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || message.contains("Host key verification failed") {
            return L10n.tr("Klucz serwera nie zgadza się z zapamiętanym w ~/.ssh/known_hosts — możliwy atak lub zmiana serwera")
        }
        return message.isEmpty ? L10n.tr("Nie udało się połączyć") : message
    }

    /// Plik znanych kluczy serwerów, którego używa ta sesja.
    public var knownHostsPath: String { config.knownHostsFile ?? NSHomeDirectory() + "/.ssh/known_hosts" }

    /// Zaufanie przy pierwszym połączeniu (jak `StrictHostKeyChecking=accept-new`): zapisuje klucz
    /// nowego serwera do known_hosts bez logowania. Znany serwer z innym kluczem — błąd.
    public func recordHostKey() throws {
        try? FileManager.default.createDirectory(atPath: (knownHostsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Pierwsze wystąpienie opcji wygrywa — własne ustawienia przed wspólnymi.
        var args = ["-o", "PreferredAuthentications=none", "-o", "UserKnownHostsFile=\(Self.pathValue(knownHostsPath))"] + commonOptions(master: false)
        if let port = config.port { args += ["-p", String(port)] }
        args += [destination, "exit"]
        let r = try Spawn.run(Self.ssh, args.map { Array($0.utf8) }, environment: environment, timeout: 30)
        let text = r.errorText
        if text.contains("IDENTIFICATION HAS CHANGED") || text.contains("Host key verification failed") || text.contains("Unable to negotiate") {
            throw RemoteError.ssh(Self.explain(text))
        }
    }

    /// Algorytmy klucza serwera zgodne z kluczami zapisanymi w known_hosts (rclone wybrałby inny typ
    /// klucza niż zapisany i odrzucił połączenie jako „key mismatch”).
    public func knownHostKeyAlgorithms() -> [String] {
        let name = config.port.map { $0 == 22 ? config.host : "[\(config.host)]:\($0)" } ?? config.host
        let args = ["-F", name, "-f", knownHostsPath].map { Array($0.utf8) }
        guard let r = try? Spawn.run("/usr/bin/ssh-keygen", args, environment: environment, timeout: 10), r.status == 0 else { return [] }
        var out: [String] = []
        for line in String(decoding: r.output, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            guard fields.count >= 2 else { continue }
            let type = String(fields[1])
            let algorithms = type == "ssh-rsa" ? ["rsa-sha2-512", "rsa-sha2-256"] + (config.legacyAlgorithms ? ["ssh-rsa"] : []) : [type]
            for a in algorithms where !out.contains(a) { out.append(a) }
        }
        return out
    }

    /// Argumenty `ssh` dla terminala w panelu: przez połączenie główne (bez ponownego logowania),
    /// z terminalem (-t). Gdy połączenie główne wygaśnie, `ssh` zapyta o hasło w terminalu (bez BatchMode).
    public func terminalArguments(remoteCommand: String?) -> [String] {
        var args = commonOptions(master: false, batch: false) + ["-t"]
        if let port = config.port { args += ["-p", String(port)] }
        args.append(destination)
        if let remoteCommand { args.append(remoteCommand) }
        return args
    }

    /// Polecenie startowe terminala: przejście do katalogu i powłoka logowania. Tylko dla powłok,
    /// które znają `-l` (ksh88 z AIX nie zna — wtedy zwykłe logowanie w katalogu domowym) i dla
    /// ścieżek, które da się przekazać (nazwy ISO-8859-2 z polskimi znakami — nie).
    public static func loginCommand(directory: String?, shell: String, encoding: NameEncoding) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        let name = (shell as NSString).lastPathComponent
        guard ["bash", "zsh", "ksh93", "mksh", "dash", "fish"].contains(name) else { return nil }
        if encoding != .utf8, directory.unicodeScalars.contains(where: { !$0.isASCII }) { return nil }
        return "cd \(shellQuote(directory)) && exec \(shellQuote(shell)) -l"
    }

    public func disconnect() {
        let args = (commonOptions(master: false) + ["-O", "exit", destination]).map { Array($0.utf8) }
        _ = try? Spawn.run(Self.ssh, args, environment: environment, timeout: 10)
    }

    /// Polecenie powłoki na serwerze (tekst w kodowaniu serwera). Ponawia raz po zerwaniu połączenia.
    public func run(_ command: String, timeout: TimeInterval = 120) throws -> Spawn.Result {
        try connect()
        var args = commonOptions(master: false).map { Array($0.utf8) }
        if let port = config.port { args += [Array("-p".utf8), Array(String(port).utf8)] }
        args += [Array(destination.utf8), try config.encoding.encode(command)]
        let r = try Spawn.run(Self.ssh, args, environment: environment, timeout: timeout)
        if r.status == 255, !isConnected {
            try connect()
            return try Spawn.run(Self.ssh, args, environment: environment, timeout: timeout)
        }
        return r
    }

    /// `scp -O` (klasyczny protokół SCP, bez SFTP). `remote` to ścieżka absolutna na serwerze.
    public func scp(download remote: String, to local: String, isCancelled: @escaping @Sendable () -> Bool, isPaused: @escaping @Sendable () -> Bool) throws {
        try connect()
        let source = Array("\(destination):".utf8) + (try Self.scpEscape(remote, config.encoding))
        try runScp([source, Array(local.utf8)], isCancelled: isCancelled, isPaused: isPaused)
    }

    public func scp(upload local: String, to remote: String, isCancelled: @escaping @Sendable () -> Bool, isPaused: @escaping @Sendable () -> Bool) throws {
        try connect()
        let target = Array("\(destination):".utf8) + (try Self.scpEscape(remote, config.encoding))
        try runScp([Array(local.utf8), target], isCancelled: isCancelled, isPaused: isPaused)
    }

    private func runScp(_ paths: [[UInt8]], isCancelled: @escaping @Sendable () -> Bool, isPaused: @escaping @Sendable () -> Bool) throws {
        var args = (["-O", "-p", "-q"] + commonOptions(master: false)).map { Array($0.utf8) }
        if let port = config.port { args += [Array("-P".utf8), Array(String(port).utf8)] }
        args += paths
        let r = try Spawn.run(Self.scp, args, environment: environment, timeout: 24 * 3600, isCancelled: isCancelled, isPaused: isPaused)
        guard r.status == 0 else { throw RemoteError.ssh(Self.explain(r.errorText)) }
    }

    /// Cudzysłów powłoki POSIX (ksh na AIX, sh, bash).
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Ścieżka zdalna dla `scp -O`: odwrotny ukośnik przed każdym znakiem ASCII spoza [A-Za-z0-9/._-].
    /// Działa jednocześnie dla powłoki serwera i dla kontroli nazw klienta (fnmatch); apostrofy
    /// tej kontroli nie przechodzą („filename does not match request”).
    public static func scpEscape(_ path: String, _ encoding: NameEncoding) throws -> [UInt8] {
        var out: [UInt8] = []
        for b in try encoding.encode(path) {
            let c = Character(Unicode.Scalar(b))
            if b < 0x80, !(c.isLetter || c.isNumber || "/._-".contains(c)) {
                guard b >= 0x20, b != 0x7f else { throw VFSError.invalidName(path) }
                out.append(0x5c)
            }
            out.append(b)
        }
        return out
    }
}
