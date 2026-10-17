import CryptoKit
import Foundation

public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable {
    case md5, sha1, sha256

    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        }
    }

    /// Rozpoznanie po rozszerzeniu pliku sum (`.md5`, `.sha1`, `.sha256`, `.sha`).
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "md5": self = .md5
        case "sha1", "sha": self = .sha1
        case "sha256": self = .sha256
        default: return nil
        }
    }
}

/// Sumy kontrolne (CryptoKit), strumieniowo w blokach 1 MB.
public enum Checksums {
    public static func hash(_ path: VFSPath, algorithm: ChecksumAlgorithm, isCancelled: () -> Bool = { false }) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path.path) else { throw VFSError.notFound(path) }
        defer { try? handle.close() }
        func run<H: HashFunction>(_ h: inout H) throws -> String {
            while true {
                if isCancelled() { throw VFSError.cancelled }
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                h.update(data: chunk)
            }
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch algorithm {
        case .md5: var h = Insecure.MD5(); return try run(&h)
        case .sha1: var h = Insecure.SHA1(); return try run(&h)
        case .sha256: var h = SHA256(); return try run(&h)
        }
    }

    /// Plik sum w formacie `hash *nazwa` (zgodny z md5sum/shasum -b i Total Commanderem).
    public static func format(_ entries: [(hash: String, relativePath: String)]) -> String {
        entries.map { "\($0.hash) *\($0.relativePath)" }.joined(separator: "\n") + "\n"
    }

    public struct Entry: Sendable, Hashable {
        public var hash: String
        public var path: String
    }

    /// Odczyt pliku sum: `hash *nazwa`, `hash  nazwa` albo `MD5 (nazwa) = hash` (BSD).
    public static func parse(_ text: String) -> [Entry] {
        var out: [Entry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), let eq = line.range(of: ") = ") {
                let name = String(line[line.index(after: open)..<close])
                out.append(Entry(hash: String(line[eq.upperBound...]).lowercased(), path: name))
                continue
            }
            guard let space = line.firstIndex(of: " ") else { continue }
            let hash = String(line[..<space]).lowercased()
            var name = line[line.index(after: space)...].drop { $0 == " " }
            if name.hasPrefix("*") { name = name.dropFirst() }
            guard hash.allSatisfy(\.isHexDigit) else { continue }
            out.append(Entry(hash: hash, path: String(name)))
        }
        return out
    }

    public enum VerifyStatus: String, Sendable, Codable { case ok, mismatch, missing }

    public struct VerifyResult: Sendable, Hashable {
        public var path: String
        public var status: VerifyStatus
    }

    /// Sprawdza pozycje pliku sum względem katalogu, w którym leży plik sum.
    public static func verify(checksumFile: VFSPath, isCancelled: () -> Bool = { false }) throws -> [VerifyResult] {
        guard let algorithm = ChecksumAlgorithm(fileExtension: checksumFile.name.fileExtension) else {
            throw VFSError.unsupported("checksum file")
        }
        let text = String(decoding: try LocalFS().readSync(checksumFile), as: UTF8.self)
        let base = checksumFile.parent ?? .root
        return try parse(text).map { e in
            let p = e.path.hasPrefix("/") ? VFSPath.local(e.path) : VFSPath.local(base.path + "/" + e.path)
            guard FileManager.default.fileExists(atPath: p.path) else { return VerifyResult(path: e.path, status: .missing) }
            let h = try hash(p, algorithm: algorithm, isCancelled: isCancelled)
            return VerifyResult(path: e.path, status: h == e.hash ? .ok : .mismatch)
        }
    }
}

/// Wyszukiwanie duplikatów: grupy po rozmiarze, potem po haszu (najpierw pierwsze 64 KB,
/// potem całość), opcjonalnie wymagana ta sama nazwa.
public enum DuplicateFinder {
    public enum Mode: String, Codable, Sendable, CaseIterable { case content, nameAndSize, name }

    public static func find(in roots: [VFSPath], mode: Mode = .content, minSize: Int64 = 1, includeHidden: Bool = false, isCancelled: @escaping () -> Bool = { false }) throws -> [[FileItem]] {
        var files: [FileItem] = []
        let fs = LocalFS()
        var stack = roots
        while let dir = stack.popLast() {
            if isCancelled() { throw VFSError.cancelled }
            guard let items = try? fs.listSync(dir) else { continue }
            for item in items where includeHidden || !item.isHidden {
                if item.kind == .directory { stack.append(item.path) }
                else if item.kind == .file && item.size >= minSize { files.append(item) }
            }
        }
        switch mode {
        case .name:
            return group(files) { $0.name.lowercased() }
        case .nameAndSize:
            return group(files) { "\($0.name.lowercased())|\($0.size)" }
        case .content:
            var result: [[FileItem]] = []
            for sameSize in group(files, by: { "\($0.size)" }) {
                let partial = group(sameSize) { (try? prefixHash($0.path)) ?? UUID().uuidString }
                for candidates in partial {
                    if isCancelled() { throw VFSError.cancelled }
                    result += group(candidates) { (try? Checksums.hash($0.path, algorithm: .sha256, isCancelled: isCancelled)) ?? UUID().uuidString }
                }
            }
            return result.sorted { ($0.first?.size ?? 0) > ($1.first?.size ?? 0) }
        }
    }

    static func group(_ items: [FileItem], by key: (FileItem) -> String) -> [[FileItem]] {
        Dictionary(grouping: items, by: key).values.filter { $0.count > 1 }.map { $0.sorted { $0.path < $1.path } }
    }

    static func prefixHash(_ path: VFSPath) throws -> String {
        let data = try LocalFS().readSync(path, range: 0..<65_536)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Dzielenie pliku na części (`nazwa.001`, `nazwa.002`, …) z plikiem `.sha256` do kontroli
/// i łączenie części z powrotem (z weryfikacją, jeśli jest plik sum).
public enum FileSplitter {
    public static func partName(_ base: String, index: Int) -> String {
        String(format: "%@.%03d", base, index)
    }

    /// Zwraca ścieżki utworzonych plików (części + plik sum).
    @discardableResult
    public static func split(_ source: VFSPath, partSize: Int64, into directory: VFSPath, isCancelled: () -> Bool = { false }) throws -> [VFSPath] {
        precondition(partSize > 0)
        guard let input = FileHandle(forReadingAtPath: source.path) else { throw VFSError.notFound(source) }
        defer { try? input.close() }
        var created: [VFSPath] = []
        var index = 1
        do {
            while true {
                if isCancelled() { throw VFSError.cancelled }
                var remaining = partSize
                var first = true
                var output: FileHandle?
                let part = directory.appending(partName(source.name, index: index))
                while remaining > 0 {
                    let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
                    if chunk.isEmpty { break }
                    if first {
                        guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: nil) else { throw VFSError.alreadyExists(part) }
                        output = FileHandle(forWritingAtPath: part.path)
                        created.append(part)
                        first = false
                    }
                    try output?.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                }
                try output?.close()
                if first { break }
                index += 1
            }
            let sum = directory.appending(source.name + ".sha256")
            let hash = try Checksums.hash(source, algorithm: .sha256)
            try Data(Checksums.format([(hash, source.name)]).utf8).write(to: URL(filePath: sum.path), options: .withoutOverwriting)
            created.append(sum)
        } catch {
            for p in created { try? FileManager.default.removeItem(atPath: p.path) }
            throw error
        }
        return created
    }

    /// Części zaczynające się od `first` (`x.001` → `x.001`, `x.002`, …).
    public static func parts(startingWith first: VFSPath) -> [VFSPath] {
        let ext = first.name.fileExtension
        guard ext.count == 3, Int(ext) != nil, let parent = first.parent else { return [first] }
        let base = first.name.fileStem
        var out: [VFSPath] = []
        var i = 1
        while true {
            let p = parent.appending(partName(base, index: i))
            guard FileManager.default.fileExists(atPath: p.path) else { break }
            out.append(p)
            i += 1
        }
        return out
    }

    /// Łączy części w plik `target`. Zwraca `true`/`false` dla weryfikacji sumą (albo `nil`, gdy brak pliku sum).
    @discardableResult
    public static func join(_ parts: [VFSPath], into target: VFSPath, isCancelled: () -> Bool = { false }) throws -> Bool? {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw VFSError.alreadyExists(target) }
        guard FileManager.default.createFile(atPath: target.path, contents: nil), let output = FileHandle(forWritingAtPath: target.path) else {
            throw VFSError.permissionDenied(target)
        }
        do {
            for part in parts {
                guard let input = FileHandle(forReadingAtPath: part.path) else { throw VFSError.notFound(part) }
                while true {
                    if isCancelled() { throw VFSError.cancelled }
                    let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                    if chunk.isEmpty { break }
                    try output.write(contentsOf: chunk)
                }
                try input.close()
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(atPath: target.path)
            throw error
        }
        guard let first = parts.first, let parent = first.parent else { return nil }
        let sumFile = parent.appending(first.name.fileStem + ".sha256")
        guard let text = try? String(contentsOfFile: sumFile.path, encoding: .utf8), let expected = Checksums.parse(text).first else { return nil }
        return try Checksums.hash(target, algorithm: .sha256) == expected.hash
    }
}
