import AudioToolbox
import Foundation
import ImageIO

public enum CaseMode: String, Codable, Sendable, CaseIterable {
    case unchanged, lower, upper, title, firstUpper

    public var displayName: String {
        switch self {
        case .unchanged: L10n.tr("bez zmian")
        case .lower: L10n.tr("małe litery")
        case .upper: L10n.tr("WIELKIE LITERY")
        case .title: L10n.tr("Każde Słowo Wielką")
        case .firstUpper: L10n.tr("Pierwsza wielka")
        }
    }

    func apply(_ s: String) -> String {
        switch self {
        case .unchanged: s
        case .lower: s.lowercased()
        case .upper: s.uppercased()
        case .title: s.capitalized
        case .firstUpper: s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }
    }
}

/// Reguła zmiany nazw wielu plików (Ctrl+M), w składni masek Total Commandera:
/// `[N]` nazwa, `[E]` rozszerzenie, `[N2-5]` / `[N2,3]` / `[N-3-]` fragmenty, `[C]` licznik
/// (`[C:3]` — cyfry), `[P]` / `[G]` katalog nadrzędny / dziadek, `[Y] [M] [D] [h] [m] [s]` data
/// modyfikacji, `[Exif:Pole]` / `[Exif:DateTimeOriginal:yyyy-MM-dd]` metadane zdjęć,
/// `[Media:title|artist|album|year]` tagi multimediów. Potem „znajdź i zamień” i wielkość liter.
public struct RenameRule: Codable, Sendable, Hashable {
    public var nameMask: String
    public var extensionMask: String
    public var search: String
    public var replace: String
    public var regex: Bool
    public var caseSensitive: Bool
    public var nameCase: CaseMode
    public var extensionCase: CaseMode
    public var counterStart: Int
    public var counterStep: Int
    public var counterDigits: Int

    public init(
        nameMask: String = "[N]", extensionMask: String = "[E]", search: String = "", replace: String = "",
        regex: Bool = false, caseSensitive: Bool = false, nameCase: CaseMode = .unchanged, extensionCase: CaseMode = .unchanged,
        counterStart: Int = 1, counterStep: Int = 1, counterDigits: Int = 1
    ) {
        self.nameMask = nameMask
        self.extensionMask = extensionMask
        self.search = search
        self.replace = replace
        self.regex = regex
        self.caseSensitive = caseSensitive
        self.nameCase = nameCase
        self.extensionCase = extensionCase
        self.counterStart = counterStart
        self.counterStep = counterStep
        self.counterDigits = counterDigits
    }
}

public struct RenamePlanEntry: Sendable, Hashable, Identifiable {
    public var id: VFSPath { source }
    public var source: VFSPath
    public var newName: String
    public var problem: String?

    public var changes: Bool { newName != source.name }
}

/// Odczyt metadanych do nazw (EXIF przez ImageIO, tagi multimediów przez AVFoundation).
public enum FileMetadata {
    public static func exif(_ key: String, of path: VFSPath) -> Any? {
        guard let url = path.url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        switch key.lowercased() {
        case "width", "pixelwidth": return props[kCGImagePropertyPixelWidth as String]
        case "height", "pixelheight": return props[kCGImagePropertyPixelHeight as String]
        case "make": return tiff[kCGImagePropertyTIFFMake as String]
        case "model": return tiff[kCGImagePropertyTIFFModel as String]
        default:
            return exif.first { $0.key.lowercased() == key.lowercased() }?.value
                ?? tiff.first { $0.key.lowercased() == key.lowercased() }?.value
                ?? props.first { $0.key.lowercased() == key.lowercased() }?.value
        }
    }

    /// Data EXIF „yyyy:MM:dd HH:mm:ss”.
    static func exifDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    /// Tagi multimediów (`title`, `artist`, `album`, `year`, `genre`) synchronicznie przez AudioToolbox
    /// (MP3/ID3, AAC/M4A, MP4 ze ścieżką dźwiękową, AIFF…) — bez czekania na zadanie w puli wątków.
    /// `nil`, jeśli pliku nie da się odczytać jako multimediów; pusty tekst, jeśli plik nie ma takiego tagu.
    public static func media(_ key: String, of path: VFSPath) -> String? {
        guard let url = path.url else { return nil }
        let info: [String: Any]
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var dict: Unmanaged<CFDictionary>?
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
              let value = dict?.takeRetainedValue() as? [String: Any] else { return nil }
        info = value
        let wanted: String? = switch key.lowercased() {
        case "title": kAFInfoDictionary_Title
        case "artist": kAFInfoDictionary_Artist
        case "album": kAFInfoDictionary_Album
        case "year", "date": kAFInfoDictionary_Year
        case "genre": kAFInfoDictionary_Genre
        default: nil
        }
        guard let wanted else { return nil }
        guard var value = (info[wanted] as? String) ?? (info[wanted] as? NSNumber)?.stringValue else { return "" }
        if key.lowercased() == "year" { value = String(value.prefix(4)) }
        return value
    }
}

public enum MultiRename {
    /// Łączny czas procesora na dopasowania wyrażenia regularnego w jednym planie. Zwykły wzorzec
    /// na tysiącach nazw zużywa milisekundy; po wyczerpaniu pozostałe pozycje dostają problem.
    static let regexBudget: Duration = .seconds(1)

    /// Nowa nazwa dla elementu (bez sprawdzania konfliktów).
    public static func newName(for item: FileItem, index: Int, rule: RenameRule) -> String {
        var problem: String?
        var budget = regexBudget
        return newName(for: item, index: index, rule: rule, problem: &problem, regexBudget: &budget)
    }

    /// Nowa nazwa i problem z jej wyliczeniem (np. nieczytelne metadane multimediów, zbyt złożone
    /// wyrażenie regularne). `regexBudget` — pozostały czas na dopasowania wyrażenia w całym planie.
    static func newName(for item: FileItem, index: Int, rule: RenameRule, problem: inout String?, regexBudget: inout Duration) -> String {
        let isDir = item.isNavigable
        let stem = isDir ? item.name : item.name.fileStem
        let ext = isDir ? "" : item.name.fileExtension
        // Start i krok bywają podane przez agenta — przepełnienie to problem w podglądzie, nie pułapka.
        let (offset, o1) = index.multipliedReportingOverflow(by: rule.counterStep)
        let (sum, o2) = rule.counterStart.addingReportingOverflow(offset)
        let counter = o1 || o2 ? 0 : sum
        if o1 || o2, mentionsCounter(rule) { problem = problem ?? L10n.tr("licznik poza zakresem") }

        var name = expand(rule.nameMask, item: item, stem: stem, ext: ext, counter: counter, digits: rule.counterDigits, problem: &problem)
        var newExt = isDir ? "" : expand(rule.extensionMask, item: item, stem: stem, ext: ext, counter: counter, digits: rule.counterDigits, problem: &problem)
        name = rule.nameCase.apply(name)
        newExt = rule.extensionCase.apply(newExt)
        var full = newExt.isEmpty ? name : name + "." + newExt
        if !rule.search.isEmpty {
            if rule.regex {
                // Wzorzec od agenta liczy się przed oknem zgody: ryzykowny jest odrzucany z góry,
                // a każde dopasowanie ma limit czasu (RegexSafety) — podgląd nie może zawisnąć.
                if RegexSafety.issue(in: rule.search) != nil || regexBudget <= .zero {
                    problem = problem ?? RegexSafety.message
                } else if let re = try? NSRegularExpression(pattern: rule.search, options: rule.caseSensitive ? [] : [.caseInsensitive]) {
                    let start = ThreadCPUClock.now()
                    let replaced = re.replacingMatches(in: full, template: rule.replace, limit: regexBudget)
                    regexBudget -= ThreadCPUClock.now() - start
                    if let replaced { full = replaced } else {
                        regexBudget = .zero
                        problem = problem ?? RegexSafety.message
                    }
                }
            } else {
                full = full.replacingOccurrences(of: rule.search, with: rule.replace, options: rule.caseSensitive ? [] : [.caseInsensitive])
            }
        }
        return full
    }

    static func expand(_ mask: String, item: FileItem, stem: String, ext: String, counter: Int, digits: Int) -> String {
        var problem: String?
        return expand(mask, item: item, stem: stem, ext: ext, counter: counter, digits: digits, problem: &problem)
    }

    static func expand(_ mask: String, item: FileItem, stem: String, ext: String, counter: Int, digits: Int, problem: inout String?) -> String {
        var out = ""
        var i = mask.startIndex
        while i < mask.endIndex {
            let ch = mask[i]
            guard ch == "[", let close = mask[i...].firstIndex(of: "]") else {
                out.append(ch)
                i = mask.index(after: i)
                continue
            }
            let token = String(mask[mask.index(after: i)..<close])
            out += value(of: token, item: item, stem: stem, ext: ext, counter: counter, digits: digits, problem: &problem) ?? "[\(token)]"
            i = mask.index(after: close)
        }
        return out
    }

    static func value(of token: String, item: FileItem, stem: String, ext: String, counter: Int, digits: Int, problem: inout String?) -> String? {
        let date = item.modified ?? Date()
        let cal = Calendar.current
        func two(_ n: Int) -> String { String(format: "%02d", n) }
        switch token {
        case "N": return stem
        case "E": return ext
        case "P": return item.path.parent?.name ?? ""
        case "G": return item.path.parent?.parent?.name ?? ""
        case "Y": return String(cal.component(.year, from: date))
        case "M": return two(cal.component(.month, from: date))
        case "D": return two(cal.component(.day, from: date))
        case "h": return two(cal.component(.hour, from: date))
        case "m": return two(cal.component(.minute, from: date))
        case "s": return two(cal.component(.second, from: date))
        case "C": return counterText(counter, width: digits, problem: &problem)
        default: break
        }
        if token.hasPrefix("C:"), let d = Int(token.dropFirst(2)) { return counterText(counter, width: d, problem: &problem) }
        if token.lowercased().hasPrefix("exif:") {
            let parts = token.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let raw = FileMetadata.exif(parts[1], of: item.path)
            if parts.count == 3, let d = FileMetadata.exifDate(raw) {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = parts[2]
                return f.string(from: d)
            }
            return raw.map { sanitize("\($0)") } ?? ""
        }
        if token.lowercased().hasPrefix("media:") {
            guard let value = FileMetadata.media(String(token.dropFirst(6)), of: item.path) else {
                problem = problem ?? L10n.tr("nie można odczytać metadanych multimediów")
                return ""
            }
            return sanitize(value)
        }
        if token.hasPrefix("N") || token.hasPrefix("E") {
            let source = token.hasPrefix("N") ? stem : ext
            return substring(source, spec: String(token.dropFirst()))
        }
        return nil
    }

    /// Najszersze pole licznika: Int64 ma 19 cyfr (+ znak). Szersze `[C:300000000]` alokowało setki MB na element.
    static let maxCounterWidth = 20

    static func counterText(_ counter: Int, width: Int, problem: inout String?) -> String {
        if width > maxCounterWidth { problem = problem ?? L10n.tr("szerokość licznika poza zakresem 1–20") }
        return String(format: "%0\(min(max(1, width), maxCounterWidth))ld", counter)
    }

    /// Czy maska używa licznika (przepełnienie licznika nieużywanego nie jest problemem).
    static func mentionsCounter(_ rule: RenameRule) -> Bool {
        (rule.nameMask + rule.extensionMask).contains("[C")
    }

    /// Fragmenty jak w TC: `2-5`, `2,3` (od 2, 3 znaki), `3` (jeden znak), `3-` (od 3 do końca),
    /// `-3-` (trzy ostatnie), `-5,2` (od piątego od końca, 2 znaki).
    static func substring(_ s: String, spec: String) -> String? {
        let chars = Array(s)
        let n = chars.count
        // Pozycje zaciśnięte do ±(n+1), długości do 0…2(n+1) — wynik ten sam, a liczby bliskie
        // Int.min/Int.max (np. od agenta, liczone przed oknem zgody) nie przepełniają działań.
        func position(_ raw: Substring) -> Int? {
            guard let v = Int(raw) else { return nil }
            return min(max(v < 0 ? n + v + 1 : v, -(n + 1)), n + 1)
        }
        func slice(_ from: Int, _ to: Int) -> String {
            let a = max(1, from), b = min(n, to)
            return a <= b ? String(chars[(a - 1)..<b]) : ""
        }
        if spec.hasPrefix("-"), spec.hasSuffix("-") {
            guard let k = Int(spec.dropFirst().dropLast()) else { return nil }
            return slice(n - min(max(k, 0), n) + 1, n)
        }
        if let comma = spec.firstIndex(of: ",") {
            guard let a = position(spec[..<comma]), let len = Int(spec[spec.index(after: comma)...]) else { return nil }
            return slice(a, a + min(max(len, 0), 2 * (n + 1)) - 1)
        }
        if spec.hasSuffix("-") {
            guard let a = position(spec.dropLast()) else { return nil }
            return slice(a, n)
        }
        let body = spec.hasPrefix("-") ? spec.dropFirst() : Substring(spec)
        if let dash = body.firstIndex(of: "-") {
            let startRaw = spec.hasPrefix("-") ? "-" + body[..<dash] : String(body[..<dash])
            guard let a = position(Substring(startRaw)), let b = position(body[body.index(after: dash)...]) else { return nil }
            return slice(a, b)
        }
        guard let a = position(Substring(spec)) else { return nil }
        return slice(a, a)
    }

    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Podgląd: nowe nazwy i problemy (niepoprawna nazwa, powtórzona nowa nazwa, zajęte miejsce).
    public static func plan(_ items: [FileItem], rule: RenameRule) -> [RenamePlanEntry] {
        var budget = regexBudget
        var entries = items.enumerated().map { i, item in
            var problem: String?
            let name = newName(for: item, index: i, rule: rule, problem: &problem, regexBudget: &budget)
            return RenamePlanEntry(source: item.path, newName: name, problem: problem)
        }
        let sources = Set(items.map { $0.path.path.lowercased() })
        var seen: [String: Int] = [:]
        for i in entries.indices where entries[i].problem == nil {
            let e = entries[i]
            do { try validateFileName(e.newName) } catch {
                entries[i].problem = L10n.tr("nieprawidłowa nazwa")
                continue
            }
            guard let parent = e.source.parent else { continue }
            let target = parent.appending(e.newName)
            let key = target.path.lowercased()
            if let other = seen[key] {
                entries[i].problem = L10n.tr("taka sama nazwa jak dla „\(entries[other].source.name)”")
                continue
            }
            seen[key] = i
            if e.changes, target.path.lowercased() != e.source.path.lowercased(), !sources.contains(key),
               FileManager.default.fileExists(atPath: target.path) {
                entries[i].problem = L10n.tr("element o tej nazwie już istnieje")
            }
        }
        return entries
    }

    /// Wykonuje plan (pomija pozycje z problemem). Zamiany nazw w obrębie zbioru (a↔b) idą przez
    /// nazwy tymczasowe; każdy rzeczywisty krok trafia do dziennika, więc cofanie jest dokładne.
    @discardableResult
    public static func execute(_ plan: [RenamePlanEntry], journal: OperationJournal?, invoker: Invoker, title: String) throws -> Int {
        let fs = LocalFS()
        let work = plan.filter { $0.changes && $0.problem == nil }
        guard !work.isEmpty else { return 0 }
        // Partia zapisywana stopniowo: do końca nie da się jej cofnąć (Cmd+Z w trakcie cofnąłby część).
        let batch = journal?.beginBatch(title: title, invoker: invoker, finished: false)
        defer { if let journal, let batch { journal.endBatch(batch) } }
        func record(_ from: VFSPath, _ to: VFSPath) {
            if let journal, let batch { journal.record(.moved(from: from, to: to), fingerprint: try? fs.itemSync(at: to).fingerprint, in: batch) }
        }
        // Element pod nazwą tymczasową (jeszcze bez nazwy docelowej).
        var current: [VFSPath: VFSPath] = [:]
        func lowered(_ e: RenamePlanEntry) -> String { e.source.parent!.appending(e.newName).path.lowercased() }
        let targetsLower = Set(work.map(lowered))
        var done = 0
        do {
            // Faza 1: każdy element, którego obecne miejsce jest celem innego elementu (zamiana a↔b,
            // łańcuch 1→2, 2→3…), na nazwę tymczasową — wtedy w fazie 2 każdy cel jest już wolny.
            for e in work where targetsLower.contains(e.source.path.lowercased()) && lowered(e) != e.source.path.lowercased() {
                let temp = e.source.parent!.appending(".bifold-rename-\(UUID().uuidString.prefix(8))")
                try fs.moveSync(e.source, to: temp)
                record(e.source, temp)
                current[e.source] = temp
            }
        } catch {
            for (source, temp) in current where (try? fs.moveSync(temp, to: source)) != nil { record(temp, source) }
            throw error
        }
        // Faza 2: nazwy docelowe. Błąd jednego elementu nie zatrzymuje pozostałych.
        var firstError: (any Error)?
        for e in work {
            let from = current[e.source] ?? e.source
            let target = e.source.parent!.appending(e.newName)
            do {
                try fs.moveSync(from, to: target)
                record(from, target)
                current[e.source] = nil
                done += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        // Nieudane elementy nie mogą zostać pod ukrytą nazwą tymczasową: wracają na swoje miejsce
        // albo (gdy zajęte) obok, jako „nazwa (2)”.
        for (source, temp) in current {
            let back = TransferEngine.uniqueOrSame(source)
            if (try? fs.moveSync(temp, to: back)) != nil { record(temp, back) }
        }
        if let firstError { throw firstError }
        return done
    }
}
