import Foundation

/// Identyfikator dostawcy systemu plików: `local`, `archive:<id>`, `remote:<alias>`, `device:<id>`.
public struct ProviderID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let local = ProviderID("local")

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Adres elementu w dowolnym systemie plików. Ścieżka jest zawsze absolutna i znormalizowana
/// (bez `.`, `..`, podwójnych i końcowych ukośników).
public struct VFSPath: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public let provider: ProviderID
    public let path: String

    public init(provider: ProviderID = .local, path: String) {
        self.provider = provider
        self.path = VFSPath.normalize(path)
    }

    /// Bez normalizacji — dla ścieżek składanych z już znormalizowanych części (listowanie).
    init(provider: ProviderID, normalizedPath: String) {
        self.provider = provider
        self.path = normalizedPath
    }

    public static func local(_ path: String) -> VFSPath { VFSPath(provider: .local, path: path) }
    public static func local(_ url: URL) -> VFSPath { VFSPath(provider: .local, path: url.path(percentEncoded: false)) }

    public static let root = VFSPath.local("/")

    public var isLocal: Bool { provider == .local }
    public var isRoot: Bool { path == "/" }

    /// URL pliku dla ścieżek lokalnych.
    public var url: URL? {
        guard isLocal else { return nil }
        return URL(filePath: path, directoryHint: .inferFromPath)
    }

    public var components: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Ostatni komponent (dla `/` zwraca `/`).
    public var name: String { components.last ?? "/" }

    public var parent: VFSPath? {
        guard !isRoot else { return nil }
        var comps = components
        comps.removeLast()
        return VFSPath(provider: provider, path: "/" + comps.joined(separator: "/"))
    }

    public func appending(_ name: String) -> VFSPath {
        VFSPath(provider: provider, path: path == "/" ? "/" + name : path + "/" + name)
    }

    /// Czy `self` leży w `ancestor` lub jest nim (porównanie po komponentach).
    public func isDescendant(of ancestor: VFSPath, orEqual: Bool = true, caseInsensitive: Bool = false) -> Bool {
        guard provider == ancestor.provider else { return false }
        let a = ancestor.components, s = components
        guard s.count >= a.count else { return false }
        if s.count == a.count && !orEqual { return false }
        for (x, y) in zip(a, s) {
            if caseInsensitive {
                if x.compare(y, options: .caseInsensitive) != .orderedSame { return false }
            } else if x != y {
                return false
            }
        }
        return true
    }

    public var description: String {
        provider == .local ? path : "\(provider.rawValue):\(path)"
    }

    public static func < (lhs: VFSPath, rhs: VFSPath) -> Bool {
        (lhs.provider.rawValue, lhs.path) < (rhs.provider.rawValue, rhs.path)
    }

    /// Normalizacja tekstowa (nie rozwiązuje dowiązań symbolicznych).
    public static func normalize(_ raw: String) -> String {
        var stack: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }
}

extension String {
    /// Rozszerzenie nazwy pliku bez kropki (pliki ukryte typu `.zshrc` nie mają rozszerzenia).
    public var fileExtension: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return "" }
        return String(self[index(after: dot)...])
    }

    /// Nazwa bez rozszerzenia.
    public var fileStem: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return self }
        return String(self[..<dot])
    }
}
