import Foundation
import Synchronization

/// Archiwum jako katalog (7zz): wejście, przeglądanie, podgląd i kopiowanie z archiwum.
/// Ścieżki w obrębie dostawcy zaczynają się od `/` (korzeń archiwum).
public final class ArchiveFS: FileSystemProvider {
    public let id: ProviderID
    /// Plik archiwum na dysku lokalnym.
    public let archive: VFSPath
    public let tool: SevenZip
    public let capabilities: ProviderCapabilities = [.read]
    public let isEncrypted: Bool
    private let password: String?
    private let tree: [String: [SevenZip.Entry]]
    /// Klucze w NFC (nazwy w archiwum bywają w NFD); `Entry.path` zostaje oryginalne dla 7zz.
    private let entriesByPath: [String: SevenZip.Entry]

    /// Klucz wpisu: bez składników `.` (tar z „.” ma wpisy `./kat/a.txt`) i w NFC.
    static func key(_ path: String) -> String {
        ("/" + path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")).precomposedStringWithCanonicalMapping
    }

    /// Wpis, który da się pokazać i rozpakować: nie korzeń archiwum (`.`), a każdy składnik ścieżki to
    /// bezpieczna nazwa (bez `..` — 7zz rozpakowuje `../x` jako `x`, a ścieżka liczona z nazwy wskazywałaby
    /// plik poza katalogiem tymczasowym — i bez znaków sterujących, jak nazwy z urządzeń, D46).
    /// Składniki `.` (tar z „.”: `./kat/a.txt`) są pomijane, jak w `key`.
    static func isUsable(_ path: String) -> Bool {
        let components = path.split(separator: "/").filter { $0 != "." }
        return !components.isEmpty && components.allSatisfy { isSafeComponentName(String($0)) }
    }

    public var hostLocation: VFSPath? { archive }
    public var root: VFSPath { VFSPath(provider: id, path: "/") }

    /// Rozszerzenia rozpoznawane jako archiwa (Enter wchodzi do środka).
    public static let extensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "jar", "war", "cab", "lzma", "zst", "iso", "dmg", "cpio", "rpm", "deb", "arj", "lzh"]

    public static func isArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = lower.fileExtension
        if extensions.contains(ext) { return true }
        // Pierwsza część archiwum wieloczęściowego: x.7z.001, x.zip.001, x.part1.rar
        if ext == "001", extensions.contains(lower.fileStem.fileExtension) { return true }
        return false
    }

    /// Otwiera archiwum (listowanie przez `7zz l -slt`). Rzuca `ArchiveError.passwordRequired`
    /// dla archiwów z zaszyfrowanymi nagłówkami bez hasła.
    public init(archive: VFSPath, tool: SevenZip, password: String? = nil) throws {
        self.archive = archive
        self.tool = tool
        self.password = password
        id = ProviderID("archive:\(UUID().uuidString.prefix(8).lowercased())")
        let entries = try tool.list(archive, password: password).filter { Self.isUsable($0.path) }
        var byPath: [String: SevenZip.Entry] = [:]
        var tree: [String: [SevenZip.Entry]] = [:]
        // Katalogi pośrednie, których archiwum nie zawiera jawnie (częste w ZIP).
        for e in entries {
            let normalized = Self.key(e.path)
            byPath[normalized] = e
            var parent = (normalized as NSString).deletingLastPathComponent
            while parent != "/" && byPath[parent] == nil {
                byPath[parent] = SevenZip.Entry(path: String(parent.dropFirst()), isDirectory: true, size: 0, modified: e.modified, encrypted: false)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for (path, e) in byPath {
            tree[(path as NSString).deletingLastPathComponent, default: []].append(e)
        }
        self.tree = tree
        entriesByPath = byPath
        isEncrypted = entries.contains { $0.encrypted }
    }

    func item(for entry: SevenZip.Entry) -> FileItem {
        let path = Self.key(entry.path)
        return FileItem(
            path: VFSPath(provider: id, path: path), kind: entry.isDirectory ? .directory : .file,
            size: entry.isDirectory ? -1 : entry.size, modified: entry.modified,
            permissions: entry.isDirectory ? 0o755 : 0o644, flags: entry.encrypted ? [.locked] : [])
    }

    /// Ścieżka wpisu wewnątrz archiwum (bez początkowego `/`).
    public func entryPath(_ path: VFSPath) -> String {
        entriesByPath[Self.key(path.path)]?.path ?? String(path.path.dropFirst())
    }

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        let items = (tree[Self.key(directory.path)] ?? []).map(item(for:))
        return options.includeHidden ? items : items.filter { !$0.isHidden }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: root, name: archive.name, kind: .directory) }
        guard let e = entriesByPath[Self.key(path.path)] else { throw VFSError.notFound(path) }
        return item(for: e)
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        let tool = tool, archive = archive, password = password, entry = entryPath(path)
        // Z zakresem — strumieniowo, bez wczytywania całego wpisu (podgląd początku pliku 6 GB).
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await runBlocking { try tool.read(archive, entry: entry, password: password, range: range, isCancelled: { flag.isCancelled }) }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Rozpakowuje jeden plik do katalogu (bez ścieżki z archiwum) i zwraca jego ścieżkę lokalną —
    /// do podglądu dużych plików bez trzymania ich w pamięci.
    public func extractFile(_ path: VFSPath, to directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> VFSPath {
        guard let entry = entriesByPath[Self.key(path.path)], !entry.isDirectory else { throw VFSError.notFound(path) }
        return try tool.extractEntry(archive, entry: entry.path, to: directory, password: password, isCancelled: isCancelled)
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        try Volumes.info(for: archive)
    }

    /// Wszystkie pliki poddrzewa (do rozpakowania wybranych elementów i liczenia rozmiaru).
    public func descendants(of path: VFSPath) -> [SevenZip.Entry] {
        let k = Self.key(path.path)
        let prefix = path.isRoot ? "/" : k + "/"
        return entriesByPath.filter { $0.key.hasPrefix(prefix) || $0.key == k }.map(\.value)
    }

    /// Rozpakowuje wskazane elementy (pliki lub katalogi) do katalogu docelowego bez ścieżki
    /// nadrzędnej w archiwum: `a/b/c.txt` trafia jako `c.txt`. Najpierw do katalogu tymczasowego
    /// na woluminie docelowym, potem przeniesienie silnikiem kopiowania (konflikty, dziennik).
    public func extractionPlan(_ paths: [VFSPath]) -> [String] {
        paths.map(entryPath)
    }

    public func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        let temp = directory.appending(".bifold-extract-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: false)
        do {
            let entries = paths.flatMap { p -> [String] in
                let e = entryPath(p)
                return entriesByPath[Self.key(p.path)]?.isDirectory == true ? [e, e + "/*"] : [e]
            }
            try tool.extract(archive, to: temp, entries: entries, overwrite: .overwrite, password: password, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(atPath: temp.path)
            throw error
        }
        // Rozpakowane elementy (nazwy jak w archiwum; APFS i tak porównuje bez względu na normalizację).
        return (temp, paths.map { VFSPath.local(temp.path + "/" + entryPath($0)) })
    }

    public static func isArchivePath(_ path: VFSPath) -> Bool {
        path.provider.rawValue.hasPrefix("archive:")
    }
}
