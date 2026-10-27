import Foundation
import Testing
@testable import BifoldCore

/// Wyrażenia regularne od użytkownika i agenta nie mogą zawiesić podglądu ani wyszukiwania
/// (katastrofalne nawracanie ICU).
@Suite struct RegexSafetyTests {
    static func item(_ name: String) -> FileItem {
        FileItem(path: .local("/nieistniejacy-katalog-bifold/\(name)"), kind: .file, size: 1, modified: Date(timeIntervalSince1970: 0))
    }

    /// Wykonuje `body` na osobnym wątku; `nil`, jeśli nie skończy się w `limit` sekund (test nie wisi).
    static func within<T: Sendable>(_ limit: Double, _ body: @escaping @Sendable () -> T) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Thread.detachNewThread { box.value = body(); done.signal() }
        return done.wait(timeout: .now() + limit) == .success ? box.value : nil
    }

    @Test func catastrophicPatternsInMultiRenameReturnProblemQuickly() throws {
        let long = String(repeating: "a", count: 200)
        let items = (0..<20).map { Self.item("\(long)\($0).txt") }
        for pattern in ["(.*)*\\x{0}", "(a*)*b", ".*.*.*.*.*.*.*.*.*.*.*.*\\x{0}"] {
            let rule = RenameRule(search: pattern, replace: "x", regex: true)
            let start = Date()
            let plan = try #require(Self.within(10) { MultiRename.plan(items, rule: rule) }, "\(pattern): plan zawisł")
            #expect(Date().timeIntervalSince(start) < 2, "\(pattern)")
            #expect(plan.allSatisfy { $0.problem == RegexSafety.message }, "\(pattern): \(plan.map(\.problem))")
        }
    }

    /// Wzorzec bez widocznego ryzyka, ale wolny (nawracanie wielomianowe) — łapie go limit czasu.
    @Test func timeLimitCatchesSlowPatternWithoutVisibleNesting() throws {
        let pattern = ".*.*.*.*.*.*.*.*.*.*.*.*\\x{0}"
        #expect(RegexSafety.issue(in: pattern) == nil)
        let regex = NameRegex(pattern)
        #expect(regex.isValid)
        let name = String(repeating: "a", count: 200)
        let start = Date()
        let matched = try #require(Self.within(10) { regex.matches(name) })
        #expect(!matched)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(regex.exceededTimeLimit)
        #expect(regex.problem == RegexSafety.message)
        // Po przekroczeniu limitu wzorzec nie pasuje już do niczego — bez kolejnych prób.
        #expect(!regex.matches("a\u{0}"))
    }

    @Test func ordinaryPatternsStillWork() {
        let rule = RenameRule(nameMask: "[N]", search: "^(\\d+)_(.*)$", replace: "$2-$1", regex: true)
        #expect(MultiRename.newName(for: Self.item("0042_wakacje.jpg"), index: 0, rule: rule) == "wakacje.jpg-0042")
        let letters = RenameRule(search: "[a-z]+", replace: "X", regex: true, caseSensitive: true)
        let plan = MultiRename.plan([Self.item("abc123def.TXT")], rule: letters)
        #expect(plan.first?.newName == "X123X.TXT")
        #expect(plan.first?.problem == nil)
        // Wynik jak w `stringByReplacingMatches` (także puste dopasowania i grupy).
        for (pattern, template, text) in [("x*", "-", "abc"), ("(a)(b)?", "[$1$2]", "aab ab"), ("ą", "a", "Łąka ąą"), ("$", "!", "koniec")] {
            let re = try! NSRegularExpression(pattern: pattern)
            let expected = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
            #expect(re.replacingMatches(in: text, template: template, limit: .seconds(1)) == expected, "\(pattern)")
        }
        #expect(NameRegex("^IMG_\\d{4}").matches("img_1234.jpg"))
    }

    @Test func riskyPatternsAreRejected() {
        for pattern in ["(a*)*b", "(a+)+", "(x|x)*", "(.|a)+", "((a)\\2)*", "(?:a?){5}", "(\\w+\\s?)*", "(.*)*\\x{0}",
                        "(?<n>a|a)+", "((a+))*", "(a{1,3})+", "(?i:(?:ab|ac)+)", "(\\Qab\\E|a)*", "(a*)*+", "(a*){2,}"] {
            #expect(RegexSafety.issue(in: pattern) == .tooComplex, "\(pattern)")
            let regex = NameRegex(pattern)
            #expect(!regex.isValid, "\(pattern)")
            #expect(regex.problem == RegexSafety.message)
        }
        for pattern in ["^(\\d+)_(.*)$", "[a-z]+", "(ab){3}", "(a|b)*", "[(*)]+", "\\(a*\\)*", "(\\d{4})-(\\d{2})", "(?i)foo",
                        "\\Q(a*)*\\E", "(a{3})+", "^IMG_\\d{4}", "(\\.jpg|\\.png)$", "\\x{41}{2}(b)", "[[a-z]&&[^q]]+(x)*", "(?#(a*)*)a"] {
            #expect(RegexSafety.issue(in: pattern) == nil, "\(pattern)")
        }
        let tooLong = String(repeating: "a", count: RegexSafety.maxPatternLength + 1)
        #expect(RegexSafety.issue(in: tooLong) == .tooLong)
        #expect(RegexSafety.issue(in: String(tooLong.dropFirst())) == nil)
        #expect(!NameRegex(tooLong).isValid)
        // Wzorzec odrzucony przez podgląd: problem w każdej pozycji, nazwa bez zmian.
        let plan = MultiRename.plan([Self.item("plik.txt")], rule: RenameRule(search: tooLong, replace: "", regex: true))
        #expect(plan.first?.problem == RegexSafety.message)
    }

    /// Maska glob zamieniana na wyrażenie (`*a*a*…`) też ma limit czasu.
    @Test func globMaskHasTimeLimit() throws {
        let mask = NameMask("*a*a*a*a*a*a*a*a*a*a*a*b")
        let name = String(repeating: "a", count: 200)
        let start = Date()
        let matched = try #require(Self.within(10) { mask.matches(name) })
        #expect(!matched)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(NameMask("*.jpg").matches("x.JPG"))
    }
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
