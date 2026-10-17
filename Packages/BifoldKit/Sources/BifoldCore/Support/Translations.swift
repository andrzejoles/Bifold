import Foundation

/// Języki interfejsu: wbudowane (katalog `Localizable.xcstrings` skompilowany do `<kod>.lproj` w
/// aplikacji) i zaimportowane z pliku JSON (jak w CantatePresenter) — zapisywane jako
/// `<dane>/languages/<kod>.lproj/Localizable.strings`, więc działają bez przebudowy aplikacji.
public final class Translations: Sendable {
    public struct Language: Hashable, Sendable, Identifiable {
        public var id: String { code }
        public var code: String
        public var name: String
        public var flag: String
        public var isCustom: Bool
    }

    public struct Item: Codable, Sendable, Equatable {
        public var key: String
        public var sourceText: String
        public var translation: String
        public var context: String
    }

    /// Plik tłumaczenia (eksport do tłumacza lub AI, import z powrotem).
    public struct Package: Codable, Sendable {
        public var schema: String
        public var sourceLanguage: String
        public var targetLanguageCode: String
        public var targetLanguageName: String
        public var targetLanguageFlag: String
        public var instructionsForAI: String
        public var translations: [Item]
    }

    public struct ImportResult: Sendable, Equatable {
        public var code: String
        public var name: String
        public var imported: Int
        /// Klucze odrzucone, bo znaczniki wartości (%@, %lld) nie zgadzają się z tekstem źródłowym.
        public var rejected: [String]
    }

    public enum TranslationError: Error, LocalizedError, Equatable {
        case invalidFile(String)
        case invalidCode(String)

        public var errorDescription: String? {
            switch self {
            case .invalidFile(let m): L10n.tr("Nieprawidłowy plik tłumaczenia: \(m)")
            case .invalidCode(let c): L10n.tr("Nieprawidłowy kod języka: \(c) (np. fr, pt-BR)")
            }
        }
    }

    public static let schema = "bifold-i18n-v1"
    public static let sourceLanguage = "pl"
    /// Preferencja w UserDefaults: kod języka albo „system”.
    public static let preferenceKey = "BifoldLanguage"

    public static let builtIn: [(code: String, name: String, flag: String)] = [
        ("pl", "Polski", "🇵🇱"), ("en", "English", "🇬🇧"), ("de", "Deutsch", "🇩🇪"),
        ("es", "Español", "🇪🇸"), ("uk", "Українська", "🇺🇦"),
    ]

    let appBundle: Bundle
    public let directory: URL

    public init(appBundle: Bundle, directory: URL) {
        self.appBundle = appBundle
        self.directory = directory
    }

    // MARK: Języki

    public var languages: [Language] {
        var out = Self.builtIn.filter { $0.code == Self.sourceLanguage || appLproj($0.code) != nil }
            .map { Language(code: $0.code, name: $0.name, flag: $0.flag, isCustom: false) }
        for meta in customMetadata() where !out.contains(where: { $0.code == meta.code }) {
            out.append(meta)
        }
        // Zaimportowany język o kodzie wbudowanym (poprawki) oznaczamy jako własny.
        for meta in customMetadata() {
            if let i = out.firstIndex(where: { $0.code == meta.code }) { out[i].isCustom = true }
        }
        return out
    }

    /// „system” → pierwszy język z ustawień macOS, który jest dostępny; inaczej polski.
    public func resolve(_ preference: String?) -> String {
        let available = Set(languages.map(\.code))
        if let preference, preference != "system", available.contains(preference) { return preference }
        for preferred in Locale.preferredLanguages {
            if available.contains(preferred) { return preferred }
            let base = String(preferred.prefix { $0 != "-" && $0 != "_" })
            if available.contains(base) { return base }
        }
        return Self.sourceLanguage
    }

    /// Katalog `.lproj` do `L10n.use`: zaimportowany, wbudowany, a dla polskiego pusty (teksty źródłowe).
    public func bundle(for code: String) -> Bundle? {
        let custom = directory.appending(path: "\(code).lproj", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: custom.appending(path: "Localizable.strings").path) { return Bundle(url: custom) }
        if code == Self.sourceLanguage { return emptyBundle }
        return appLproj(code).flatMap { Bundle(url: $0) }
    }

    /// Bez tłumaczeń — `String(localized:)` zwraca wtedy polski tekst źródłowy, także gdy system jest po angielsku.
    var emptyBundle: Bundle? {
        let dir = directory.appending(path: "pl-source.lproj", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Bundle(url: dir)
    }

    func appLproj(_ code: String) -> URL? {
        guard let url = appBundle.url(forResource: code, withExtension: "lproj"),
              FileManager.default.fileExists(atPath: url.appending(path: "Localizable.strings").path) else { return nil }
        return url
    }

    /// Tłumaczenia języka (klucz → tekst): zaimportowane albo wbudowane.
    public func strings(for code: String) -> [String: String] {
        guard let bundle = bundle(for: code), let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return dict
    }

    /// Wszystkie teksty źródłowe (polskie klucze) — z wbudowanych języków.
    public var sourceKeys: [String] {
        var keys = Set<String>()
        for l in Self.builtIn where l.code != Self.sourceLanguage {
            if let url = appLproj(l.code)?.appending(path: "Localizable.strings"), let dict = NSDictionary(contentsOf: url) as? [String: String] {
                keys.formUnion(dict.keys)
            }
        }
        return keys.sorted()
    }

    // MARK: Eksport i import

    /// Plik do tłumaczenia: wszystkie teksty, kontekst po angielsku, `translation` puste albo z
    /// istniejącym tłumaczeniem języka `prefill` (do poprawek).
    public func exportPackage(prefill code: String? = nil) throws -> Data {
        let english = strings(for: "en")
        let existing = code.map { strings(for: $0) } ?? [:]
        let lang = code.flatMap { c in languages.first { $0.code == c } }
        let items = sourceKeys.map { key in
            Item(key: key, sourceText: key, translation: existing[key] ?? "", context: english[key].map { "English: \($0)" } ?? "")
        }
        let package = Package(
            schema: Self.schema, sourceLanguage: Self.sourceLanguage,
            targetLanguageCode: lang?.code ?? "fr", targetLanguageName: lang?.name ?? "Français", targetLanguageFlag: lang?.flag ?? "🇫🇷",
            instructionsForAI: """
            Przetłumacz pole „translation” każdego elementu z polskiego („sourceText”) na język docelowy \
            (targetLanguageCode/targetLanguageName — ustaw je). „context” zawiera tłumaczenie angielskie jako podpowiedź. \
            To interfejs menedżera plików dla macOS: krótko, spójnie, terminologia jak w Finderze i Total Commanderze. \
            Znaczniki %@, %lld i %% muszą zostać w tłumaczeniu w tej samej liczbie i rodzaju; zmiana kolejności tylko \
            z numerami (%1$@, %2$@). Nie zmieniaj pól „key” ani „sourceText”. Puste „translation” = tekst po polsku.
            """,
            translations: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(package)
    }

    /// Wczytuje plik tłumaczenia i zapisuje język jako `<kod>.lproj`. Język o kodzie wbudowanym
    /// nakłada poprawki na tłumaczenie wbudowane.
    public func importPackage(_ data: Data) throws -> ImportResult {
        let package: Package
        do {
            package = try JSONDecoder().decode(Package.self, from: data)
        } catch {
            throw TranslationError.invalidFile(L10n.tr("oczekiwany format \(Self.schema) (plik z eksportu)"))
        }
        let code = package.targetLanguageCode.trimmingCharacters(in: .whitespaces)
        guard code.range(of: #"^[a-z]{2,3}([_-][A-Za-z0-9]{2,8})?$"#, options: .regularExpression) != nil, code != Self.sourceLanguage else {
            throw TranslationError.invalidCode(code)
        }
        var strings = Self.builtIn.contains { $0.code == code } ? (appLproj(code).flatMap { NSDictionary(contentsOf: $0.appending(path: "Localizable.strings")) as? [String: String] } ?? [:]) : [:]
        var rejected: [String] = []
        var imported = 0
        for item in package.translations {
            let text = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard Self.placeholdersMatch(key: item.key, translation: text) else {
                rejected.append(item.key)
                continue
            }
            strings[item.key] = text
            imported += 1
        }
        guard imported > 0 else { throw TranslationError.invalidFile(L10n.tr("brak przetłumaczonych tekstów")) }
        let dir = directory.appending(path: "\(code).lproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
        try plist.write(to: dir.appending(path: "Localizable.strings"), options: .atomic)
        let name = package.targetLanguageName.trimmingCharacters(in: .whitespaces)
        let meta = ["code": code, "name": name.isEmpty ? code : name, "flag": package.targetLanguageFlag.isEmpty ? "🌐" : package.targetLanguageFlag]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appending(path: "\(code).json"), options: .atomic)
        return ImportResult(code: code, name: meta["name"]!, imported: imported, rejected: rejected)
    }

    /// Usuwa zaimportowany język (wbudowany wraca do wersji z aplikacji).
    public func remove(_ code: String) throws {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(code).lproj"))
        try? FileManager.default.removeItem(at: directory.appending(path: "\(code).json"))
    }

    func customMetadata() -> [Language] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted().compactMap { file in
            guard let data = try? Data(contentsOf: directory.appending(path: file)),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let code = meta["code"], FileManager.default.fileExists(atPath: directory.appending(path: "\(code).lproj").path) else { return nil }
            return Language(code: code, name: meta["name"] ?? code, flag: meta["flag"] ?? "🌐", isCustom: true)
        }
    }

    // MARK: Znaczniki wartości

    /// Rodzaje znaczników formatu w kolejności (`%@`, `%lld`, `%1$@` → indeks i rodzaj). `%%` pomijane.
    static func specifiers(_ s: String) -> [(index: Int?, type: String)] {
        let regex = /%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfFeEgGcCsSpaA%])/
        return s.matches(of: regex).compactMap { m in
            let conversion = String(m.output.3)
            if conversion == "%" { return nil }
            return (m.output.1.flatMap { Int($0) }, String(m.output.2 ?? "") + conversion)
        }
    }

    /// Tłumaczenie musi mieć te same wartości co tekst źródłowy (inaczej `String(format:)` może
    /// pokazać śmieci albo zatrzymać aplikację): bez numerów — ta sama kolejność rodzajów;
    /// z numerami (%2$@) — każdy numer wskazuje wartość tego samego rodzaju i żadnej nie brakuje.
    public static func placeholdersMatch(key: String, translation: String) -> Bool {
        let source = specifiers(key).map(\.type)
        let target = specifiers(translation)
        if target.contains(where: { $0.index != nil }) {
            guard target.allSatisfy({ $0.index != nil }) else { return false }
            var seen = Set<Int>()
            for t in target {
                guard let i = t.index, i >= 1, i <= source.count, source[i - 1] == t.type else { return false }
                seen.insert(i)
            }
            return seen.count == source.count
        }
        return target.map(\.type) == source
    }
}
