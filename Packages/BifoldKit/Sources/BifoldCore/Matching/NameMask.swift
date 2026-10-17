import Foundation

/// Maska nazw w stylu Total Commandera:
/// - kilka wzorców oddzielonych `;` (albo spacją, gdy nie ma `;`),
/// - wzorce po `|` wykluczają,
/// - `*` dowolny ciąg, `?` jeden znak, `[abc]` / `[a-z]` klasa znaków,
/// - `*.*` pasuje także do nazw bez rozszerzenia (jak w TC),
/// - wzorzec zakończony `/` dotyczy tylko katalogów,
/// - bez rozróżniania wielkości liter.
public struct NameMask: Sendable, Hashable, CustomStringConvertible {
    public let pattern: String
    private let include: [Glob]
    private let exclude: [Glob]

    public init(_ pattern: String) {
        self.pattern = pattern
        let parts = pattern.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        include = NameMask.parseList(parts.first.map(String.init) ?? "")
        exclude = parts.count > 1 ? NameMask.parseList(String(parts[1])) : []
    }

    public var description: String { pattern }

    /// Pusta lista wzorców włączających oznacza „wszystko”.
    public func matches(_ name: String, isDirectory: Bool = false) -> Bool {
        let included = include.isEmpty || include.contains { $0.matches(name, isDirectory: isDirectory) }
        guard included else { return false }
        return !exclude.contains { $0.matches(name, isDirectory: isDirectory) }
    }

    public func matches(_ item: FileItem) -> Bool {
        matches(item.name, isDirectory: item.isNavigable)
    }

    private static func parseList(_ text: String) -> [Glob] {
        let separators: Set<Character> = text.contains(";") ? [";"] : [" "]
        return text.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(Glob.init)
    }
}

/// Pojedynczy wzorzec glob skompilowany do wyrażenia regularnego.
struct Glob: Sendable, Hashable {
    let source: String
    let directoriesOnly: Bool
    let matchesEverything: Bool
    private let regex: NSRegularExpressionBox?

    init(_ raw: String) {
        var text = raw
        directoriesOnly = text.hasSuffix("/") || text.hasSuffix("\\")
        if directoriesOnly { text.removeLast() }
        source = text
        matchesEverything = text == "*" || text == "*.*"
        regex = matchesEverything ? nil : NSRegularExpressionBox(pattern: Glob.regexPattern(for: text))
    }

    func matches(_ name: String, isDirectory: Bool) -> Bool {
        if directoriesOnly && !isDirectory { return false }
        if matchesEverything { return true }
        return regex?.matchesWhole(name) ?? false
    }

    static func regexPattern(for glob: String) -> String {
        var out = "^"
        var inClass = false
        for ch in glob {
            if inClass {
                if ch == "]" { inClass = false; out.append("]") }
                else if ch == "\\" { out.append("\\\\") }
                else { out.append(ch) }
                continue
            }
            switch ch {
            case "*": out.append(".*")
            case "?": out.append(".")
            case "[": inClass = true; out.append("[")
            default: out.append(NSRegularExpression.escapedPattern(for: String(ch)))
            }
        }
        if inClass { out.append("]") }
        // „nazwa.*” pasuje też do „nazwa” (TC).
        if glob.hasSuffix(".*") { out = String(out.dropLast(4)) + "(\\..*)?" }
        return out + "$"
    }
}

/// `NSRegularExpression` jest niezmienny i bezpieczny wątkowo; opakowanie daje Sendable/Hashable.
struct NSRegularExpressionBox: @unchecked Sendable, Hashable {
    let regex: NSRegularExpression
    let pattern: String

    init?(pattern: String, caseInsensitive: Bool = true) {
        guard let r = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return nil
        }
        regex = r
        self.pattern = pattern
    }

    func matchesWhole(_ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func matchesAnywhere(_ s: String) -> Bool { matchesWhole(s) }

    static func == (a: Self, b: Self) -> Bool { a.pattern == b.pattern }
    func hash(into h: inout Hasher) { h.combine(pattern) }
}

/// Dopasowanie nazwy wyrażeniem regularnym (w dowolnym miejscu nazwy).
public struct NameRegex: Sendable, Hashable {
    public let pattern: String
    private let box: NSRegularExpressionBox?

    public init(_ pattern: String, caseInsensitive: Bool = true) {
        self.pattern = pattern
        box = NSRegularExpressionBox(pattern: pattern, caseInsensitive: caseInsensitive)
    }

    public var isValid: Bool { box != nil }

    public func matches(_ name: String) -> Bool { box?.matchesAnywhere(name) ?? false }
}
