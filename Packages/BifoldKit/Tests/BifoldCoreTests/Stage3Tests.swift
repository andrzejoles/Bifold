import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BifoldCore

let rg: String? = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite struct SearchTests {
    @Test func nameAndAttributeSearch() async throws {
        let tmp = try TempDir()
        try tmp.file("a/raport-2024.txt", "x", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try tmp.file("a/b/raport-2025.pdf", String(repeating: "y", count: 5000))
        try tmp.file("a/.ukryty-raport.txt")
        try tmp.file("c/inne.txt")
        var c = SearchCriteria(roots: [tmp.path], nameMask: "*raport*")
        #expect(Set(try await SearchEngine.collect(c, ripgrep: nil).hits.map(\.item.name)) == ["raport-2024.txt", "raport-2025.pdf"])
        c.includeHidden = true
        #expect(try await SearchEngine.collect(c, ripgrep: nil).hits.count == 3)
        c.includeHidden = false
        c.minSize = 1000
        #expect(try await SearchEngine.collect(c, ripgrep: nil).hits.map(\.item.name) == ["raport-2025.pdf"])
        c.minSize = nil
        c.modifiedBefore = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(try await SearchEngine.collect(c, ripgrep: nil).hits.map(\.item.name) == ["raport-2024.txt"])
        let regex = SearchCriteria(roots: [tmp.path], nameRegex: "\\d{4}\\.pdf$")
        #expect(try await SearchEngine.collect(regex, ripgrep: nil).hits.count == 1)
        let dirs = SearchCriteria(roots: [tmp.path], kind: .directories)
        #expect(Set(try await SearchEngine.collect(dirs, ripgrep: nil).hits.map(\.item.name)) == ["a", "b", "c"])
        let flat = SearchCriteria(roots: [tmp.path.appending("a")], nameMask: "*.txt;*.pdf", recursive: false)
        #expect(try await SearchEngine.collect(flat, ripgrep: nil).hits.map(\.item.name) == ["raport-2024.txt"])
        var limited = SearchCriteria(roots: [tmp.path])
        limited.maxResults = 2
        let r = try await SearchEngine.collect(limited, ripgrep: nil)
        #expect(r.hits.count == 2 && r.truncated)
    }

    @Test(.enabled(if: rg != nil)) func contentSearchWithRipgrep() async throws {
        let tmp = try TempDir()
        try tmp.file("utf8.txt", "linia 1\nZażółć gęślą jaźń\nkoniec")
        let cp1250 = "Zażółć gęślą jaźń w CP1250".data(using: .windowsCP1250)!
        FileManager.default.createFile(atPath: tmp.url.appending(path: "win.txt").path, contents: cp1250)
        try tmp.file("inne.md", "nic tu nie ma")
        try tmp.file("skip.bak", "Zażółć")

        var c = SearchCriteria(roots: [tmp.path], nameMask: "*|*.bak", contentText: "gęślą")
        let utf = try await SearchEngine.collect(c, ripgrep: rg)
        #expect(utf.hits.map(\.item.name) == ["utf8.txt"])
        #expect(utf.hits[0].matches.first?.line == 2)

        c.encoding = "windows-1250"
        let win = try await SearchEngine.collect(c, ripgrep: rg)
        #expect(win.hits.map(\.item.name).contains("win.txt"))

        let regex = SearchCriteria(roots: [tmp.path], contentText: "lin[a-z]+ \\d", contentIsRegex: true)
        #expect(try await SearchEngine.collect(regex, ripgrep: rg).hits.map(\.item.name) == ["utf8.txt"])
        let args = SearchEngine.ripgrepArguments(SearchCriteria(roots: [tmp.path], nameMask: "*.txt;*.md|tmp*", contentText: "x"))
        #expect(args.contains("--iglob") && args.contains("!tmp*") && args.contains("--fixed-strings"))
    }

    @Test func contentSearchWithoutRipgrepFails() async throws {
        let tmp = try TempDir()
        await #expect(throws: SearchEngine.SearchError.self) {
            _ = try await SearchEngine.collect(SearchCriteria(roots: [tmp.path], contentText: "x"), ripgrep: nil)
        }
    }
}

@Suite struct ChecksumAndSplitTests {
    @Test func knownHashes() throws {
        let tmp = try TempDir()
        let f = try tmp.file("abc.txt", "abc")
        #expect(try Checksums.hash(f, algorithm: .md5) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(try Checksums.hash(f, algorithm: .sha1) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(try Checksums.hash(f, algorithm: .sha256) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func createAndVerifyChecksumFile() throws {
        let tmp = try TempDir()
        let a = try tmp.file("a.txt", "abc")
        try tmp.file("b.txt", "def")
        let entries = try ["a.txt", "b.txt"].map { (try Checksums.hash(tmp.path.appending($0), algorithm: .sha256), $0) }
        try Data(Checksums.format(entries).utf8).write(to: tmp.url.appending(path: "sumy.sha256"))
        #expect(try Checksums.verify(checksumFile: tmp.path.appending("sumy.sha256")).allSatisfy { $0.status == .ok })
        try Data("zmiana".utf8).write(to: a.url!)
        try FileManager.default.removeItem(at: tmp.url.appending(path: "b.txt"))
        let results = try Checksums.verify(checksumFile: tmp.path.appending("sumy.sha256"))
        #expect(results.map(\.status) == [.mismatch, .missing])
        #expect(Checksums.parse("MD5 (plik z spacją.txt) = ABCDEF\n").first == Checksums.Entry(hash: "abcdef", path: "plik z spacją.txt"))
        #expect(Checksums.parse("abcd  nazwa.txt").first?.path == "nazwa.txt")
    }

    @Test func splitAndJoin() throws {
        let tmp = try TempDir()
        let data = Data((0..<250_000).map { UInt8($0 % 251) })
        FileManager.default.createFile(atPath: tmp.url.appending(path: "duzy.bin").path, contents: data)
        let out = try tmp.dir("czesci")
        let created = try FileSplitter.split(tmp.path.appending("duzy.bin"), partSize: 100_000, into: out)
        #expect(created.map(\.name) == ["duzy.bin.001", "duzy.bin.002", "duzy.bin.003", "duzy.bin.sha256"])
        let parts = FileSplitter.parts(startingWith: out.appending("duzy.bin.001"))
        #expect(parts.count == 3)
        let verified = try FileSplitter.join(parts, into: out.appending("duzy.bin"))
        #expect(verified == true)
        #expect(try Data(contentsOf: out.appending("duzy.bin").url!) == data)
        #expect(throws: VFSError.self) { try FileSplitter.join(parts, into: out.appending("duzy.bin")) }
    }

    @Test func duplicates() throws {
        let tmp = try TempDir()
        try tmp.file("a/x.txt", "taka sama treść")
        try tmp.file("b/y.txt", "taka sama treść")
        try tmp.file("c/x.txt", "całkiem inna treść")
        try tmp.file("d/z.txt", "inna treść!!!!?")
        let content = try DuplicateFinder.find(in: [tmp.path], mode: .content)
        #expect(content.count == 1 && Set(content[0].map(\.name)) == ["x.txt", "y.txt"])
        let names = try DuplicateFinder.find(in: [tmp.path], mode: .name)
        #expect(names.count == 1 && names[0].count == 2)
        let nameSize = try DuplicateFinder.find(in: [tmp.path], mode: .nameAndSize)
        #expect(nameSize.isEmpty)
    }
}

@Suite struct MultiRenameTests {
    func item(_ name: String, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FileItem {
        FileItem(path: .local("/zdjecia/wakacje/\(name)"), kind: .file, size: 1, modified: modified)
    }

    @Test func masksCountersAndCase() {
        var rule = RenameRule(nameMask: "[P]_[C]", counterStart: 1, counterDigits: 3)
        #expect(MultiRename.newName(for: item("IMG_1.JPG"), index: 0, rule: rule) == "wakacje_001.JPG")
        #expect(MultiRename.newName(for: item("IMG_1.JPG"), index: 4, rule: rule) == "wakacje_005.JPG")
        rule.extensionCase = .lower
        #expect(MultiRename.newName(for: item("IMG_1.JPG"), index: 0, rule: rule) == "wakacje_001.jpg")
        let date = RenameRule(nameMask: "[Y]-[M]-[D] [N]")
        let cal = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(MultiRename.newName(for: item("a.txt"), index: 0, rule: date) == String(format: "%04d-%02d-%02d a.txt", cal.year!, cal.month!, cal.day!))
        #expect(MultiRename.newName(for: item("dokument.txt"), index: 0, rule: RenameRule(nameCase: .upper)) == "DOKUMENT.txt")
        #expect(MultiRename.newName(for: item("ala ma kota.txt"), index: 0, rule: RenameRule(nameCase: .title)) == "Ala Ma Kota.txt")
        #expect(MultiRename.newName(for: item("x.txt"), index: 2, rule: RenameRule(nameMask: "[N]-[C:2]", counterStart: 10, counterStep: 5)) == "x-20.txt")
    }

    @Test(arguments: [
        ("[N2-4]", "bcd"), ("[N2,3]", "bcd"), ("[N3]", "c"), ("[N5-]", "efgh"), ("[N-3-]", "fgh"), ("[N-5,2]", "de"), ("[N1-2][N-1-]", "abh"),
    ])
    func substrings(mask: String, expected: String) {
        #expect(MultiRename.newName(for: item("abcdefgh.txt"), index: 0, rule: RenameRule(nameMask: mask, extensionMask: "")) == expected)
    }

    @Test func searchReplace() {
        let plain = RenameRule(search: "IMG", replace: "foto")
        #expect(MultiRename.newName(for: item("IMG_0001.jpg"), index: 0, rule: plain) == "foto_0001.jpg")
        let regex = RenameRule(search: "^(\\w+)_(\\d+)", replace: "$2-$1", regex: true)
        #expect(MultiRename.newName(for: item("IMG_0001.jpg"), index: 0, rule: regex) == "0001-IMG.jpg")
    }

    @Test func planDetectsProblems() throws {
        let tmp = try TempDir()
        try tmp.file("a.txt")
        try tmp.file("b.txt")
        try tmp.file("zajety.txt")
        let fs = LocalFS()
        let items = try ["a.txt", "b.txt"].map { try fs.itemSync(at: tmp.path.appending($0)) }
        let same = MultiRename.plan(items, rule: RenameRule(nameMask: "x"))
        #expect(same[0].problem == nil && same[1].problem != nil)
        let taken = MultiRename.plan([items[0]], rule: RenameRule(nameMask: "zajety"))
        #expect(taken[0].problem != nil)
        let invalid = MultiRename.plan([items[0]], rule: RenameRule(nameMask: "a/b"))
        #expect(invalid[0].problem != nil)
    }

    @Test func swapNamesAndUndo() throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "A")
        try tmp.file("b.txt", "B")
        let fs = LocalFS()
        let items = try ["a.txt", "b.txt"].map { try fs.itemSync(at: tmp.path.appending($0)) }
        let rule = RenameRule(search: "^(a|b)", replace: "", regex: true)
        _ = rule
        var plan = MultiRename.plan(items, rule: RenameRule())
        plan[0].newName = "b.txt"
        plan[1].newName = "a.txt"
        let journal = OperationJournal()
        try MultiRename.execute(plan, journal: journal, invoker: .user, title: "zamiana")
        #expect(try tmp.read("a.txt") == "B" && tmp.read("b.txt") == "A")
        let undo = UndoPlanner.plan(for: journal.batches)
        #expect(undo.conflicts.isEmpty)
        let result = UndoPlanner.execute(undo, journal: journal)
        #expect(result.errors.isEmpty)
        #expect(try tmp.read("a.txt") == "A" && tmp.read("b.txt") == "B")
    }

    @Test func exifDateInName() throws {
        let tmp = try TempDir()
        let url = tmp.url.appending(path: "zdjecie.jpg")
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2021:07:14 18:30:05"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "Aparat X"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let item = try LocalFS().itemSync(at: .local(url))
        let rule = RenameRule(nameMask: "[Exif:DateTimeOriginal:yyyy-MM-dd_HH-mm-ss] [Exif:Model]")
        #expect(MultiRename.newName(for: item, index: 0, rule: rule) == "2021-07-14_18-30-05 Aparat X.jpg")
    }
}
