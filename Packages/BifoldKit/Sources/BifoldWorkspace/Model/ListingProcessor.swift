import BifoldCore
import Foundation

public enum ViewMode: String, Codable, Sendable, CaseIterable {
    case details, brief, thumbnails, columns

    public var displayName: String {
        switch self {
        case .details: L10n.tr("Szczegóły")
        case .brief: L10n.tr("Lista skrócona")
        case .thumbnails: L10n.tr("Miniatury")
        case .columns: L10n.tr("Kolumny")
        }
    }
}

public enum SortField: String, Codable, Sendable, CaseIterable {
    case name, ext, size, modified, created

    public var displayName: String {
        switch self {
        case .name: L10n.tr("Nazwa")
        case .ext: L10n.tr("Rozszerzenie")
        case .size: L10n.tr("Rozmiar")
        case .modified: L10n.tr("Data modyfikacji")
        case .created: L10n.tr("Data utworzenia")
        }
    }
}

public struct SortSpec: Codable, Sendable, Hashable {
    public var field: SortField
    public var ascending: Bool

    public init(field: SortField = .name, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }
}

extension FileFlags {
    /// Wiersz „..” (katalog nadrzędny) na początku listy.
    public static let parentLink = FileFlags(rawValue: 1 << 8)
}

extension FileItem {
    public var isParentLink: Bool { flags.contains(.parentLink) }

    static func parentLink(for directory: VFSPath) -> FileItem? {
        guard let parent = directory.parent else { return nil }
        return FileItem(path: parent, name: "..", kind: .directory, flags: [.parentLink])
    }
}

/// Filtrowanie i sortowanie listingu — czysta funkcja, wykonywana poza głównym wątkiem.
public enum ListingProcessor {
    public struct Options: Sendable, Hashable {
        public var sort: SortSpec
        public var showHidden: Bool
        public var filter: String
        public var directorySizes: [VFSPath: Int64]
        /// Wiersz „..” w korzeniu archiwum prowadzi do katalogu z plikiem archiwum.
        public var parentOverride: VFSPath?

        public init(sort: SortSpec = SortSpec(), showHidden: Bool = false, filter: String = "", directorySizes: [VFSPath: Int64] = [:], parentOverride: VFSPath? = nil) {
            self.sort = sort
            self.showHidden = showHidden
            self.filter = filter
            self.directorySizes = directorySizes
            self.parentOverride = parentOverride
        }
    }

    public static func process(_ items: [FileItem], in directory: VFSPath, options: Options) -> [FileItem] {
        var result = items
        if !options.showHidden { result.removeAll { $0.isHidden } }
        if !options.filter.isEmpty { result = filter(result, options.filter) }
        result = sort(result, options)
        if let parent = FileItem.parentLink(for: directory) {
            result.insert(parent, at: 0)
        } else if let host = options.parentOverride {
            result.insert(FileItem(path: host, name: "..", kind: .directory, flags: [.parentLink]), at: 0)
        }
        return result
    }

    /// Filtr panelu: maska (gdy zawiera `*`, `?`, `;` lub `|`) albo fragment nazwy.
    static func filter(_ items: [FileItem], _ text: String) -> [FileItem] {
        if text.contains(where: { "*?;|[".contains($0) }) {
            let mask = NameMask(text)
            return items.filter { $0.isNavigable || mask.matches($0) }
        }
        return items.filter { $0.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Sortowanie: katalogi zawsze przed plikami, potem wg pola; remisy wg nazwy.
    /// Duże listy sortowane równolegle w kawałkach i scalane.
    public static func sort(_ items: [FileItem], _ options: Options) -> [FileItem] {
        let keyed = parallelMap(items) { SortKey(item: $0, options: options) }
        let ascending = options.sort.ascending
        let less: @Sendable (SortKey, SortKey) -> Bool = { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let c = a.compare(b)
            if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
            return a.item.name < b.item.name
        }
        return parallelSort(keyed, by: less).map(\.item)
    }

    static func parallelMap<T: Sendable, U: Sendable>(_ array: [T], _ transform: @escaping @Sendable (T) -> U) -> [U] {
        let chunkCount = array.count > 5_000 ? min(ProcessInfo.processInfo.activeProcessorCount, 16) : 1
        guard chunkCount > 1 else { return array.map(transform) }
        let chunkSize = (array.count + chunkCount - 1) / chunkCount
        let chunks = UnsafeChunks<U>(count: chunkCount)
        DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
            let start = i * chunkSize
            let end = min(start + chunkSize, array.count)
            chunks.set(i, start < end ? array[start..<end].map(transform) : [])
        }
        return chunks.all.flatMap { $0 }
    }

    static func parallelSort<T: Sendable>(_ array: [T], by less: @escaping @Sendable (T, T) -> Bool) -> [T] {
        let chunkCount = array.count > 20_000 ? min(ProcessInfo.processInfo.activeProcessorCount, 16) : 1
        guard chunkCount > 1 else { return array.sorted(by: less) }
        let chunkSize = (array.count + chunkCount - 1) / chunkCount
        let chunks = UnsafeChunks<T>(count: chunkCount)
        DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
            let start = i * chunkSize
            let end = min(start + chunkSize, array.count)
            chunks.set(i, start < end ? array[start..<end].sorted(by: less) : [])
        }
        var parts = chunks.all
        while parts.count > 1 {
            let pairs = (parts.count + 1) / 2
            let next = UnsafeChunks<T>(count: pairs)
            let current = parts
            DispatchQueue.concurrentPerform(iterations: pairs) { j in
                let a = 2 * j
                next.set(j, a + 1 < current.count ? merge(current[a], current[a + 1], less) : current[a])
            }
            parts = next.all
        }
        return parts.first ?? []
    }

    static func merge<T>(_ a: [T], _ b: [T], _ less: (T, T) -> Bool) -> [T] {
        var out: [T] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if less(b[j], a[i]) { out.append(b[j]); j += 1 } else { out.append(a[i]); i += 1 }
        }
        out.append(contentsOf: a[i...])
        out.append(contentsOf: b[j...])
        return out
    }
}

/// Bufor wyników równoległego sortowania (każdy indeks zapisywany przez jeden wątek).
private final class UnsafeChunks<T>: @unchecked Sendable {
    private var storage: [[T]]
    private let lock = NSLock()
    init(count: Int) { storage = Array(repeating: [], count: count) }
    func set(_ i: Int, _ v: [T]) { lock.withLock { storage[i] = v } }
    var all: [[T]] { lock.withLock { storage } }
}

/// Klucz sortowania z policzonymi wcześniej wartościami (porównanie nazw jest najdroższe,
/// więc nazwy zamieniamy raz na klucze `NameCollation`).
struct SortKey: Sendable {
    let item: FileItem
    let isDir: Bool
    let field: SortField
    let size: Int64
    let nameKey: [UInt32]
    let extKey: [UInt32]

    init(item: FileItem, options: ListingProcessor.Options) {
        self.item = item
        isDir = item.isNavigable
        field = options.sort.field
        size = item.isNavigable ? (options.directorySizes[item.path] ?? -1) : item.size
        nameKey = NameCollation.key(item.name)
        extKey = field == .ext ? NameCollation.key(item.fileExtension) : []
    }

    func compareNames(_ other: SortKey) -> ComparisonResult {
        let c = NameCollation.compare(nameKey, other.nameKey)
        return c != .orderedSame ? c : item.name.localizedStandardCompare(other.item.name)
    }

    func compare(_ other: SortKey) -> ComparisonResult {
        switch field {
        case .name:
            return compareNames(other)
        case .ext:
            let c = NameCollation.compare(extKey, other.extKey)
            return c != .orderedSame ? c : compareNames(other)
        case .size:
            if size != other.size { return size < other.size ? .orderedAscending : .orderedDescending }
            return compareNames(other)
        case .modified:
            return compareDates(item.modified, other.item.modified, other)
        case .created:
            return compareDates(item.created, other.item.created, other)
        }
    }

    private func compareDates(_ a: Date?, _ b: Date?, _ other: SortKey) -> ComparisonResult {
        let x = a ?? .distantPast, y = b ?? .distantPast
        if x != y { return x < y ? .orderedAscending : .orderedDescending }
        return compareNames(other)
    }
}
