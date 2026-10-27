import Foundation
import Synchronization

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
/// Każde dopasowanie ma limit czasu (`RegexSafety`); po pierwszym przekroczeniu wzorzec uznaje się za
/// zbyt złożony i dalej nie pasuje do niczego (bez kolejnych prób — kolorowanie wierszy na wątku
/// głównym i wyszukiwanie w tysiącach plików nie czekają na każdym pliku od nowa).
struct NSRegularExpressionBox: @unchecked Sendable, Hashable {
    /// Limit czasu procesora jednego dopasowania nazwy.
    static let matchLimit: Duration = .milliseconds(100)

    let regex: NSRegularExpression
    let pattern: String
    private let exceeded = ExceededFlag()

    init?(pattern: String, caseInsensitive: Bool = true) {
        guard let r = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return nil
        }
        regex = r
        self.pattern = pattern
    }

    /// Czy któreś dopasowanie przekroczyło limit czasu.
    var exceededTimeLimit: Bool { exceeded.isSet }

    func matchesWhole(_ s: String) -> Bool {
        guard !exceeded.isSet else { return false }
        guard let found = regex.matches(in: s, limit: Self.matchLimit, first: true) else {
            exceeded.set()
            return false
        }
        return !found.isEmpty
    }

    func matchesAnywhere(_ s: String) -> Bool { matchesWhole(s) }

    static func == (a: Self, b: Self) -> Bool { a.pattern == b.pattern && a.regex.options == b.regex.options }
    func hash(into h: inout Hasher) { h.combine(pattern) }
}

/// Znacznik ustawiany raz, czytany z wielu wątków.
final class ExceededFlag: Sendable {
    private let state = Atomic<Bool>(false)
    var isSet: Bool { state.load(ordering: .relaxed) }
    func set() { state.store(true, ordering: .relaxed) }
}

/// Dopasowanie nazwy wyrażeniem regularnym (w dowolnym miejscu nazwy). Wzorzec ryzykowny
/// (`RegexSafety.issue(in:)`) jest odrzucany jak niepoprawny: `isValid == false`, `issue` mówi dlaczego.
public struct NameRegex: Sendable, Hashable {
    public let pattern: String
    /// Powód odrzucenia wzorca przed kompilacją (zbyt długi, zbyt złożony).
    public let issue: RegexSafety.Issue?
    private let box: NSRegularExpressionBox?

    public init(_ pattern: String, caseInsensitive: Bool = true) {
        self.pattern = pattern
        issue = RegexSafety.issue(in: pattern)
        box = issue == nil ? NSRegularExpressionBox(pattern: pattern, caseInsensitive: caseInsensitive) : nil
    }

    public var isValid: Bool { box != nil }

    /// Wzorzec przekroczył limit czasu dopasowania — od tej chwili nie pasuje do niczego.
    public var exceededTimeLimit: Bool { box?.exceededTimeLimit ?? false }

    /// Tekst problemu (odrzucony albo przekroczony limit czasu); `nil` dla wzorca działającego
    /// lub po prostu niepoprawnego składniowo (wtedy `isValid == false`).
    public var problem: String? { issue != nil || exceededTimeLimit ? RegexSafety.message : nil }

    public func matches(_ name: String) -> Bool { box?.matchesAnywhere(name) ?? false }
}
