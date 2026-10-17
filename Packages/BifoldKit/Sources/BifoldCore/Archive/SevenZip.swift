import Foundation

public enum ArchiveError: Error, LocalizedError, Equatable, Sendable {
    case toolMissing
    case passwordRequired
    case wrongPassword
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing: L10n.tr("Archiwa wymagają 7-Zip (brew install sevenzip)")
        case .passwordRequired: L10n.tr("Archiwum jest zaszyfrowane — wymagane hasło")
        case .wrongPassword: L10n.tr("Nieprawidłowe hasło do archiwum")
        case .failed(let m): L10n.tr("7-Zip: \(m)")
        }
    }
}

/// Formaty tworzenia archiwów.
public enum ArchiveFormat: String, Codable, Sendable, CaseIterable {
    case zip, sevenZ = "7z", tar, tarGz = "tar.gz", tarBz2 = "tar.bz2", tarXz = "tar.xz", gz, bz2, xz

    public var fileExtension: String { rawValue }

    /// Typ dla `7zz -t…` (dla tar.* — typ kompresji drugiego kroku).
    var sevenZipType: String {
        switch self {
        case .zip: "zip"
        case .sevenZ: "7z"
        case .tar: "tar"
        case .tarGz, .gz: "gzip"
        case .tarBz2, .bz2: "bzip2"
        case .tarXz, .xz: "xz"
        }
    }

    public var isTarCompound: Bool { [.tarGz, .tarBz2, .tarXz].contains(self) }
    /// Formaty kompresji jednego pliku (bez kontenera).
    public var isSingleStream: Bool { [.gz, .bz2, .xz].contains(self) }
    public var supportsPassword: Bool { self == .zip || self == .sevenZ }
}

/// Uruchamianie `7zz`. Hasło idzie przez stdin (nie przez argumenty widoczne w `ps`), ścieżki
/// wewnątrz archiwum — przez plik listy (`@lista`), bo `Process` zamienia argumenty na NFD.
public struct SevenZip: Sendable {
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
    }

    @discardableResult
    public func run(_ arguments: [String], password: String? = nil, directory: String? = nil, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Output {
        let p = Process()
        p.executableURL = URL(filePath: executable)
        // Bez -p 7zz czyta hasło ze standardowego wejścia; bez hasła — puste wejście (szybki błąd zamiast czekania).
        p.arguments = arguments + ["-sccUTF-8", "-scsUTF-8"]
        if let directory { p.currentDirectoryURL = URL(filePath: directory) }
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        try p.run()
        if let password { input.fileHandleForWriting.write(Data((password + "\n").utf8)) }
        try? input.fileHandleForWriting.close()
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        while p.isRunning {
            if isCancelled() { p.terminate() }
            _ = group.wait(timeout: .now() + 0.1)
        }
        group.wait()
        p.waitUntilExit()
        let stderr = String(decoding: errBox.data, as: UTF8.self)
        let stdoutText = String(decoding: outBox.data.prefix(65536), as: UTF8.self)
        if p.terminationStatus != 0 {
            if isCancelled() { throw VFSError.cancelled }
            let all = stderr + stdoutText
            if all.contains("Wrong password") { throw password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword }
            if all.contains("Can not open encrypted archive") || all.contains("Enter password") {
                throw password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
            }
        }
        return Output(status: p.terminationStatus, stdout: outBox.data, stderr: stderr)
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Plik listy ścieżek (UTF-8) dla `@plik`.
    static func listFile(_ paths: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bifold-7z-\(UUID().uuidString).txt")
        try Data(paths.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    // MARK: Listowanie

    public struct Entry: Sendable, Hashable {
        public var path: String
        public var isDirectory: Bool
        public var size: Int64
        public var modified: Date?
        public var encrypted: Bool
    }

    public func list(_ archive: VFSPath, password: String?) throws -> [Entry] {
        let out = try run(["l", "-slt", archive.path], password: password)
        guard out.status == 0 else { throw ArchiveError.failed(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Self.parseListing(String(decoding: out.stdout, as: UTF8.self))
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Parser wyjścia `7zz l -slt`: bloki „Klucz = wartość” po linii „----------”.
    static func parseListing(_ text: String) -> [Entry] {
        guard let start = text.range(of: "\n----------\n") else { return [] }
        var entries: [Entry] = []
        for block in text[start.upperBound...].components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let eq = line.range(of: " = ") else { continue }
                fields[String(line[..<eq.lowerBound])] = String(line[eq.upperBound...])
            }
            guard let path = fields["Path"], !path.isEmpty else { continue }
            let isDir = fields["Folder"] == "+" || (fields["Attributes"]?.hasPrefix("D") ?? false)
            let modified = fields["Modified"].flatMap { dateFormatter.date(from: String($0.prefix(19))) }
            entries.append(Entry(
                path: path, isDirectory: isDir, size: Int64(fields["Size"] ?? "") ?? 0,
                modified: modified, encrypted: fields["Encrypted"] == "+"))
        }
        return entries
    }

    // MARK: Rozpakowywanie i tworzenie

    public enum Overwrite: String, Sendable { case skip = "-aos", overwrite = "-aoa", rename = "-aou" }

    /// Rozpakowuje całe archiwum albo wskazane ścieżki (z zachowaniem struktury katalogów).
    public func extract(_ archive: VFSPath, to directory: VFSPath, entries: [String]? = nil, overwrite: Overwrite = .skip, password: String?,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        var args = ["x", archive.path, "-o" + directory.path, overwrite.rawValue, "-y"]
        var list: URL?
        if let entries {
            list = try Self.listFile(entries)
            args.append("@" + list!.path)
        }
        defer { if let list { try? FileManager.default.removeItem(at: list) } }
        let out = try run(args, password: password, isCancelled: isCancelled)
        guard out.status == 0 || out.status == 1 else { throw ArchiveError.failed(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Zawartość jednego pliku z archiwum (podgląd F3).
    public func read(_ archive: VFSPath, entry: String, password: String?) throws -> Data {
        let list = try Self.listFile([entry])
        defer { try? FileManager.default.removeItem(at: list) }
        let out = try run(["e", "-so", archive.path, "@" + list.path], password: password)
        guard out.status == 0 else { throw ArchiveError.failed(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out.stdout
    }

    /// Sprawdza spójność archiwum (`7zz t`).
    public func test(_ archive: VFSPath, password: String?) throws -> Bool {
        try run(["t", archive.path], password: password).status == 0
    }

    /// Tworzy archiwum z elementów katalogu `base` (nazwy względne). `volumeSize` — archiwum
    /// wieloczęściowe (np. „100m”).
    public func create(_ archive: VFSPath, format: ArchiveFormat, base: VFSPath, names: [String], level: Int = 5,
                       password: String? = nil, volumeSize: String? = nil, isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        if FileManager.default.fileExists(atPath: archive.path) { throw VFSError.alreadyExists(archive) }
        let list = try Self.listFile(names)
        defer { try? FileManager.default.removeItem(at: list) }
        var args = ["a", "-t" + format.sevenZipType, "-mx=\(level)", archive.path, "@" + list.path]
        if let password, format.supportsPassword {
            args.append("-p")
            if format == .sevenZ { args.append("-mhe=on") }
        }
        if let volumeSize, !volumeSize.isEmpty { args.append("-v" + volumeSize) }

        if format.isTarCompound {
            // tar.* — najpierw tar w katalogu tymczasowym, potem kompresja jednego pliku.
            let tmpDir = archive.parent!.appending(".bifold-tar-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(atPath: tmpDir.path, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: tmpDir.path) }
            let tarPath = tmpDir.appending(archive.name.fileStem)
            let tarOut = try run(["a", "-ttar", tarPath.path, "@" + list.path], directory: base.path, isCancelled: isCancelled)
            guard tarOut.status == 0 else { throw ArchiveError.failed(tarOut.stderr) }
            var second = ["a", "-t" + format.sevenZipType, "-mx=\(level)", archive.path, tarPath.path]
            if let volumeSize, !volumeSize.isEmpty { second.append("-v" + volumeSize) }
            let out = try run(second, isCancelled: isCancelled)
            guard out.status == 0 else { throw ArchiveError.failed(out.stderr) }
            return
        }
        let out = try run(args, password: password.map { "\($0)\n\($0)" }, directory: base.path, isCancelled: isCancelled)
        guard out.status == 0 else {
            try? FileManager.default.removeItem(atPath: archive.path)
            throw ArchiveError.failed(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
