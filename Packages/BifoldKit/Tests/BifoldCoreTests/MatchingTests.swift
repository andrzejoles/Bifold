import Foundation
import Testing
@testable import BifoldCore

@Suite struct NameMaskTests {
    @Test(arguments: [
        ("*.txt", "notatki.txt", true),
        ("*.txt", "notatki.TXT", true),
        ("*.txt", "notatki.md", false),
        ("*.txt;*.md", "a.md", true),
        ("*.txt *.md", "a.md", true),
        ("*.*", "Makefile", true),
        ("*", ".zshrc", true),
        ("readme.*", "README", true),
        ("readme.*", "readme.md", true),
        ("a?c.txt", "abc.txt", true),
        ("a?c.txt", "abbc.txt", false),
        ("[ab]*.log", "b1.log", true),
        ("[ab]*.log", "c1.log", false),
        ("*|*.bak", "x.bak", false),
        ("*|*.bak", "x.txt", true),
        ("*.txt|tmp*", "tmp1.txt", false),
        ("zdj(1).jpg", "zdj(1).jpg", true),
        ("", "cokolwiek", true),
    ])
    func masks(pattern: String, name: String, expected: Bool) {
        #expect(NameMask(pattern).matches(name) == expected)
    }

    @Test func directoryOnlyPattern() {
        let m = NameMask("src/")
        #expect(m.matches("src", isDirectory: true))
        #expect(!m.matches("src", isDirectory: false))
    }

    @Test func regex() {
        #expect(NameRegex("^IMG_\\d{4}").matches("img_1234.jpg"))
        #expect(!NameRegex("^IMG_\\d{4}").matches("DSC_1234.jpg"))
        #expect(!NameRegex("([").isValid)
    }
}

@Suite struct ColorRuleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func file(_ name: String, size: Int64 = 10, ageDays: Double = 0, kind: FileKind = .file, perms: UInt16 = 0o644) -> FileItem {
        FileItem(path: .local("/x/\(name)"), kind: kind, size: size, modified: now.addingTimeInterval(-ageDays * 86400), permissions: perms)
    }

    @Test func olderThanThreeMonthsIsRed() {
        let rules = ColorRuleSet.defaults
        #expect(rules.style(for: file("stary.txt", ageDays: 120), now: now)?.textColor == .red)
        #expect(rules.style(for: file("nowy.txt", ageDays: 10), now: now) == nil)
        // Katalogi nie podlegają regule „plik”.
        #expect(rules.style(for: file("katalog", ageDays: 400, kind: .directory), now: now) == nil)
    }

    @Test func conditionsAndModes() {
        let blue = HexColor(hex: "#0000FF")!
        let any = ColorRule(name: "a", match: .any, conditions: [.extensions(["jpg", ".PNG"]), .largerThan(bytes: 1000)], style: FileStyle(textColor: blue))
        let set = ColorRuleSet(rules: [any])
        #expect(set.style(for: file("a.png"), now: now) != nil)
        #expect(set.style(for: file("a.txt", size: 5000), now: now) != nil)
        #expect(set.style(for: file("a.txt"), now: now) == nil)

        let all = ColorRuleSet(rules: [ColorRule(name: "b", conditions: [.nameRegex("^raport"), .attribute(.executable, true)], style: FileStyle(bold: true))])
        #expect(all.style(for: file("raport.sh", perms: 0o755), now: now)?.bold == true)
        #expect(all.style(for: file("raport.sh"), now: now) == nil)
    }

    @Test func firstMatchingRuleWinsAndDisabledIgnored() {
        var r1 = ColorRule(name: "1", conditions: [.nameMask("*.txt")], style: FileStyle(italic: true))
        let r2 = ColorRule(name: "2", conditions: [.nameMask("*")], style: FileStyle(bold: true))
        #expect(ColorRuleSet(rules: [r1, r2]).style(for: file("a.txt"), now: now)?.italic == true)
        r1.enabled = false
        #expect(ColorRuleSet(rules: [r1, r2]).style(for: file("a.txt"), now: now)?.bold == true)
    }

    @Test func jsonRoundTripAndReadableFormat() throws {
        let set = ColorRuleSet.defaults
        let data = try set.encodedJSON()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"type\" : \"olderThan\""))
        #expect(text.contains("#D70015"))
        #expect(try ColorRuleSet.decode(json: data) == set)

        let handWritten = """
        {"rules":[{"name":"Duże","conditions":[{"type":"largerThan","bytes":1048576}],"style":{"textColor":"#FF9500","bold":true}}]}
        """
        let parsed = try ColorRuleSet.decode(json: Data(handWritten.utf8))
        #expect(parsed.rules[0].enabled && parsed.rules[0].style.bold)
        #expect(parsed.style(for: file("big.iso", size: 2_000_000), now: now)?.textColor?.hex == "#FF9500")
        #expect(throws: (any Error).self) { try ColorRuleSet.decode(json: Data(#"{"rules":[{"conditions":[{"type":"nope"}],"style":{}}]}"#.utf8)) }
    }

    @Test func hexColor() {
        #expect(HexColor(hex: "#ff000080")?.alpha == 128.0 / 255)
        #expect(HexColor(hex: "zzz") == nil)
        #expect(HexColor(hex: "00FF00")?.hex == "#00FF00")
    }
}

@Suite struct TextDecodingTests {
    @Test func detectsEncodings() {
        let pl = "Zażółć gęślą jaźń"
        #expect(TextDecoding.detect(Data(pl.utf8)) == .utf8)
        let cp1250 = pl.data(using: .windowsCP1250)!
        #expect(TextDecoding.detect(cp1250) == .windows1250)
        #expect(TextDecoding.decode(cp1250, as: .windows1250) == pl)
        let utf16 = pl.data(using: .utf16LittleEndian)!
        #expect(TextDecoding.detect(utf16) == .utf16LE)
        #expect(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data("abc".utf8), as: .utf8) == "abc")
        let latin2 = pl.data(using: .isoLatin2)!
        #expect(TextDecoding.decode(latin2, as: .iso8859_2) == pl)
        #expect(TextDecoding.decode(pl.data(using: TextEncoding.cp852.stringEncoding)!, as: .cp852) == pl)
    }

    @Test func binaryAndHex() {
        #expect(TextDecoding.looksBinary(Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01])))
        #expect(!TextDecoding.looksBinary(Data("tekst".utf8)))
        let dump = TextDecoding.hexDump(Data("ABCDEFGHIJKLMNOPQ".utf8))
        #expect(dump.hasPrefix("00000000  41 42 43"))
        #expect(dump.contains("ABCDEFGHIJKLMNOP"))
        #expect(dump.split(separator: "\n").count == 2)
    }
}

@Suite struct DirectorySizerTests {
    @Test func sumsTree() async throws {
        let tmp = try TempDir()
        try tmp.file("a/1.txt", "12345")
        try tmp.file("a/b/2.txt", "123")
        try tmp.file("a/b/c/3.txt", "1")
        let size = try await DirectorySizer.size(of: tmp.path.appending("a"))
        #expect(size.bytes == 9)
        #expect(size.files == 3)
        #expect(size.directories == 2)
    }

    @Test func cancellation() async throws {
        let tmp = try TempDir()
        try tmp.file("a/1.txt", "1")
        #expect(throws: VFSError.cancelled) {
            try DirectorySizer.sizeSync(of: tmp.path, isCancelled: { true })
        }
    }
}
