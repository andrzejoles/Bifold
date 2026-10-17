import Foundation
import Testing
@testable import BifoldCore

@Suite(.serialized) struct TranslationsTests {
    /// Udawany pakiet aplikacji z wbudowanym angielskim.
    func makeApp(_ tmp: TempDir) throws -> Translations {
        let en = tmp.url.appending(path: "App/en.lproj")
        try FileManager.default.createDirectory(at: en, withIntermediateDirectories: true)
        let strings = ["Kopiuj": "Copy", "Kopiowanie %@ → %@": "Copying %1$@ to %2$@", "Usunięto: %lld": "Deleted: %lld"]
        try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0).write(to: en.appending(path: "Localizable.strings"))
        return Translations(appBundle: Bundle(url: tmp.url.appending(path: "App"))!, directory: tmp.url.appending(path: "languages"))
    }

    @Test func placeholders() {
        #expect(Translations.placeholdersMatch(key: "Kopiowanie %@ → %@", translation: "Copying %@ to %@"))
        #expect(Translations.placeholdersMatch(key: "Kopiowanie %@ → %@", translation: "Nach %2$@: %1$@"))
        #expect(Translations.placeholdersMatch(key: "Usunięto: %lld", translation: "Deleted: %lld (100%%)"))
        #expect(!Translations.placeholdersMatch(key: "Usunięto: %lld", translation: "Deleted: %@"))
        #expect(!Translations.placeholdersMatch(key: "%@ ma %lld", translation: "%lld w %@"))
        #expect(!Translations.placeholdersMatch(key: "Kopiowanie %@ → %@", translation: "Copying %1$@"))
        #expect(!Translations.placeholdersMatch(key: "Kopiuj", translation: "Copy %@"))
        #expect(!Translations.placeholdersMatch(key: "%@ i %@", translation: "%1$@ and %@"))
    }

    @Test func builtInLanguageAndSystemPreference() throws {
        let tmp = try TempDir()
        let t = try makeApp(tmp)
        #expect(t.languages.map(\.code) == ["pl", "en"])
        #expect(t.resolve("en") == "en" && t.resolve("de") != "de")
        let name = "plik.txt", dir = "/tmp", n = 3
        let en = try #require(t.bundle(for: "en"))
        #expect(String(localized: "Kopiowanie \(name) → \(dir)", bundle: en) == "Copying plik.txt to /tmp")
        // Polski wybrany jawnie = teksty źródłowe, niezależnie od języka systemu.
        let pl = try #require(t.bundle(for: "pl"))
        #expect(String(localized: "Usunięto: \(n)", bundle: pl) == "Usunięto: 3")
    }

    @Test func exportImportRoundTrip() throws {
        let tmp = try TempDir()
        let t = try makeApp(tmp)
        let template = try JSONDecoder().decode(Translations.Package.self, from: try t.exportPackage())
        #expect(template.schema == Translations.schema && template.translations.count == 3)
        #expect(template.translations.allSatisfy { $0.translation.isEmpty && $0.context.hasPrefix("English: ") })
        #expect(template.instructionsForAI.contains("%@"))

        var fr = template
        fr.targetLanguageCode = "fr"
        fr.targetLanguageName = "Français"
        for i in fr.translations.indices {
            fr.translations[i].translation = switch fr.translations[i].key {
            case "Kopiuj": "Copier"
            case "Kopiowanie %@ → %@": "Copie de %1$@ vers %2$@"
            default: "Supprimés : %@"   // zły znacznik — odrzucony
            }
        }
        let result = try t.importPackage(try JSONEncoder().encode(fr))
        #expect(result == Translations.ImportResult(code: "fr", name: "Français", imported: 2, rejected: ["Usunięto: %lld"]))
        #expect(t.languages.contains { $0.code == "fr" && $0.isCustom && $0.name == "Français" })
        let b = try #require(t.bundle(for: "fr"))
        let a = "x", d = "y", n = 2
        #expect(String(localized: "Kopiowanie \(a) → \(d)", bundle: b) == "Copie de x vers y")
        #expect(String(localized: "Usunięto: \(n)", bundle: b) == "Usunięto: 2")

        // Eksport z wypełnionym językiem (do poprawek) i usunięcie.
        let again = try JSONDecoder().decode(Translations.Package.self, from: try t.exportPackage(prefill: "fr"))
        #expect(again.targetLanguageCode == "fr" && again.translations.first { $0.key == "Kopiuj" }?.translation == "Copier")
        try t.remove("fr")
        #expect(!t.languages.contains { $0.code == "fr" })
    }

    @Test func correctionsOverlayBuiltInLanguage() throws {
        let tmp = try TempDir()
        let t = try makeApp(tmp)
        var en = try JSONDecoder().decode(Translations.Package.self, from: try t.exportPackage(prefill: "en"))
        for i in en.translations.indices where en.translations[i].key == "Kopiuj" { en.translations[i].translation = "Copy files" }
        _ = try t.importPackage(try JSONEncoder().encode(en))
        let s = t.strings(for: "en")
        #expect(s["Kopiuj"] == "Copy files" && s["Usunięto: %lld"] == "Deleted: %lld")
        try t.remove("en")
        #expect(t.strings(for: "en")["Kopiuj"] == "Copy")
    }

    @Test func invalidFiles() throws {
        let tmp = try TempDir()
        let t = try makeApp(tmp)
        #expect(throws: Translations.TranslationError.self) { try t.importPackage(Data("{}".utf8)) }
        var p = try JSONDecoder().decode(Translations.Package.self, from: try t.exportPackage())
        p.targetLanguageCode = "../etc"
        #expect(throws: Translations.TranslationError.self) { try t.importPackage(try JSONEncoder().encode(p)) }
        p.targetLanguageCode = "pl"
        #expect(throws: Translations.TranslationError.self) { try t.importPackage(try JSONEncoder().encode(p)) }
        p.targetLanguageCode = "it"
        #expect(throws: Translations.TranslationError.self) { try t.importPackage(try JSONEncoder().encode(p)) }  // nic nie przetłumaczono
    }
}
