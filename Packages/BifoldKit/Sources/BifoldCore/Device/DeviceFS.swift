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

// MARK: - Android (MTP przez narzędzia libmtp)

/// Telefon z Androidem przez MTP. MTP adresuje pliki identyfikatorami, więc drzewo jest
/// budowane z `mtp-files` (jedno wywołanie — telefon obsługuje naraz tylko jedną sesję MTP).
public final class MTPDeviceFS: ExtractingProvider {
    public let id: ProviderID
    public let device: DeviceInfo
    let tools: String
    public let capabilities: ProviderCapabilities = [.read]
    private let tree = Mutex<[String: [Entry]]?>(nil)
    private let byPath = Mutex<[String: Entry]>([:])

    public struct Entry: Sendable, Hashable {
        public var id: Int
        public var parent: Int
        public var name: String
        public var size: Int64
        public var isFolder: Bool
    }

    public init(device: DeviceInfo, toolsDirectory: String) {
        self.device = device
        tools = toolsDirectory
        id = ProviderID("device:mtp-\(device.id)")
    }

    public var displayName: String { device.name }
    public var root: VFSPath { VFSPath(provider: id, path: "/") }

    /// Parser `mtp-files` (bloki „File ID: …”) i `mtp-folders` (wcięte „ID<tab>nazwa”).
    public static func parseFiles(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var current: Entry?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("File ID:") {
                if let c = current { out.append(c) }
                current = Entry(id: Int(line.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? -1, parent: 0, name: "", size: 0, isFolder: false)
            } else if line.hasPrefix("Filename:") {
                current?.name = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("File size") {
                current?.size = Int64(line.dropFirst(9).trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
            } else if line.hasPrefix("Parent ID:") {
                current?.parent = Int(line.dropFirst(10).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        if let c = current { out.append(c) }
        return out.filter { $0.id >= 0 && !$0.name.isEmpty }
    }

    public static func parseFolders(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var stack: [(depth: Int, id: Int)] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let head = line[..<tab]
            guard let fid = Int(head.trimmingCharacters(in: .whitespaces)) else { continue }
            let rest = line[line.index(after: tab)...]
            let depth = rest.prefix { $0 == " " }.count
            let name = rest.trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.depth >= depth { stack.removeLast() }
            out.append(Entry(id: fid, parent: stack.last?.id ?? 0, name: name, size: 0, isFolder: true))
            stack.append((depth, fid))
        }
        return out
    }

    func load() throws -> [String: [Entry]] {
        if let t = tree.withLock({ $0 }) { return t }
        let folders = Self.parseFolders(try ToolRunner.run(tools + "/mtp-folders", [], timeout: 120).output)
        let files = Self.parseFiles(try ToolRunner.run(tools + "/mtp-files", [], timeout: 600).output)
        let all = folders + files.filter { f in !folders.contains { $0.id == f.id } }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ e: Entry) -> String {
            var comps = [e.name]
            var p = e.parent
            var guardCount = 0
            while p != 0, let parent = byID[p], guardCount < 64 { comps.insert(parent.name, at: 0); p = parent.parent; guardCount += 1 }
            return "/" + comps.joined(separator: "/")
        }
        var t: [String: [Entry]] = [:]
        var paths: [String: Entry] = [:]
        for e in all {
            let full = path(e)
            paths[full] = e
            t[(full as NSString).deletingLastPathComponent, default: []].append(e)
        }
        tree.withLock { $0 = t }
        byPath.withLock { $0 = paths }
        return t
    }

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        let t = try await runBlocking(qos: .userInitiated) { try self.load() }
        return (t[directory.path] ?? []).map {
            FileItem(path: directory.appending($0.name), kind: $0.isFolder ? .directory : .file, size: $0.isFolder ? -1 : $0.size)
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: root, name: device.name, kind: .directory) }
        _ = try await runBlocking(qos: .userInitiated) { try self.load() }
        guard let e = byPath.withLock({ $0[path.path] }) else { throw VFSError.notFound(path) }
        return FileItem(path: path, kind: e.isFolder ? .directory : .file, size: e.isFolder ? -1 : e.size)
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        let (temp, items) = try await runBlocking(qos: .userInitiated) { try self.extract([path], toTemporaryIn: .local(NSTemporaryDirectory()), isCancelled: { false }) }
        defer { try? FileManager.default.removeItem(atPath: temp.path) }
        return try LocalFS().readSync(items[0], range: range)
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: device.name, totalCapacity: 0, availableCapacity: 0, fileSystem: "mtp", isRemovable: true, isInternal: false)
    }

    /// Pobiera pliki (katalogi rekurencyjnie) przez `mtp-getfile <id> <plik>`.
    public func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        let t = try load()
        let temp = directory.appending(".bifold-device-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: true)
        func fetch(_ devicePath: String, to local: VFSPath) throws {
            if isCancelled() { throw VFSError.cancelled }
            guard let e = byPath.withLock({ $0[devicePath] }) else { throw VFSError.notFound(VFSPath(provider: id, path: devicePath)) }
            if e.isFolder {
                try FileManager.default.createDirectory(atPath: local.path, withIntermediateDirectories: true)
                for child in t[devicePath] ?? [] { try fetch(devicePath + "/" + child.name, to: local.appending(child.name)) }
            } else {
                let (status, output) = try ToolRunner.run(tools + "/mtp-getfile", [String(e.id), local.path], timeout: 3600)
                guard status == 0 else { throw VFSError.unsupported(output) }
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

    /// `mtp-detect`: „Found N device(s)” i nazwy modeli.
    public static func parseMTPDetect(_ text: String) -> [DeviceInfo] {
        guard text.contains("Found") else { return [] }
        var devices: [DeviceInfo] = []
        var index = 0
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Model:") {
                devices.append(DeviceInfo(id: String(index), kind: .android, name: String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)))
                index += 1
            }
        }
        if devices.isEmpty, let n = text.range(of: #"Found (\d+) device"#, options: .regularExpression).map({ Int(text[$0].filter(\.isNumber)) ?? 0 }), n > 0 {
            devices = (0..<n).map { DeviceInfo(id: String($0), kind: .android, name: "Android") }
        }
        return devices
    }

    public static func androids(toolsDirectory: String) -> [DeviceInfo] {
        let detect = toolsDirectory + "/mtp-detect"
        guard FileManager.default.isExecutableFile(atPath: detect), let (_, out) = try? ToolRunner.run(detect, [], timeout: 30) else { return [] }
        return parseMTPDetect(out)
    }
}
