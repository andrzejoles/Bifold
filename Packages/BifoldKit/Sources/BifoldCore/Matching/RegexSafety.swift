import Foundation

/// Ochrona przed katastrofalnym nawracaniem wyrażeń regularnych (ICU w `NSRegularExpression`
/// nawraca wykładniczo: `(a*)*b` albo `(.*)*\x{0}` na nazwie 45 znaków liczy się minutami).
/// Wzorce bywają od agenta i są liczone przed oknem zgody (podgląd `file.multiRename`), więc:
///
/// 1. **Odrzucenie z góry** (`issue(in:)`): wzorzec dłuższy niż `maxPatternLength` albo z oczywistym
///    ryzykiem — powtarzana grupa z kwantyfikatorem zmiennej długości w środku (`(x*)*`, `(x+)+`,
///    `(x?){9}`), z odwołaniem wstecznym (`((a)\2)*`) albo z alternatywami zaczynającymi się tak samo
///    (`(x|x)*`, `(.|a)+`).
/// 2. **Limit czasu** każdego dopasowania: `enumerateMatches` z `.reportProgress` — ICU co kilkaset
///    kroków wywołuje blok, a `stop` przerywa dopasowanie od razu (bez osobnego wątku, więc nie zostaje
///    porzucony wątek ICU, który liczyłby dalej). Czas to czas procesora bieżącego wątku, więc
///    obciążenie maszyny nie skraca limitu zwykłym wzorcom. Łapie też to, czego nie widać w składni
///    (`.*.*.*.*.*.*x` — nawracanie wielomianowe).
public enum RegexSafety {
    /// Najdłuższy przyjmowany wzorzec (znaki Unicode).
    public static let maxPatternLength = 512

    public enum Issue: Error, Sendable, Hashable {
        /// Wzorzec dłuższy niż `maxPatternLength`.
        case tooLong
        /// Wzorzec grozi katastrofalnym nawracaniem (albo przekroczył limit czasu).
        case tooComplex
    }

    /// Tekst problemu dla podglądu i błędów.
    public static var message: String { L10n.tr("wyrażenie regularne zbyt złożone") }

    /// Ryzyko widoczne w samym wzorcu (bez kompilowania); `nil` — wzorzec przyjęty.
    public static func issue(in pattern: String) -> Issue? {
        if pattern.unicodeScalars.count > maxPatternLength { return .tooLong }
        return PatternScanner(pattern).isRisky ? .tooComplex : nil
    }
}

/// Czas procesora bieżącego wątku (wywłaszczenie i obciążenie maszyny się nie liczą).
struct ThreadCPUClock {
    static func now() -> Duration {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return .seconds(ts.tv_sec) + .nanoseconds(ts.tv_nsec)
    }
}

extension NSRegularExpression {
    /// Dopasowania w `text` liczone najwyżej `limit` czasu procesora; `nil` — przekroczono limit
    /// (dopasowanie przerwane, nie liczy się dalej w tle). `first` — tylko pierwsze dopasowanie.
    func matches(in text: String, limit: Duration, first: Bool = false) -> [NSTextCheckingResult]? {
        let deadline = ThreadCPUClock.now() + limit
        var found: [NSTextCheckingResult] = []
        var exceeded = false
        enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
            if let result {
                found.append(result)
                if first { stop.pointee = true; return }
            }
            if ThreadCPUClock.now() >= deadline {
                exceeded = true
                stop.pointee = true
            }
        }
        return exceeded ? nil : found
    }

    /// Jak `stringByReplacingMatches(in:range:withTemplate:)`, ale z limitem czasu; `nil` — przekroczono.
    func replacingMatches(in text: String, template: String, limit: Duration) -> String? {
        guard let found = matches(in: text, limit: limit) else { return nil }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in found {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replacementString(for: m, in: text, offset: 0, template: template)
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }
}

/// Uproszczony przegląd składni ICU: grupy, klasy znaków, ucieczki, `\Q…\E`, kwantyfikatory.
/// Wystarcza do wykrycia zagnieżdżonych kwantyfikatorów; resztę łapie limit czasu.
private struct PatternScanner {
    struct Frame {
        /// W grupie (także głębiej) jest kwantyfikator zmiennej długości.
        var variable = false
        var backreference = false
        /// Pierwszy element każdej alternatywy (`nil` — alternatywa pusta).
        var firstAtoms: [String?] = []
        var currentFirst: String?
        var currentEmpty = true

        mutating func atom(_ text: String) {
            if currentEmpty { currentFirst = text; currentEmpty = false }
        }

        /// Alternatywy zaczynające się tak samo albo od kropki (pasuje do wszystkiego).
        var overlappingAlternatives: Bool {
            let atoms = (firstAtoms + [currentEmpty ? nil : currentFirst]).compactMap { $0 }
            guard firstAtoms.count >= 1 else { return false }
            return Set(atoms).count < atoms.count || atoms.contains(".")
        }
    }

    struct Quantifier {
        var variable: Bool
        var repeats: Bool
    }

    let scalars: [Unicode.Scalar]
    private(set) var isRisky = false

    init(_ pattern: String) {
        scalars = Array(pattern.unicodeScalars)
        isRisky = scan()
    }

    private func scan() -> Bool {
        var stack: [Frame] = [Frame()]
        var i = 0
        var groupCounter = 0
        func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < scalars.count ? scalars[i + k] : nil }

        while i < scalars.count {
            let c = scalars[i]
            var closed: Frame?
            var atomText: String
            switch c {
            case "\\":
                guard let next = peek(1) else { return false }
                if next == "Q" {
                    // Dosłowny tekst do `\E`; kwantyfikator dotyczy tylko ostatniego znaku.
                    i += 2
                    var any = false
                    while i < scalars.count, !(scalars[i] == "\\" && peek(1) == "E") {
                        if !any { stack[stack.count - 1].atom(String(scalars[i])) }
                        any = true
                        i += 1
                    }
                    i = min(i + 2, scalars.count)
                    if any, let q = quantifier(at: &i), q.variable { stack[stack.count - 1].variable = true }
                    continue
                }
                if next == "E" { i += 2; continue }
                atomText = "\\" + String(next)
                i += 2
                if ("1"..."9").contains(next) || (next == "k" && peek() == "<") {
                    stack[stack.count - 1].backreference = true
                }
                if ["x", "N", "p", "P", "k"].contains(next), let open = peek(), open == "{" || open == "<" {
                    let close: Unicode.Scalar = open == "{" ? "}" : ">"
                    while i < scalars.count, scalars[i] != close { i += 1 }
                    i = min(i + 1, scalars.count)
                }
            case "[":
                let start = i
                var depth = 0
                repeat {
                    let s = scalars[i]
                    if s == "\\" { i += 2; continue }
                    if s == "[" {
                        depth += 1
                        i += 1
                        // `]` tuż po `[` albo `[^` jest zwykłym znakiem.
                        if peek() == "^" { i += 1 }
                        if peek() == "]" { i += 1 }
                        continue
                    }
                    if s == "]" { depth -= 1 }
                    i += 1
                } while i < scalars.count && depth > 0
                atomText = String(String.UnicodeScalarView(scalars[start..<min(i, scalars.count)]))
            case "(":
                i += 1
                if peek() == "?" {
                    i += 1
                    if peek() == "#" {
                        while i < scalars.count, scalars[i] != ")" { i += 1 }
                        i += 1
                        continue
                    }
                    if peek() == "<", let n = peek(1), n == "=" || n == "!" {
                        i += 2
                    } else if peek() == "<" {
                        while i < scalars.count, scalars[i] != ">" { i += 1 }
                        i += 1
                    } else if let n = peek(), "=!>:".unicodeScalars.contains(n) {
                        i += 1
                    } else {
                        while let n = peek(), n.properties.isAlphabetic || n == "-" { i += 1 }
                        if peek() == ":" { i += 1 }
                    }
                }
                stack.append(Frame())
                continue
            case ")":
                i += 1
                guard stack.count > 1 else { continue }
                closed = stack.removeLast()
                groupCounter += 1
                atomText = "(\(groupCounter)"
            case "|":
                i += 1
                var top = stack[stack.count - 1]
                top.firstAtoms.append(top.currentEmpty ? nil : top.currentFirst)
                top.currentFirst = nil
                top.currentEmpty = true
                stack[stack.count - 1] = top
                continue
            default:
                atomText = String(c)
                i += 1
            }
            stack[stack.count - 1].atom(atomText)
            let q = quantifier(at: &i)
            if let closed {
                if let q, q.repeats, closed.variable || closed.backreference || closed.overlappingAlternatives { return true }
                stack[stack.count - 1].variable = stack[stack.count - 1].variable || closed.variable || (q?.variable ?? false)
                stack[stack.count - 1].backreference = stack[stack.count - 1].backreference || closed.backreference
            } else if let q {
                stack[stack.count - 1].variable = stack[stack.count - 1].variable || q.variable
            }
        }
        return false
    }

    /// Kwantyfikator na pozycji `i` (wraz z `?`/`+` leniwym/zaborczym); przesuwa `i` za niego.
    private func quantifier(at i: inout Int) -> Quantifier? {
        guard i < scalars.count else { return nil }
        var q: Quantifier
        switch scalars[i] {
        case "*", "+":
            q = Quantifier(variable: true, repeats: true)
            i += 1
        case "?":
            q = Quantifier(variable: true, repeats: false)
            i += 1
        case "{":
            var j = i + 1
            var text = ""
            while j < scalars.count, scalars[j] != "}" { text.unicodeScalars.append(scalars[j]); j += 1 }
            guard j < scalars.count else { return nil }
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let low = parts.first ?? nil, parts.count <= 2 else { return nil }
            if parts.count == 1 {
                q = Quantifier(variable: false, repeats: low > 1)
            } else if let high = parts[1] {
                q = Quantifier(variable: high != low, repeats: high > 1)
            } else {
                q = Quantifier(variable: true, repeats: true)
            }
            i = j + 1
        default:
            return nil
        }
        if i < scalars.count, scalars[i] == "?" || scalars[i] == "+" { i += 1 }
        return q
    }
}
