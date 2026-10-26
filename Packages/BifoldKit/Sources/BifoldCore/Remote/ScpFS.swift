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
            if text.contains("No such file") || text.contains("does not exist") { throw VFSError.notFound(target) }
            if text.contains("Permission denied") { throw VFSError.permissionDenied(target) }
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
        // Dowiązania do katalogów osobno: `ls -la` nie mówi, na co wskazuje dowiązanie.
        let command = "cd \(SSHSession.shellQuote(dir)) && ls -la && echo '\(Self.linkMarker)' && for f in .* *; do [ -h \"$f\" ] && [ -d \"$f\" ] && echo \"$f\"; done; true"
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
        let remote = remotePath(path)
        try await runBlocking(qos: .userInitiated) { try self.session.scp(upload: local.path, to: remote, isCancelled: { false }, isPaused: { false }) }
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
                let local = temp.appending(p.name)
                try fetch(ListingEntry(item: try itemSync(p), linkTarget: nil), to: local, topLevel: true, isCancelled: isCancelled, isPaused: { false }) { _ in }
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
    func fetch(_ entry: ListingEntry, to local: VFSPath, topLevel: Bool, isCancelled: @escaping @Sendable () -> Bool,
               isPaused: @escaping @Sendable () -> Bool, done: (Int64) -> Void) throws {
        if isCancelled() { throw VFSError.cancelled }
        let info = entry.item
        if info.kind == .directory || (topLevel && info.isNavigable) {
            try FileManager.default.createDirectory(atPath: local.path, withIntermediateDirectories: false)
            // APFS nie rozróżnia wielkości liter ani postaci Unicode: „README” i „Readme” z serwera
            // zapisałyby się w jeden plik — drugi dostaje wolną nazwę („Readme (2)”).
            var taken = Set<String>()
            for child in try entriesSync(info.path) {
                var target = local.appending(child.item.name)
                if !taken.insert(child.item.name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                    target = TransferEngine.uniqueName(for: target)
                }
                try fetch(child, to: target, topLevel: false, isCancelled: isCancelled, isPaused: isPaused, done: done)
            }
        } else if info.kind == .symlink && !topLevel {
            guard let link = entry.linkTarget, !link.isEmpty, !link.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return }
            try FileManager.default.createSymbolicLink(atPath: local.path, withDestinationPath: link)
        } else if info.kind == .file || info.kind == .symlink {
            try session.scp(download: remotePath(info.path), to: local.path, isCancelled: isCancelled, isPaused: isPaused)
            done(max(0, info.size))
        }
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
    /// Stała decyzja przy konflikcie (`nil` — pyta `delegate`, bez delegata pomija).
    public var conflict: ConflictResolution?
    public var delegate: (any TransferDelegate)?

    public init(fs: ScpFS, sources: [VFSPath], destination: VFSPath, conflict: ConflictResolution? = nil, delegate: (any TransferDelegate)? = nil) {
        self.fs = fs
        self.sources = sources
        self.destination = destination
        self.conflict = conflict
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
        let existing = Self.byName((try? fs.listSync(destination)) ?? [])
        for source in sources {
            guard control.checkpoint() else { throw VFSError.cancelled }
            state.progress.currentItem = source.name
            progress(state.progress)
            do {
                try put(source, into: destination, existing: existing[source.name], siblings: existing, state: state, control: control, progress: progress)
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
        if let conflict { return conflict }
        if let d = state.applyToAll { return d }
        guard let delegate else { return .skip }
        let question = FileConflict(source: local, destination: remote, kind: .copy)
        let decision = waitFor { await delegate.resolveConflict(question) }
        if decision.applyToAll { state.applyToAll = decision.resolution }
        if decision.resolution == .cancel { throw VFSError.cancelled }
        return decision.resolution
    }

    /// Wysyła `local` do katalogu `directory` na serwerze; `existing` — element o tej nazwie na serwerze.
    private func put(_ local: VFSPath, into directory: VFSPath, existing: FileItem?, siblings: [String: FileItem], state: State,
                     control: JobControl, progress: @Sendable (TransferProgress) -> Void) throws {
        guard control.checkpoint() else { throw VFSError.cancelled }
        let item = try LocalFS().itemSync(at: local)
        guard item.kind == .directory || item.kind == .file else {
            if item.kind == .symlink { state.errors.append(L10n.tr("\(item.name): dowiązanie symboliczne — pominięto")) }
            return
        }
        var target = existing?.path ?? ScpFS.newName(directory.appending(item.name))
        var replace = false
        // Katalog do katalogu (także dowiązania do katalogu): scalanie bez pytania — jak lokalnie.
        if let existing, !(item.kind == .directory && existing.isNavigable) {
            switch try decide(item, existing, state: state) {
            case .skip, .cancel:
                state.errors.append(L10n.tr("\(item.name): istnieje na serwerze — pominięto"))
                return
            case .rename:
                target = Self.unique(item.name, in: directory, taken: siblings)
            case .overwriteOlder:
                if let mine = item.modified, let theirs = existing.modified, theirs >= mine {
                    state.errors.append(L10n.tr("\(item.name): istnieje na serwerze — pominięto"))
                    return
                }
                replace = true
            case .overwrite:
                replace = true
            }
            // Niezgodny typ (katalog ⇄ plik, dowiązanie): stary element trzeba usunąć; plik na plik scp nadpisuje sam.
            if replace, item.kind == .directory || existing.kind != .file {
                _ = try fs.shell("rm -r -f \(SSHSession.shellQuote(fs.remotePath(target)))", path: target)
            }
        }
        // Czy na serwerze nie było niczego pod `target` (nowy element).
        let isNew = existing == nil || target != existing?.path || (replace && existing?.kind != .file)
        if item.kind == .directory {
            let remoteChildren = isNew ? [:] : Self.byName((try? fs.listSync(target)) ?? [])
            _ = try fs.shell("mkdir -p \(SSHSession.shellQuote(fs.remotePath(target)))", path: target)
            for name in try FileManager.default.contentsOfDirectory(atPath: local.path).sorted() {
                try put(local.appending(name), into: target, existing: remoteChildren[name], siblings: remoteChildren, state: state, control: control, progress: progress)
            }
            return
        }
        do {
            try fs.session.scp(upload: local.path, to: fs.remotePath(target), isCancelled: { control.isCancelled }, isPaused: { control.isPaused })
        } catch {
            // Urwany plik nie może zostać na serwerze: po anulowaniu zawsze, po błędzie — tylko nowy
            // (istniejący, którego nie dało się nadpisać, zostaje nietknięty).
            if error as? VFSError == .cancelled || isNew {
                _ = try? fs.shell("rm -f \(SSHSession.shellQuote(fs.remotePath(target)))", path: target)
            }
            throw error
        }
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
