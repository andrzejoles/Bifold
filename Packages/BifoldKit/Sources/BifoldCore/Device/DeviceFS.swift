import Foundation
import Synchronization

/// Dostawca, z którego pliki kopiuje się przez wypakowanie do katalogu tymczasowego
/// (archiwa, urządzenia) — kolejka potem przenosi je silnikiem kopiowania.
public protocol ExtractingProvider: FileSystemProvider {
    func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath])
    var displayName: String { get }
}

extension ArchiveFS: ExtractingProvider {
    public var displayName: String { archive.name }
}

public enum DeviceKind: String, Codable, Sendable { case iPhone, android }

public struct DeviceInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: DeviceKind
    public var name: String
}

/// Uruchamianie narzędzi CLI z lokalizacją C (stały format dat) i bez kolorów.
struct ToolRunner {
    static func run(_ executable: String, _ args: [String], timeout: Double = 30) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(filePath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, stripANSI(String(decoding: data, as: UTF8.self)))
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

// MARK: - iPhone / iPad (AFC przez afcclient z libimobiledevice)

/// iPhone przez usługę AFC: dostępne są tylko media (zdjęcia DCIM, nagrania) oraz — przez
/// `--documents <bundle id>` — katalogi Documents aplikacji z włączonym udostępnianiem plików.
/// To ograniczenie iOS, nie aplikacji.
public final class AFCDeviceFS: ExtractingProvider {
    public let id: ProviderID
    public let device: DeviceInfo
    let afcclient: String
    /// Kontener aplikacji (`--documents`), `nil` = media.
    public let appContainer: String?
    public let capabilities: ProviderCapabilities = [.read]

    public static let limitation = "iOS udostępnia przez kabel tylko zdjęcia i nagrania (DCIM) oraz katalogi aplikacji z włączonym udostępnianiem plików. Pozostałe dane iPhone’a są niedostępne."

    public init(device: DeviceInfo, afcclient: String, appContainer: String? = nil) {
        self.device = device
        self.afcclient = afcclient
        self.appContainer = appContainer
        id = ProviderID("device:\(device.id.prefix(12))\(appContainer.map { ":" + $0 } ?? "")")
    }

    public var displayName: String { device.name }
    public var root: VFSPath { VFSPath(provider: id, path: "/") }

    var baseArgs: [String] {
        var a = ["-u", device.id]
        if let appContainer { a += ["--documents", appContainer] }
        return a
    }

    public static func parseLongListing(_ text: String, in dir: VFSPath) -> [FileItem] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM yyyy HH:mm:ss"
        var out: [FileItem] = []
        for line in text.split(separator: "\n").map(String.init) {
            // drwxr-xr-x    1 mobile mobile       1234 17 Oct 2026 12:00:00 nazwa
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9, let mode = parts.first, mode.count == 10, let size = Int64(parts[4]) else { continue }
            let dateText = parts[5...8].joined(separator: " ")
            guard let nameStart = line.range(of: dateText)?.upperBound else { continue }
            let name = String(line[nameStart...].dropFirst())
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let kind: FileKind = mode.hasPrefix("d") ? .directory : (mode.hasPrefix("l") ? .symlink : .file)
            out.append(FileItem(path: dir.appending(name), kind: kind, size: kind == .directory ? -1 : size, modified: f.date(from: dateText)))
        }
        return out
    }

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        let exe = afcclient, args = baseArgs + ["ls", "-l", directory.path]
        let (status, output) = try await runBlocking(qos: .userInitiated) { try ToolRunner.run(exe, args) }
        guard status == 0, !output.hasPrefix("Error") else { throw VFSError.io(path: directory, code: EIO) }
        let items = Self.parseLongListing(output, in: directory)
        return options.includeHidden ? items : items.filter { !$0.isHidden }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: root, name: device.name, kind: .directory) }
        guard let parent = path.parent else { throw VFSError.notFound(path) }
        guard let item = try await list(parent, options: ListOptions()).first(where: { $0.name == path.name }) else { throw VFSError.notFound(path) }
        return item
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        let (temp, items) = try await runBlocking(qos: .userInitiated) { try self.extract([path], toTemporaryIn: .local(NSTemporaryDirectory()), isCancelled: { false }) }
        defer { try? FileManager.default.removeItem(atPath: temp.path) }
        return try LocalFS().readSync(items[0], range: range)
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: device.name, totalCapacity: 0, availableCapacity: 0, fileSystem: "afc", isRemovable: true, isInternal: false)
    }

    public func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        let temp = directory.appending(".bifold-device-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: true)
        var items: [VFSPath] = []
        for p in paths {
            if isCancelled() { throw VFSError.cancelled }
            let local = temp.appending(p.name)
            let (status, output) = try ToolRunner.run(afcclient, baseArgs + ["get", "-rf", p.path, local.path], timeout: 3600)
            guard status == 0, FileManager.default.fileExists(atPath: local.path) else {
                try? FileManager.default.removeItem(atPath: temp.path)
                throw VFSError.unsupported(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            items.append(local)
        }
        return (temp, items)
    }
}

// MARK: - Android (MTP przez pomocnika bifold-mtp)

/// Telefon z Androidem przez MTP. Pomocnik `bifold-mtp` (C, libmtp z Homebrew) trzyma jedną sesję
/// i czyta foldery pojedynczo — narzędzia mtp-files/mtp-folders wczytywały cały telefon naraz
/// (minuty przy tysiącach zdjęć). Telefon obsługuje tylko jedną sesję MTP naraz.
public final class MTPDeviceFS: ExtractingProvider, @unchecked Sendable {
    public let id: ProviderID
    public let device: DeviceInfo
    public let model: String
    let helperPath: String
    let index: Int
    /// Sesja MTP; po „Zezwól” Samsung łączy się z USB od nowa, więc stara sesja nie widzi nośników —
    /// wtedy otwierana jest nowa.
    private let session = NSLock()
    nonisolated(unsafe) private var current: MTPHelper
    public let capabilities: ProviderCapabilities = [.read]
    /// Zawartość odczytanych folderów (ścieżka → elementy), do zamiany ścieżek na identyfikatory MTP.
    private let cache = Mutex<[String: [Entry]]>([:])
    static let root: UInt32 = 0xFFFF_FFFF

    public struct Entry: Sendable, Hashable {
        public var id: UInt32
        public var storage: UInt32
        public var name: String
        public var size: Int64
        public var modified: Date?
        public var isFolder: Bool
        public var total: Int64 = 0
        public var free: Int64 = 0
    }

    public enum MTPError: Error, LocalizedError {
        case noStorage
        case helper(String)

        public var errorDescription: String? {
            switch self {
            case .noStorage:
                L10n.tr("Telefon nie udostępnia plików: odblokuj go i na ekranie telefonu stuknij „Zezwól” (dostęp do danych telefonu), potem odśwież panel (Ctrl+R).")
            case .helper(let m): m
            }
        }
    }

    /// Otwiera sesję MTP (kilka sekund — telefon odpowiada wolno).
    public init(device: DeviceInfo, helperPath: String) throws {
        self.device = device
        guard let index = Int(device.id) else { throw MTPError.helper("index") }
        let (helper, hello) = try MTPHelper.open(helperPath, index: index)
        self.helperPath = helperPath
        self.index = index
        current = helper
        model = (hello["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? device.name
        id = ProviderID("device:mtp-\(device.id)")
    }

    public var displayName: String { model }
    public var root: VFSPath { VFSPath(provider: id, path: "/") }

    var helper: MTPHelper { session.withLock { current } }

    /// Nowa sesja w miejsce starej (po ponownym podłączeniu telefonu do USB).
    func reopen() throws {
        session.lock()
        defer { session.unlock() }
        current.close()
        current = try MTPHelper.open(helperPath, index: index).0
        cache.withLock { $0 = [:] }
    }

    /// Polecenie; gdy sesja przestała odpowiadać (telefon odłączony i podłączony ponownie) — raz w nowej sesji.
    func request(_ command: String, timeout: TimeInterval) throws -> [String: Any] {
        do {
            return try helper.request(command, timeout: timeout)
        } catch MTPError.helper(let message) where !helper.isRunning || message == L10n.tr("Telefon nie odpowiada") {
            try reopen()
            return try helper.request(command, timeout: timeout)
        }
    }

    static func entries(_ items: Any?, storage: UInt32) -> [Entry] {
        ((items as? [[String: Any]]) ?? []).compactMap { e in
            guard let id = (e["id"] as? NSNumber)?.uint32Value, let name = e["name"] as? String, !name.isEmpty else { return nil }
            let mtime = (e["mtime"] as? NSNumber)?.doubleValue ?? 0
            return Entry(id: id, storage: storage, name: name, size: (e["size"] as? NSNumber)?.int64Value ?? 0,
                         modified: mtime > 0 ? Date(timeIntervalSince1970: mtime) : nil, isFolder: e["folder"] as? Bool ?? false)
        }
    }

    /// Nośniki („Pamięć wewnętrzna”, karta SD) jako foldery w korzeniu.
    func storages() throws -> [Entry] {
        var r = try request("storages", timeout: 60)
        if (r["storages"] as? [Any])?.isEmpty ?? true {
            // Sesja sprzed „Zezwól” nie zobaczy nośników — nowa sesja.
            try reopen()
            r = try request("storages", timeout: 60)
        }
        let list = ((r["storages"] as? [[String: Any]]) ?? []).compactMap { s -> Entry? in
            guard let id = (s["id"] as? NSNumber)?.uint32Value else { return nil }
            let name = (s["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L10n.tr("Pamięć \(id)")
            return Entry(id: Self.root, storage: id, name: name, size: -1, modified: nil, isFolder: true,
                         total: (s["total"] as? NSNumber)?.int64Value ?? 0, free: (s["free"] as? NSNumber)?.int64Value ?? 0)
        }
        guard !list.isEmpty else { throw MTPError.noStorage }
        return list
    }

    /// Zawartość folderu (zawsze świeża — odświeżenie panelu pyta telefon ponownie).
    func entries(_ dir: String) throws -> [Entry] {
        let items: [Entry]
        if dir == "/" {
            items = try storages()
        } else {
            let target = try resolve(dir)
            guard target.isFolder else { throw VFSError.notADirectory(VFSPath(provider: id, path: dir)) }
            let r = try request("list \(target.storage) \(target.id)", timeout: 600)
            items = Self.entries(r["items"], storage: target.storage)
        }
        cache.withLock { $0[dir] = items }
        return items
    }

    /// Ścieżka → obiekt MTP (z zapamiętanych folderów, brakujące czytane po drodze).
    func resolve(_ path: String) throws -> Entry {
        let comps = path.split(separator: "/").map(String.init)
        var dir = "/"
        var current: Entry?
        for name in comps {
            let listing = try cache.withLock({ $0[dir] }) ?? entries(dir)
            guard let next = listing.first(where: { $0.name == name }) else { throw VFSError.notFound(VFSPath(provider: id, path: path)) }
            current = next
            dir = dir == "/" ? "/" + name : dir + "/" + name
        }
        guard let current else { throw VFSError.notFound(VFSPath(provider: id, path: path)) }
        return current
    }

    func item(_ e: Entry, in dir: VFSPath) -> FileItem {
        FileItem(path: dir.appending(e.name), kind: e.isFolder ? .directory : .file, size: e.isFolder ? -1 : e.size, modified: e.modified)
    }

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        let items = try await runBlocking(qos: .userInitiated) { try self.entries(directory.path) }.map { item($0, in: directory) }
        return options.includeHidden ? items : items.filter { !$0.isHidden }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: root, name: model, kind: .directory) }
        let e = try await runBlocking(qos: .userInitiated) { try self.resolve(path.path) }
        return FileItem(path: path, kind: e.isFolder ? .directory : .file, size: e.isFolder ? -1 : e.size, modified: e.modified)
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        let (temp, items) = try await runBlocking(qos: .userInitiated) { try self.extract([path], toTemporaryIn: .local(NSTemporaryDirectory()), isCancelled: { false }) }
        defer { try? FileManager.default.removeItem(atPath: temp.path) }
        return try LocalFS().readSync(items[0], range: range)
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        let storageName = path.path.split(separator: "/").first.map(String.init)
        let s = storageName.flatMap { name in cache.withLock { $0["/"] }?.first { $0.name == name } }
        return VolumeInfo(path: root, name: model, totalCapacity: s?.total ?? 0, availableCapacity: s?.free ?? 0, fileSystem: "mtp", isRemovable: true, isInternal: false)
    }

    /// Pobiera pliki (katalogi rekurencyjnie) do nowego katalogu tymczasowego.
    public func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        let temp = directory.appending(".bifold-device-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: true)
        func fetch(_ devicePath: String, to local: VFSPath) throws {
            if isCancelled() { throw VFSError.cancelled }
            let e = try resolve(devicePath)
            if e.isFolder {
                try FileManager.default.createDirectory(atPath: local.path, withIntermediateDirectories: true)
                for child in try entries(devicePath) { try fetch(devicePath + "/" + child.name, to: local.appending(child.name)) }
            } else {
                _ = try request("get \(e.id) \(local.path)", timeout: 3600)
            }
        }
        var items: [VFSPath] = []
        do {
            for p in paths {
                let local = temp.appending(p.name)
                try fetch(p.path, to: local)
                items.append(local)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temp.path)
            throw error
        }
        return (temp, items)
    }

    /// Kończy sesję MTP (telefon wolny dla innych programów).
    public func close() { helper.close() }

    /// Do testów: czy proces sesji działa.
    var isSessionRunning: Bool { helper.isRunning }
}

/// Proces `bifold-mtp serve N`: polecenie w wierszu na stdin, odpowiedź JSON w wierszu na stdout.
final class MTPHelper: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: Int32
    private let lock = NSLock()
    private var buffer = Data()

    private init(process: Process, input: FileHandle, output: Int32) {
        self.process = process
        self.input = input
        self.output = output
    }

    static func open(_ executable: String, index: Int) throws -> (MTPHelper, [String: Any]) {
        let p = Process()
        p.executableURL = URL(filePath: executable)
        p.arguments = ["serve", String(index)]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        let helper = MTPHelper(process: p, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading.fileDescriptor)
        let hello = try helper.readReply(timeout: 60)
        return (helper, hello)
    }

    func request(_ command: String, timeout: TimeInterval) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { throw MTPDeviceFS.MTPError.helper(L10n.tr("Połączenie z telefonem zostało przerwane (odłączony kabel?)")) }
        try input.write(contentsOf: Data((command + "\n").utf8))
        return try readReply(timeout: timeout)
    }

    private func readReply(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw MTPDeviceFS.MTPError.helper("JSON") }
                guard obj["ok"] as? Bool == true else { throw MTPDeviceFS.MTPError.helper(obj["error"] as? String ?? "MTP") }
                return obj
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw MTPDeviceFS.MTPError.helper(L10n.tr("Telefon nie odpowiada")) }
            var pfd = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(left, 1) * 1000))
            if ready <= 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(output, &chunk, chunk.count)
            if n <= 0 { throw MTPDeviceFS.MTPError.helper(L10n.tr("Połączenie z telefonem zostało przerwane (odłączony kabel?)")) }
            buffer.append(chunk, count: n)
        }
    }

    var isRunning: Bool { process.isRunning }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning {
            try? input.write(contentsOf: Data("quit\n".utf8))
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
        }
    }

    deinit { if process.isRunning { process.terminate() } }
}

/// Wykrywanie podłączonych urządzeń.
public enum DeviceDetector {
    public static func iPhones(toolsDirectory: String) -> [DeviceInfo] {
        let idevice = toolsDirectory + "/idevice_id", info = toolsDirectory + "/ideviceinfo"
        guard FileManager.default.isExecutableFile(atPath: idevice), let (status, out) = try? ToolRunner.run(idevice, ["-l"], timeout: 10), status == 0 else { return [] }
        return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { udid in
            let name = (try? ToolRunner.run(info, ["-u", udid, "-k", "DeviceName"], timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "iPhone"
            return DeviceInfo(id: udid, kind: .iPhone, name: name.isEmpty || name.contains("ERROR") ? "iPhone" : name)
        }
    }

    /// Telefony z Androidem: `bifold-mtp detect` (bez otwierania sesji — szybko i bez blokowania telefonu).
    public static func parseMTPDetect(_ json: Data) -> [DeviceInfo] {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let index = (d["index"] as? NSNumber)?.intValue else { return nil }
            let vendor = d["vendor"] as? String ?? "", product = (d["product"] as? String ?? "").replacingOccurrences(of: " (MTP)", with: "")
            let name = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
            return DeviceInfo(id: String(index), kind: .android, name: name.isEmpty ? "Android" : name)
        }
    }

    public static func androids(helper: String?) -> [DeviceInfo] {
        guard let helper, FileManager.default.isExecutableFile(atPath: helper) else { return [] }
        let p = Process()
        p.executableURL = URL(filePath: helper)
        p.arguments = ["detect"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseMTPDetect(data)
    }

    /// Pomocnik MTP: obok programu w pakiecie aplikacji albo `BIFOLD_MTP_HELPER` (testy).
    public static var mtpHelperPath: String? {
        if let env = ProcessInfo.processInfo.environment["BIFOLD_MTP_HELPER"] { return env }
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "bifold-mtp").path
        return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }
}
