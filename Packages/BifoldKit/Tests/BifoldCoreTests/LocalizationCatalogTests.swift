import Foundation
import Testing
@testable import BifoldCore

/// Każdy tekst interfejsu ma tłumaczenie en, de, es, uk ze zgodnymi znacznikami wartości
/// (po dodaniu tekstów: make build, python3 scripts/gen-strings.py, uzupełnić tłumaczenia).
@Suite struct LocalizationCatalogTests {
    static let languages = ["en", "de", "es", "uk"]

    func catalog(_ name: String) throws -> [String: [String: Any]] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "App/Resources/\(name).xcstrings"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["strings"] as? [String: [String: Any]])
    }

    @Test func everyTextIsTranslated() throws {
        var missing: [String] = [], mismatched: [String] = []
        for (key, entry) in try catalog("Localizable") where entry["shouldTranslate"] as? Bool != false {
            let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for lang in Self.languages {
                guard let value = (locs[lang]?["stringUnit"] as? [String: Any])?["value"] as? String, !value.isEmpty else {
                    missing.append("\(lang): \(key)")
                    continue
                }
                if !Translations.placeholdersMatch(key: key, translation: value) { mismatched.append("\(lang): \(key) → \(value)") }
            }
        }
        #expect(missing.isEmpty, "Brak tłumaczeń: \(missing.sorted().prefix(30))")
        #expect(mismatched.isEmpty, "Niezgodne znaczniki: \(mismatched.sorted())")
    }

    @Test func infoPlistTextsAreTranslated() throws {
        for (key, entry) in try catalog("InfoPlist") {
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            for lang in Self.languages { #expect(locs[lang] != nil, "\(lang): \(key)") }
        }
    }
}
