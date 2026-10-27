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

    /// - Parameter session: wspólna sesja SSH serwera (jedna na gniazdo połączenia głównego — także dla
    ///   terminala); `nil` — nowa.
    public static func connect(_ c: RemoteConnection, runDirectory: URL, sshConfigFile: String? = nil, knownHostsFile: String? = nil,
                               session existing: SSHSession? = nil, secret: @escaping @Sendable () -> String?) async throws -> ScpFS {
        try RemoteFS.validateAlias(c.alias)
        let session = try existing ?? SSHSession(config: sessionConfig(c, sshConfigFile: sshConfigFile, knownHostsFile: knownHostsFile),
                                                 runDirectory: runDirectory, secret: secret)
        let base = try await runBlocking(qos: .userInitiated) { () -> String in
            try session.connect()
            let start = c.path.trimmingCharacters(in: .whitespaces)
            // Znacznik: `.bashrc` wypisujący tekst nie może zepsuć ścieżki.
            let r = try session.run(SSHSession.markedOutput(start.isEmpty ? "pwd" : "cd \(SSHSession.shellQuote(start)) && pwd"))
            guard r.status == 0 else { throw RemoteError.ssh(r.errorText.isEmpty ? L10n.tr("Brak katalogu \(start)") : r.errorText) }
            return SSHSession.textAfterMarker(session.config.encoding.decode(r.output)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ScpFS(connection: c, session: session, base: base.isEmpty ? "/" : base)
    }

    /// Konfiguracja SSH połączenia (SCP i terminal tego samego serwera dzielą sesję).
    public static func sessionConfig(_ c: RemoteConnection, sshConfigFile: String?, knownHostsFile: String?) -> SSHSession.Config {
        SSHSession.Config(host: c.host, port: c.port, user: c.user, keyFile: c.keyFile, legacyAlgorithms: c.legacyAlgorithms ?? false,
                          encoding: c.nameEncoding ?? .utf8, configFile: sshConfigFile, knownHostsFile: knownHostsFile)
    }

    public var root: VFSPath { VFSPath(provider: id, path: "/") }
    public var displayName: String { connection.alias }

    /// Ścieżka absolutna na serwerze.
    public func remotePath(_ path: VFSPath) -> String {
        let inner = String(path.path.dropFirst())
        if inner.isEmpty { return base }
        return base == "/" ? "/" + inner : base + "/" + inner
    }

    /// Polecenie powłoki na serwerze. `path` — element, którego dotyczy (komunikaty „nie znaleziono” /
    /// „brak uprawnień”); `idempotent: false` dla poleceń zmieniających (`mv`, `mkdir`), których nie
    /// wolno powtórzyć po zerwaniu połączenia.
    func shell(_ command: String, path: VFSPath? = nil, idempotent: Bool = true, timeout: TimeInterval = 120) throws -> String {
        let r = try session.run("LC_ALL=C; export LC_ALL; " + command, timeout: timeout, idempotent: idempotent)
        let target = path ?? root
        if r.timedOut { throw VFSError.io(path: target, code: ETIMEDOUT) }
        guard r.status == 0 else {
            let text = session.config.encoding.decode(r.error).trimmingCharacters(in: .whitespacesAndNewlines)
            // Bez rozróżniania wielkości liter: zsh pisze „no such file or directory”, ksh i sh — wielką literą.
            if text.range(of: "No such file", options: .caseInsensitive) != nil || text.contains("does not exist") { throw VFSError.notFound(target) }
            if text.range(of: "Permission denied", options: .caseInsensitive) != nil { throw VFSError.permissionDenied(target) }
            if text.contains("File exists") { throw VFSError.alreadyExists(target) }
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
        try entriesSync(directory).map(\.item)
    }

    /// Listing z celami dowiązań (pobieranie katalogu odtwarza dowiązania zamiast w nie wchodzić).
    func entriesSync(_ directory: VFSPath) throws -> [ListingEntry] {
        let dir = remotePath(directory)
        // Dowiązania do katalogów osobno: `ls -la` nie mówi, na co wskazuje dowiązanie. Błąd `cd`/`ls`
        // (brak katalogu, brak praw) kończy polecenie błędem — nie może wyglądać jak pusty katalog
        // (pobranie „skopiuj, potem usuń” zgubiłoby dane); `exit 0` tylko po pętli (ostatni test
        // `[ -h ]` ma kod 1). Składnia zgodna z ksh88 (AIX).
        let command = "cd \(SSHSession.shellQuote(dir)) || exit 1; ls -la || exit 1; echo '\(Self.linkMarker)'; for f in .* *; do [ -h \"$f\" ] && [ -d \"$f\" ] && echo \"$f\"; done; exit 0"
        let text = try shell(command, path: directory)
        let parts = text.components(separatedBy: Self.linkMarker + "\n")
        let linkDirs = Set((parts.count > 1 ? parts[1] : "").split(separator: "\n").map(String.init))
        var entries = Self.parseEntries(parts[0], in: directory)
        for i in entries.indices where entries[i].item.kind == .symlink && linkDirs.contains(entries[i].item.name) {
            entries[i].item.flags.insert(.symlinkToDirectory)
        }
        return entries
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        try await runBlocking(qos: .userInitiated) { try self.itemSync(path) }
    }

    public func itemSync(_ path: VFSPath) throws -> FileItem {
        if path.isRoot { return FileItem(path: root, name: connection.alias, kind: .directory) }
        guard let parent = path.parent else { throw VFSError.notFound(path) }
        let remote = SSHSession.shellQuote(remotePath(path))
        let text = try shell("ls -lad \(remote) && if [ -h \(remote) ] && [ -d \(remote) ]; then echo '\(Self.linkMarker)'; fi", path: path)
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

    /// Element listingu z celem dowiązania (tekst po „ -> ”).
    struct ListingEntry: Sendable {
        var item: FileItem
        var linkTarget: String?
    }

    /// `ls -la` w lokalizacji C (AIX, Linux, BSD): typ i prawa, liczba dowiązań, właściciel, grupa,
    /// rozmiar (albo „główny, poboczny” dla urządzeń), data „Mon DD HH:MM” lub „Mon DD  YYYY”, nazwa.
    public static func parseListing(_ text: String, in dir: VFSPath, now: Date = Date(), keepDots: Bool = false) -> [FileItem] {
        parseEntries(text, in: dir, now: now, keepDots: keepDots).map(\.item)
    }

    static func parseEntries(_ text: String, in dir: VFSPath, now: Date = Date(), keepDots: Bool = false) -> [ListingEntry] {
        var out: [ListingEntry] = []
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
            // Wiersz kończący się na polu daty (bez nazwy — np. podrzucony nową linią w nazwie pliku).
            let dateEnd = words[k + 2].1.upperBound
            guard dateEnd < line.endIndex else { continue }
            var name = String(line[line.index(after: dateEnd)...])
            let mode = words[0].0
            let kind: FileKind = switch mode.first {
            case "d": .directory
            case "l": .symlink
            case "-": .file
            default: .other
            }
            var linkTarget: String?
            if kind == .symlink, let arrow = name.range(of: " -> ") {
                linkTarget = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
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
            let item = FileItem(path: dir.appending(name), kind: kind, size: kind == .directory ? -1 : size, modified: date, permissions: parseMode(mode))
            out.append(ListingEntry(item: item, linkTarget: linkTarget))
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

    /// Nowa nazwa wpisana przez użytkownika (albo z dysku lokalnego) w postaci NFC — jak dotąd. Nazw
    /// z listingu serwera nie normalizujemy: plik w NFD (wgrany np. ze starego macOS) byłby nieosiągalny.
    static func newName(_ path: VFSPath) -> VFSPath {
        path.parent.map { $0.appending(path.name.precomposedStringWithCanonicalMapping) } ?? path
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        let url = try await download(path)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try LocalFS().readSync(.local(url), range: range)
    }

    /// Pobranie do własnego katalogu tymczasowego (`.bifold-scp-…`); usuwa go wywołujący
    /// (`readContents`, koniec edycji zdalnej).
    public func download(_ path: VFSPath) async throws -> URL {
        let (_, items) = try await runBlocking(qos: .userInitiated) {
            try self.extract([path], toTemporaryIn: .local(NSTemporaryDirectory()), isCancelled: { false })
        }
        return URL(filePath: items[0].path)
    }

    public func upload(_ local: URL, to path: VFSPath) async throws {
        try validateFileName(path.name)
        try await runBlocking(qos: .userInitiated) { try self.putFile(local.path, to: path, inPlaceFallback: true, isCancelled: { false }, isPaused: { false }) }
    }

    /// Wysyła plik pod `target` przez plik tymczasowy w tym samym katalogu i `mv -f`. `scp -t` pisze
    /// w miejscu (bez obcinania) — przerwanie zostawiłoby pod `target` mieszankę starych i nowych
    /// bajtów; zamiana nazwy w obrębie katalogu jest atomowa, a po błędzie lub anulowaniu znika tylko
    /// plik tymczasowy (istniejący plik zostaje nietknięty). `inPlaceFallback`: bez prawa zapisu do
    /// katalogu (plik zapisywalny w katalogu tylko do odczytu, np. konfiguracja w /etc) — zapis
    /// w miejscu jak dotąd.
    func putFile(_ local: String, to target: VFSPath, inPlaceFallback: Bool,
                 isCancelled: @escaping @Sendable () -> Bool, isPaused: @escaping @Sendable () -> Bool) throws {
        guard let parent = target.parent else { throw VFSError.unsupported("upload /") }
        // Nazwa spoza kodowania serwera: błąd z nazwą pliku (a nie pliku tymczasowego).
        _ = try session.config.encoding.encode(target.name)
        let tag = "bifold-" + UUID().uuidString.prefix(8)
        let tempName = target.name.utf8.count <= 200 ? ".\(target.name).\(tag)" : ".\(tag)"
        let remote = remotePath(target), temp = remotePath(parent.appending(tempName))
        do {
            try session.scp(upload: local, to: temp, isCancelled: isCancelled, isPaused: isPaused)
        } catch {
            _ = try? shell("rm -f \(SSHSession.shellQuote(temp))", path: target)
            if inPlaceFallback, error as? VFSError != .cancelled, error.localizedDescription.range(of: "Permission denied", options: .caseInsensitive) != nil {
                try session.scp(upload: local, to: remote, isCancelled: isCancelled, isPaused: isPaused)
                return
            }
            throw error
        }
        do {
            _ = try shell("mv -f \(SSHSession.shellQuote(temp)) \(SSHSession.shellQuote(remote))", path: target, idempotent: false)
        } catch {
            _ = try? shell("rm -f \(SSHSession.shellQuote(temp))", path: target)
            throw error
        }
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: connection.alias, totalCapacity: 0, availableCapacity: 0, fileSystem: "scp", isInternal: false, isNetwork: true)
    }

    public func createDirectory(_ path: VFSPath) async throws {
        try validateFileName(path.name)
        let target = Self.newName(path)
        let p = SSHSession.shellQuote(remotePath(target))
        _ = try await runBlocking(qos: .userInitiated) { try self.shell("mkdir \(p)", path: target, idempotent: false) }
    }

    public func createFile(_ path: VFSPath, contents: Data) async throws {
        try validateFileName(path.name)
        let target = Self.newName(path)
        guard await !exists(target) else { throw VFSError.alreadyExists(target) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "bifold-up-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: target.name)
        try contents.write(to: url)
        try await upload(url, to: target)
    }

    public func rename(_ path: VFSPath, to newName: String) async throws -> VFSPath {
        try validateFileName(newName)
        guard let parent = path.parent, !path.isRoot else { throw VFSError.unsupported("rename /") }
        let target = Self.newName(parent.appending(newName))
        let a = SSHSession.shellQuote(remotePath(path)), b = SSHSession.shellQuote(remotePath(target))
        _ = try await runBlocking(qos: .userInitiated) {
            try self.shell("if [ -e \(b) ] || [ -h \(b) ]; then echo 'File exists' >&2; exit 17; fi; mv \(a) \(b)", path: target, idempotent: false)
        }
        return target
    }

    /// Serwery nie mają Kosza — usuwanie jest trwałe (z potwierdzeniem w interfejsie).
    public func deletePermanently(_ path: VFSPath) async throws {
        let remote = remotePath(path)
        guard !path.isRoot, remote != "/", remote != base else { throw VFSError.unsupported("delete /") }
        // `rm -r -f` jest idempotentne — ponowienie po zerwaniu połączenia nie daje fałszywego błędu.
        _ = try await runBlocking(qos: .userInitiated) { try self.shell("rm -r -f \(SSHSession.shellQuote(remote))", path: path) }
    }

    // MARK: Pobieranie i wysyłanie

    /// Pobiera elementy (katalogi rekurencyjnie, plik po pliku) do nowego katalogu tymczasowego.
    /// Pobrane pliki dostają atrybut kwarantanny (program z serwera przejdzie przez Gatekeepera).
    public func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        let temp = directory.appending(".bifold-scp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var items: [VFSPath] = []
        do {
            for p in paths {
                let local = try fetch(ListingEntry(item: try itemSync(p), linkTarget: nil), to: temp.appending(p.name), topLevel: true,
                                      isCancelled: isCancelled, isPaused: { false }) { _ in }
                Quarantine.mark(local.path)
                items.append(local)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temp.path)
            throw error
        }
        return (temp, items)
    }

    /// Pobiera element opisany listingiem (bez ponownego `ls` dla każdego dziecka). Wchodzi tylko do
    /// katalogów — dowiązania wewnątrz pobieranego katalogu są odtwarzane jako dowiązania (`link -> ..`
    /// albo `root -> /` pobierałyby w kółko albo cały serwer); dowiązanie wybrane wprost jest pobierane
    /// jak jego cel. Pliki specjalne (urządzenia, potoki) są pomijane.
    ///
    /// APFS nie rozróżnia wielkości liter ani postaci Unicode (i składa je szerzej niż `lowercased()`:
    /// „aſ” = „as”, „bς” = „bσ”), więc o wolnej nazwie decyduje system plików: element jest tworzony
    /// wyłącznie jako nowy (`mkdir`, `symlink`, plik — przez plik tymczasowy i `renamex_np`
    /// z `RENAME_EXCL`, który nie idzie za dowiązaniem), a zajęta nazwa daje „nazwa (2)”. `scp`
    /// zapisujący wprost pod nazwą poszedłby za odtworzonym wcześniej dowiązaniem (wrogi serwer:
    /// `aſ -> ../../.zshrc`, potem plik `as`). Zwraca ścieżkę, pod którą element zapisano.
    @discardableResult
    func fetch(_ entry: ListingEntry, to local: VFSPath, topLevel: Bool, isCancelled: @escaping @Sendable () -> Bool,
               isPaused: @escaping @Sendable () -> Bool, done: (Int64) -> Void) throws -> VFSPath {
        if isCancelled() { throw VFSError.cancelled }
        let info = entry.item
        if info.kind == .directory || (topLevel && info.isNavigable) {
            let placed = try Self.createExclusively(local) { mkdir($0, 0o755) == 0 ? 0 : errno }
            for child in try entriesSync(info.path) {
                try fetch(child, to: placed.appending(child.item.name), topLevel: false, isCancelled: isCancelled, isPaused: isPaused, done: done)
            }
            return placed
        } else if info.kind == .symlink && !topLevel {
            guard let link = entry.linkTarget, !link.isEmpty, !link.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return local }
            return try Self.createExclusively(local) { symlink(link, $0) == 0 ? 0 : errno }
        } else if info.kind == .file || info.kind == .symlink {
            guard let dir = local.parent else { throw VFSError.notFound(local) }
            let part = dir.appending(".bifold-part-\(UUID().uuidString)")
            do {
                try session.scp(download: remotePath(info.path), to: part.path, isCancelled: isCancelled, isPaused: isPaused)
                let placed = try Self.storeDownloaded(part, as: local)
                done(max(0, info.size))
                return placed
            } catch {
                unlink(part.path)
                throw error
            }
        }
        return local
    }

    /// Pobrany plik tymczasowy `part` pod pierwszą wolną nazwą `target`, „target (2)”…
    static func storeDownloaded(_ part: VFSPath, as target: VFSPath) throws -> VFSPath {
        try createExclusively(target) { renamex_np(part.path, $0, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
    }

    /// Tworzy element pod pierwszą wolną nazwą: `target`, „target (2)”, „target (3)”… `create` tworzy
    /// wyłącznie nowy element i zwraca `errno` (0 — sukces, `EEXIST` — nazwa zajęta, także przez
    /// dowiązanie albo nazwę równą wg APFS). Wcześniej `lstat`, żeby nie próbować nazw zajętych.
    static func createExclusively(_ target: VFSPath, _ create: (String) -> Int32) throws -> VFSPath {
        guard let parent = target.parent else { throw VFSError.notFound(target) }
        let stem = target.name.fileStem, ext = target.name.fileExtension
        for n in 1...10_000 {
            let candidate = n == 1 ? target : parent.appending(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            var st = stat()
            if lstat(candidate.path, &st) == 0 { continue }
            let rc = create(candidate.path)
            if rc == 0 { return candidate }
            guard rc == EEXIST else { throw VFSError.io(path: candidate, code: rc) }
        }
        throw VFSError.alreadyExists(target)
    }

    public func disconnect() { session.disconnect() }
}

/// Wysyłanie na serwer SCP jako zadanie w tle (pauza = SIGSTOP procesu `scp`, anulowanie = zakończenie).
/// Konflikty jak przy kopiowaniu lokalnym: katalog do istniejącego katalogu — scalanie (nic spoza
/// wysyłanego drzewa nie znika), plik na istniejący — decyzja polityki albo delegata (okno pytania).
public struct ScpUpload: Sendable {
    public var fs: ScpFS
    public var sources: [VFSPath]
    public var destination: VFSPath
    /// Decyzja przy konflikcie (polityka albo okno pytania); bez delegata — pomijanie.
    public var delegate: (any TransferDelegate)?

    public init(fs: ScpFS, sources: [VFSPath], destination: VFSPath, delegate: (any TransferDelegate)? = nil) {
        self.fs = fs
        self.sources = sources
        self.destination = destination
        self.delegate = delegate
    }

    /// Stan jednego wysyłania (decyzja „dla wszystkich”, błędy, postęp) — tylko wątek zadania.
    final class State: @unchecked Sendable {
        var applyToAll: ConflictResolution?
        var errors: [String] = []
        var progress = TransferProgress()
    }

    public func run(control: JobControl, progress: @Sendable (TransferProgress) -> Void) throws -> [String] {
        let state = State()
        state.progress.filesTotal = sources.count
        state.progress.bytesTotal = sources.reduce(0) { $0 + ((try? DirectorySizer.sizeSync(of: $1, isCancelled: { false }))?.bytes ?? 0) }
        // Błąd listingu (zerwane połączenie, brak praw) nie może wyglądać jak pusty katalog — istniejące
        // pliki zostałyby nadpisane bez pytania.
        let existing = Self.byName(try fs.listSync(destination))
        for source in sources {
            guard control.checkpoint() else { throw VFSError.cancelled }
            state.progress.currentItem = source.name
            progress(state.progress)
            do {
                try put(source, into: destination, relative: source.name, existing: existing[source.name], siblings: existing, state: state, control: control, progress: progress)
            } catch VFSError.cancelled {
                throw VFSError.cancelled
            } catch {
                state.errors.append("\(source.name): \(error.localizedDescription)")
            }
            state.progress.filesDone += 1
            progress(state.progress)
        }
        return state.errors
    }

    /// Elementy wg nazwy (Swift porównuje napisy kanonicznie — nazwa NFD lokalnie trafia w NFC na serwerze).
    static func byName(_ items: [FileItem]) -> [String: FileItem] {
        Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func decide(_ local: FileItem, _ remote: FileItem, state: State) throws -> ConflictResolution {
        if let d = state.applyToAll { return d }
        guard let delegate else { return .skip }
        let question = FileConflict(source: local, destination: remote, kind: .copy)
        let decision = waitFor { await delegate.resolveConflict(question) }
        if decision.applyToAll { state.applyToAll = decision.resolution }
        if decision.resolution == .cancel { throw VFSError.cancelled }
        return decision.resolution
    }

    /// Wysyła `local` do katalogu `directory` na serwerze; `existing` — element o tej nazwie na serwerze,
    /// `relative` — ścieżka względna w wysyłanym drzewie (do raportu).
    private func put(_ local: VFSPath, into directory: VFSPath, relative: String, existing: FileItem?, siblings: [String: FileItem], state: State,
                     control: JobControl, progress: @Sendable (TransferProgress) -> Void) throws {
        guard control.checkpoint() else { throw VFSError.cancelled }
        let item = try LocalFS().itemSync(at: local)
        guard item.kind == .directory || item.kind == .file else {
            if item.kind == .symlink { state.errors.append(L10n.tr("\(relative): dowiązanie symboliczne — pominięto")) }
            return
        }
        var target = existing?.path ?? ScpFS.newName(directory.appending(item.name))
        var replace = false
        // Katalog do katalogu (także dowiązania do katalogu): scalanie bez pytania — jak lokalnie.
        if let existing, !(item.kind == .directory && existing.isNavigable) {
            switch try decide(item, existing, state: state) {
            case .skip, .cancel:
                state.errors.append(L10n.tr("\(relative): istnieje na serwerze — pominięto"))
                return
            case .rename:
                target = Self.unique(item.name, in: directory, taken: siblings)
            case .overwriteOlder:
                if let mine = item.modified, let theirs = existing.modified, theirs >= mine {
                    state.errors.append(L10n.tr("\(relative): istnieje na serwerze — pominięto"))
                    return
                }
                replace = true
            case .overwrite:
                replace = true
            }
            // Niezgodny typ (katalog ⇄ plik, dowiązanie): stary element trzeba usunąć (`mv -f` pliku na
            // katalog przeniósłby plik do środka); plik na plik zastępuje `putFile`.
            if replace, item.kind == .directory || existing.kind != .file {
                _ = try fs.shell("rm -r -f \(SSHSession.shellQuote(fs.remotePath(target)))", path: target)
            }
        }
        // Czy na serwerze nie było niczego pod `target` (nowy element).
        let isNew = existing == nil || target != existing?.path || (replace && existing?.kind != .file)
        if item.kind == .directory {
            // Błąd listingu katalogu docelowego to błąd tego katalogu (zawartość pominięta), a nie
            // „pusty katalog”, w którym wszystko byłoby nowe i nadpisywane bez pytania.
            let remoteChildren = isNew ? [:] : Self.byName(try fs.listSync(target))
            _ = try fs.shell("mkdir -p \(SSHSession.shellQuote(fs.remotePath(target)))", path: target)
            for name in try FileManager.default.contentsOfDirectory(atPath: local.path).sorted() {
                // Jeden błąd (nazwa spoza kodowania serwera, brak praw) nie przerywa reszty drzewa.
                let childRelative = relative + "/" + name
                do {
                    try put(local.appending(name), into: target, relative: childRelative, existing: remoteChildren[name], siblings: remoteChildren,
                            state: state, control: control, progress: progress)
                } catch VFSError.cancelled {
                    throw VFSError.cancelled
                } catch {
                    state.errors.append("\(childRelative): \(error.localizedDescription)")
                }
            }
            return
        }
        // Przez plik tymczasowy i `mv -f`: przerwanie ani anulowanie nie psuje ani nie usuwa istniejącego pliku.
        try fs.putFile(local.path, to: target, inPlaceFallback: !isNew, isCancelled: { control.isCancelled }, isPaused: { control.isPaused })
        state.progress.bytesDone += max(0, item.size)
        progress(state.progress)
    }

    /// „nazwa (2).ext” wolna w katalogu na serwerze.
    static func unique(_ name: String, in directory: VFSPath, taken: [String: FileItem]) -> VFSPath {
        let stem = name.fileStem, ext = name.fileExtension
        var n = 2
        while true {
            let candidate = (ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)").precomposedStringWithCanonicalMapping
            if taken[candidate] == nil { return directory.appending(candidate) }
            n += 1
        }
    }

    /// Most z okna pytania (async) do wątku zadania.
    private func waitFor<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Mutex<T?>(nil)
        Task.detached {
            let value = await body()
            box.withLock { $0 = value }
            semaphore.signal()
        }
        semaphore.wait()
        return box.withLock { $0! }
    }
}
