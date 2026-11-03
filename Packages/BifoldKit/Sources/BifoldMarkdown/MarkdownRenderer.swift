import cmark_gfm
import cmark_gfm_extensions
import Foundation
import UniformTypeIdentifiers

/// Markdown → HTML dla podglądu w przeglądarce F3 (cmark-gfm: CommonMark + rozszerzenia GitHuba —
/// tabele, przekreślenie, autolinki, listy zadań, przypisy).
///
/// Bezpieczeństwo: surowy HTML z pliku jest pomijany (bez `CMARK_OPT_UNSAFE` cmark-gfm wstawia w jego
/// miejsce komentarz, a linki `javascript:` czyści), strona ma CSP bez skryptów i bez zasobów z sieci ani
/// z dysku — obrazy z katalogu pliku są wstawiane jako `data:`. Widok i tak ma wyłączony JavaScript.
public enum MarkdownRenderer {
    /// Rozszerzenia GFM włączane w parserze.
    static let extensions = ["table", "strikethrough", "autolink", "tasklist"]

    /// Sam fragment HTML (treść `<body>`).
    public static func htmlBody(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_DEFAULT | CMARK_OPT_FOOTNOTES | CMARK_OPT_GITHUB_PRE_LANG | CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        markdown.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let root = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(root) }
        guard let html = cmark_render_html(root, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return String(cString: html)
    }

    /// Pełna strona z arkuszem stylów (jasny i ciemny wygląd systemu) i polityką CSP.
    /// - Parameter directory: katalog pliku — obrazy o ścieżkach względnych są z niego wstawiane jako `data:`.
    public static func page(_ markdown: String, title: String, directory: URL? = nil) -> String {
        var body = htmlBody(markdown)
        if let directory { body = inlineImages(body, directory: directory) }
        return wrap(body, title: title)
    }

    static func wrap(_ body: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head><body><article>
        \(body)
        </article></body></html>
        """
    }

    public static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; img-src data:"

    /// Największy wstawiany obraz.
    static let maxImageBytes = 20 * 1024 * 1024

    /// `<img src="obraz.png">` → `data:image/png;base64,…` dla zwykłych plików graficznych o ścieżce
    /// względnej albo `file:`. Adresy sieciowe i inne pliki zostają (CSP ich nie wczyta).
    static func inlineImages(_ html: String, directory: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<img src="([^"]*)""#) else { return html }
        var result = html
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let srcRange = Range(match.range(at: 1), in: html),
                  let data = imageData(String(html[srcRange]), directory: directory),
                  let range = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: data)
        }
        return result
    }

    static func imageData(_ src: String, directory: URL) -> String? {
        // cmark koduje `&` jako `&amp;` w atrybutach; spacje i polskie znaki — procentowo.
        let raw = src.replacingOccurrences(of: "&amp;", with: "&")
        let url: URL
        if raw.hasPrefix("file:") {
            guard let u = URL(string: raw) else { return nil }
            url = u
        } else {
            guard !raw.isEmpty, !raw.contains(":"), let path = raw.removingPercentEncoding else { return nil }
            url = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
        }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let mime = type.preferredMIMEType,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= maxImageBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let css = """
    :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --code: #f6f8fa;
            --link: #0969da; --bg: #ffffff; --quote: #59636e; }
    @media (prefers-color-scheme: dark) {
      :root { --fg: #e6edf3; --muted: #9198a1; --border: #3d444d; --code: #151b23; --link: #4493f8;
              --bg: #0d1117; --quote: #9198a1; }
    }
    html { background: var(--bg); }
    body { margin: 0; color: var(--fg); background: var(--bg);
           font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    article { max-width: 880px; margin: 0 auto; padding: 24px 32px 48px; word-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { margin: 1.4em 0 0.6em; line-height: 1.25; font-weight: 600; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
    article > :first-child { margin-top: 0; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    code, pre { font: 13px/1.45 ui-monospace, "SF Mono", Menlo, monospace; }
    code { background: var(--code); padding: .2em .4em; border-radius: 6px; }
    pre { background: var(--code); padding: 14px 16px; border-radius: 6px; overflow: auto; }
    pre code { background: none; padding: 0; }
    blockquote { color: var(--quote); border-left: .25em solid var(--border); padding: 0 1em; margin-left: 0; }
    table { border-collapse: collapse; display: block; overflow: auto; }
    th, td { border: 1px solid var(--border); padding: 6px 13px; }
    th { font-weight: 600; } tr:nth-child(2n) td { background: var(--code); }
    img { max-width: 100%; }
    hr { border: 0; height: 1px; background: var(--border); margin: 1.5em 0; }
    ul.contains-task-list, li.task-list-item { list-style: none; } li.task-list-item input { margin: 0 .4em 0 -1.4em; }
    .footnotes { font-size: .9em; color: var(--muted); border-top: 1px solid var(--border); margin-top: 2em; }
    del { color: var(--muted); }
    """
}
