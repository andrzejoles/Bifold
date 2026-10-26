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
        // Własne wątki zamiast puli GCD: wywołanie bywa synchroniczne z puli Swift Concurrency, a gdy
        // wszystkie jej wątki czekają, GCD nie dokłada wątków dla domyślnego QoS — zakleszczenie.
        group.enter()
        Thread.detachNewThread { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        Thread.detachNewThread { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
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
            if let error = Self.passwordError(stderr + stdoutText, password: password) { throw error }
        }
        return Output(status: p.terminationStatus, stdout: outBox.data, stderr: stderr)
    }

    static func passwordError(_ output: String, password: String?) -> ArchiveError? {
        if output.contains("Wrong password") || output.contains("Can not open encrypted archive") || output.contains("Enter password") {
            return password == nil ? .passwordRequired : .wrongPassword
        }
        return nil
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

    public func list(_ archive: VFSPath, password: String?, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [Entry] {
        let out = try run(["l", "-slt", archive.path], password: password, isCancelled: isCancelled)
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

    /// Fragment pliku z archiwum (`7zz e -so`) czytany strumieniowo: wyjście jest odrzucane do
    /// `range.lowerBound`, a po `range.upperBound` proces jest kończony — w pamięci tylko fragment.
    /// Bez zakresu — cały plik.
    public func read(_ archive: VFSPath, entry: String, password: String?, range: Range<Int64>?,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Data {
        guard let range else { return try read(archive, entry: entry, password: password) }
        guard range.upperBound > max(0, range.lowerBound) else { return Data() }
        let list = try Self.listFile([entry])
        defer { try? FileManager.default.removeItem(at: list) }
        let p = Process()
        p.executableURL = URL(filePath: executable)
        p.arguments = ["e", "-so", archive.path, "@" + list.path, "-sccUTF-8", "-scsUTF-8"]
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        try p.run()
        if let password { input.fileHandleForWriting.write(Data((password + "\n").utf8)) }
        try? input.fileHandleForWriting.close()
        let errBox = DataBox()
        let errDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }

        let handle = out.fileHandleForReading
        var result = Data()
        var position: Int64 = 0
        var stoppedEarly = false
        var cancelled = false
        while position < range.upperBound {
            if isCancelled() { cancelled = true; break }
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            let start = position, end = position + Int64(chunk.count)
            let lo = max(start, range.lowerBound), hi = min(end, range.upperBound)
            if lo < hi {
                let base = chunk.startIndex
                result.append(chunk[(base + Int(lo - start))..<(base + Int(hi - start))])
            }
            position = end
        }
        if p.isRunning && (cancelled || position >= range.upperBound) {
            stoppedEarly = true
            p.terminate()
        }
        try? handle.close()
        p.waitUntilExit()
        errDone.wait()
        if cancelled { throw VFSError.cancelled }
        if !stoppedEarly && p.terminationStatus != 0 {
            let stderr = String(decoding: errBox.data, as: UTF8.self)
            if let error = Self.passwordError(stderr, password: password) { throw error }
            throw ArchiveError.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Rozpakowuje jeden plik (`7zz e`, bez ścieżki z archiwum) do katalogu i zwraca ścieżkę wyniku.
    public func extractEntry(_ archive: VFSPath, entry: String, to directory: VFSPath, password: String?,
                             isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> VFSPath {
        let name = (entry as NSString).lastPathComponent
        guard isSafeComponentName(name) else { throw VFSError.invalidName(name) }
        let list = try Self.listFile([entry])
        defer { try? FileManager.default.removeItem(at: list) }
        let out = try run(["e", archive.path, "-o" + directory.path, "-aoa", "-y", "@" + list.path], password: password, isCancelled: isCancelled)
        guard out.status == 0 else { throw ArchiveError.failed(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let result = directory.appending(name)
        guard FileManager.default.fileExists(atPath: result.path) else { throw VFSError.notFound(result) }
        return result
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
    /// wieloczęściowe (np. „100m”). Archiwum powstaje pod ukrytą nazwą tymczasową i dostaje właściwą
    /// nazwę dopiero po sukcesie — po błędzie lub anulowaniu nie zostaje niekompletne archiwum ani części.
    public func create(_ archive: VFSPath, format: ArchiveFormat, base: VFSPath, names: [String], level: Int = 5,
                       password: String? = nil, volumeSize: String? = nil, isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        guard let parent = archive.parent else { throw VFSError.unsupported("archive /") }
        let volumes = !(volumeSize ?? "").isEmpty
        let firstFinal = volumes ? parent.appending(FileSplitter.partName(archive.name, index: 1)) : archive
        for p in Set([archive, firstFinal]) where FileManager.default.fileExists(atPath: p.path) { throw VFSError.alreadyExists(p) }
        let tempName = ".bifold-new-\(UUID().uuidString.prefix(8)).\(format.fileExtension)"
        let temp = parent.appending(tempName)
        func removeTemporaries() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(tempName) {
                try? FileManager.default.removeItem(atPath: parent.appending(name).path)
            }
        }
        do {
            try createUnchecked(temp, innerName: archive.name.fileStem, format: format, base: base, names: names, level: level,
                                password: password, volumeSize: volumeSize, isCancelled: isCancelled)
            if isCancelled() { throw VFSError.cancelled }
            let outputs = volumes ? FileSplitter.parts(startingWith: parent.appending(FileSplitter.partName(tempName, index: 1))) : [temp]
            guard let first = outputs.first, FileManager.default.fileExists(atPath: first.path) else {
                throw ArchiveError.failed(archive.name)
            }
            var renamed: [VFSPath] = []
            do {
                for (i, output) in outputs.enumerated() {
                    let final = volumes ? parent.appending(FileSplitter.partName(archive.name, index: i + 1)) : archive
                    guard renamex_np(output.path, final.path, UInt32(RENAME_EXCL)) == 0 else { throw VFSError.from(errno: errno, path: final) }
                    renamed.append(final)
                }
            } catch {
                for r in renamed { unlink(r.path) }
                throw error
            }
        } catch {
            removeTemporaries()
            throw error
        }
    }

    private func createUnchecked(_ archive: VFSPath, innerName: String, format: ArchiveFormat, base: VFSPath, names: [String], level: Int,
                                 password: String?, volumeSize: String?, isCancelled: @escaping @Sendable () -> Bool) throws {
        let list = try Self.listFile(names)
        defer { try? FileManager.default.removeItem(at: list) }
        var args = ["a", "-t" + format.sevenZipType, "-mx=\(level)", archive.path, "@" + list.path]
        // Samo `-p`: hasło 7zz czyta ze standardowego wejścia (nie trafia do argumentów procesu).
        if password != nil, format.supportsPassword {
            args.append("-p")
            if format == .sevenZ { args.append("-mhe=on") }
        }
        if let volumeSize, !volumeSize.isEmpty { args.append("-v" + volumeSize) }

        if format.isTarCompound {
            // tar.* — najpierw tar w katalogu tymczasowym, potem kompresja jednego pliku.
            let tmpDir = archive.parent!.appending(".bifold-tar-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(atPath: tmpDir.path, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: tmpDir.path) }
            let tarPath = tmpDir.appending(innerName)
            let tarOut = try run(["a", "-ttar", tarPath.path, "@" + list.path], directory: base.path, isCancelled: isCancelled)
            guard tarOut.status == 0 else { throw ArchiveError.failed(tarOut.stderr) }
            var second = ["a", "-t" + format.sevenZipType, "-mx=\(level)", archive.path, tarPath.path]
            if let volumeSize, !volumeSize.isEmpty { second.append("-v" + volumeSize) }
            let out = try run(second, isCancelled: isCancelled)
            guard out.status == 0 else { throw ArchiveError.failed(out.stderr) }
            return
        }
        let out = try run(args, password: password.map { "\($0)\n\($0)" }, directory: base.path, isCancelled: isCancelled)
        guard out.status == 0 else { throw ArchiveError.failed(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
