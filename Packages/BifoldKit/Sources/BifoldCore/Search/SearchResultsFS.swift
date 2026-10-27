import Foundation
import Synchronization

/// Wyniki wyszukiwania jako „katalog” w panelu (TC: Feed to listbox). Elementy mają
/// prawdziwe ścieżki lokalne, więc wszystkie operacje (kopiowanie, Kosz, zmiana nazw) działają.
public final class SearchResultsFS: FileSystemProvider {
    public let id: ProviderID
    public let title: String
    public let capabilities: ProviderCapabilities = [.read]
    private let items: Mutex<[FileItem]>

    public init(title: String, items: [FileItem]) {
        id = ProviderID("search:\(UUID().uuidString.prefix(8).lowercased())")
        self.title = title
        self.items = Mutex(items)
    }

    public var root: VFSPath { VFSPath(provider: id, path: "/") }

    public func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        // Elementy usunięte od czasu wyszukiwania znikają z listy.
        let current = items.withLock { $0 }
        let fs = LocalFS()
        let fresh = current.compactMap { try? fs.itemSync(at: $0.path) }
        items.withLock { $0 = fresh }
        return options.includeHidden ? fresh : fresh.filter { !$0.isHidden }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path == root { return FileItem(path: root, name: title, kind: .directory) }
        return try LocalFS().itemSync(at: .local(path.path))
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data {
        try LocalFS().readSync(.local(path.path), range: range)
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        try Volumes.info(for: .root)
    }

    public static func isSearchResults(_ path: VFSPath) -> Bool {
        path.provider.rawValue.hasPrefix("search:")
    }
}

/// Spotlight (`NSMetadataQuery`): zapytanie tekstowe (nazwa lub treść) w zakresie katalogów.
@MainActor
public final class SpotlightSearch {
    private let query = NSMetadataQuery()
    private var observer: (any NSObjectProtocol)?
    private var continuation: CheckedContinuation<[VFSPath], Never>?
    private var limit = 2000

    public static func run(_ text: String, scopes: [VFSPath], limit: Int = 2000, timeout: Double = 15) async -> [VFSPath] {
        await SpotlightSearch().run(text, scopes: scopes, limit: limit, timeout: timeout)
    }

    private func run(_ text: String, scopes: [VFSPath], limit: Int, timeout: Double) async -> [VFSPath] {
        self.limit = limit
        guard let predicate = Self.predicate(for: text) else { return [] }
        query.predicate = predicate
        query.searchScopes = scopes.isEmpty ? [NSMetadataQueryUserHomeScope] : scopes.compactMap(\.url)
        return await withCheckedContinuation { c in
            continuation = c
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
            // Zapytania, którego Spotlight nie przyjmie, nie ma na co czekać.
            guard query.start() else { finish(); return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish()
            }
        }
    }

    /// Predykat dla tekstu z pola wyszukiwania lub od agenta. `NSPredicate(fromMetadataQueryString:)`
    /// rzuca NSException (przerwanie procesu) przy błędzie składni, a `NSMetadataQuery` nie umie
    /// przetłumaczyć ukośnika wstecznego nawet z predykatu zbudowanego ręcznie (`start()` zwraca
    /// `false`). Dlatego: `"` jest poprzedzany ukośnikiem, `\` zastępuje symbol wieloznaczny `?`
    /// (dowolny znak — wynik obejmuje nazwy z ukośnikiem), znaki sterujące (w tym NUL) i niecharaktery
    /// Unicode (U+FDD0…U+FDEF, U+xxFFFE/U+xxFFFF — parser wykłada się na U+FFFE i U+FFFF) są pomijane.
    nonisolated static func predicate(for text: String) -> NSPredicate? {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "?"
            case "\"": escaped += "\\\""
            case _ where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value): continue
            case _ where (0xFDD0...0xFDEF).contains(scalar.value) || scalar.value & 0xFFFE == 0xFFFE: continue
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        guard !escaped.isEmpty else { return nil }
        return NSPredicate(fromMetadataQueryString:
            "(kMDItemFSName == \"*\(escaped)*\"cd) || (kMDItemTextContent == \"\(escaped)\"cd) || (kMDItemDisplayName == \"*\(escaped)*\"cd)")
    }

    private func finish() {
        guard let c = continuation else { return }
        continuation = nil
        query.stop()
        var out: [VFSPath] = []
        for i in 0..<min(query.resultCount, limit) {
            if let item = query.result(at: i) as? NSMetadataItem, let p = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                out.append(.local(p))
            }
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        c.resume(returning: out)
    }
}
