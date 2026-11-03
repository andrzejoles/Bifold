import Foundation
import Testing
@testable import BifoldMarkdown

/// Podgląd Markdown w przeglądarce F3: GFM i bezpieczeństwo wygenerowanej strony.
@Suite struct MarkdownRendererTests {
    @Test func commonMarkAndGitHubExtensions() {
        let html = MarkdownRenderer.htmlBody("""
        # Tytuł zażółć

        Tekst **pogrubiony**, *kursywa*, ~~skreślone~~ i `kod`.

        | A | B |
        |---|---|
        | 1 | 2 |

        - [x] zrobione
        - [ ] do zrobienia

        ```swift
        let x = 1
        ```

        https://example.com
        """)
        #expect(html.contains("<h1>Tytuł zażółć</h1>"))
        #expect(html.contains("<strong>pogrubiony</strong>") && html.contains("<em>kursywa</em>"))
        #expect(html.contains("<del>skreślone</del>") && html.contains("<code>kod</code>"))
        #expect(html.contains("<table>") && html.contains("<td>2</td>"))
        #expect(html.contains("type=\"checkbox\" checked=\"\" disabled=\"\""))
        #expect(html.contains("<pre lang=\"swift\"><code>let x = 1"))
        #expect(html.contains("<a href=\"https://example.com\">"))
    }

    @Test func rawHTMLAndScriptsAreDropped() {
        let html = MarkdownRenderer.htmlBody("""
        <script>alert(1)</script>

        <img src="x" onerror="alert(1)">

        [link](javascript:alert(1)) i <b onclick="x()">tekst</b>
        """)
        #expect(!html.contains("<script"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("onclick"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("raw HTML omitted"))
    }

    @Test func pageHasRestrictiveCSPAndEscapedTitle() {
        let page = MarkdownRenderer.page("Treść", title: "<a&b>.md")
        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("script-src"))
        #expect(!MarkdownRenderer.contentSecurityPolicy.contains("http"))
        #expect(page.contains("<title>&lt;a&amp;b&gt;.md</title>"))
        #expect(page.contains("<p>Treść</p>"))
    }

    @Test func localImagesInlinedRemoteNot() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bifold-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "obrazy"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try png.write(to: dir.appending(path: "obrazy/mała ikona.png"))
        try Data("nie obraz".utf8).write(to: dir.appending(path: "notatka.txt"))
        let page = MarkdownRenderer.page("""
        ![a](obrazy/mała%20ikona.png) ![b](<obrazy/mała ikona.png>) ![c](https://example.com/x.png) ![d](notatka.txt) ![e](brak.png)
        """, title: "t", directory: dir)
        let encoded = "data:image/png;base64,\(png.base64EncodedString())"
        #expect(page.components(separatedBy: encoded).count == 3)
        #expect(page.contains("src=\"https://example.com/x.png\""))
        #expect(page.contains("src=\"notatka.txt\""))
        #expect(page.contains("src=\"brak.png\""))
        #expect(MarkdownRenderer.contentSecurityPolicy.contains("img-src data:"))
        #expect(!MarkdownRenderer.contentSecurityPolicy.contains("file:"))
    }

    @Test func emptyAndInvalidUTF8() {
        #expect(MarkdownRenderer.htmlBody("").isEmpty)
        let broken = String(decoding: [0x23, 0x20, 0xC3, 0x28, 0x0A], as: UTF8.self)
        #expect(MarkdownRenderer.htmlBody(broken).hasPrefix("<h1>"))
    }
}
