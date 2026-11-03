import AppKit
import Highlightr

/// Kolorowanie składni (Highlightr = highlight.js w JavaScriptCore). Jeden silnik na własnej kolejce:
/// wczytanie highlight.js trwa ~0,1 s, a kontekst JavaScriptCore nie może być używany z wielu wątków naraz.
nonisolated final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    /// Większych tekstów nie kolorujemy (highlight.js liczy cały tekst naraz; tekst zostaje zwykły).
    static let maxCharacters = 1_000_000

    private let queue = DispatchQueue(label: "bifold.highlighter", qos: .userInitiated)
    /// Tylko na `queue`.
    private var engine: Highlightr?
    private var engineFailed = false

    /// Wynik do przekazania na wątek główny (NSAttributedString nie jest oznaczony jako Sendable).
    nonisolated final class Result: @unchecked Sendable {
        let text: NSAttributedString
        let background: NSColor?
        init(text: NSAttributedString, background: NSColor?) {
            self.text = text
            self.background = background
        }
    }

    /// Koloruje `code` jako `language` (nazwa highlight.js) motywem jasnym albo ciemnym; `nil`, gdy się nie da.
    /// Czcionka jako nazwa i rozmiar (NSFont nie jest Sendable).
    func highlight(_ code: String, language: String, dark: Bool, fontName: String, fontSize: CGFloat) async -> Result? {
        guard code.utf16.count <= Self.maxCharacters else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: run(code, language, dark, fontName, fontSize))
            }
        }
    }

    private func run(_ code: String, _ language: String, _ dark: Bool, _ fontName: String, _ fontSize: CGFloat) -> Result? {
        if engine == nil, !engineFailed {
            engine = Highlightr()
            engineFailed = engine == nil
        }
        guard let engine, engine.setTheme(to: dark ? "atom-one-dark" : "xcode") else { return nil }
        engine.theme.setCodeFont(NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        guard let text = engine.highlight(code, as: language, fastRender: true) else { return nil }
        return Result(text: text, background: engine.theme.themeBackgroundColor)
    }
}
