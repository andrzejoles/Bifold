import Foundation
import Testing
@testable import BifoldCore

let sevenZipPath: String? = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"].first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.enabled(if: sevenZipPath != nil)) struct ArchiveTests {
    let tool = SevenZip(executable: sevenZipPath ?? "")

    func fixture() throws -> TempDir {
        let tmp = try TempDir()
        try tmp.file("src/zażółć.txt", "gęślą jaźń")
        try tmp.file("src/katalog/b.txt", "B")
        try tmp.file("src/katalog/głęboko/c.txt", "C")
        return tmp
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZ, .tar, .tarGz, .tarBz2, .tarXz])
    func createListExtract(format: ArchiveFormat) throws {
        let tmp = try fixture()
        let archive = tmp.path.appending("a." + format.fileExtension)
        try tool.create(archive, format: format, base: tmp.path.appending("src"), names: ["zażółć.txt", "katalog"])
        let fs = try ArchiveFS(archive: archive, tool: tool)
        // tar.* — w środku jest jeden plik .tar (jak w TC); 7zz widzi go jako zawartość.
        if format.isTarCompound { return }
        let names = Set(fs.descendants(of: fs.root).map(\.path))
        #expect(names.contains("zażółć.txt") || names.contains("zażółć.txt".decomposedStringWithCanonicalMapping))
        #expect(names.contains("katalog/głęboko/c.txt") || names.contains("katalog/głęboko/c.txt".decomposedStringWithCanonicalMapping))
        let out = try tmp.dir("out")
        try tool.extract(archive, to: out, password: nil)
        #expect(try tmp.read("out/katalog/głęboko/c.txt") == "C")
    }

    /// Archiwum z wpisami `./…` (tar z „.”) i spreparowanymi `../…`: `./kat` widać jako `kat`, korzeń „.”
    /// nie jest folderem, a wpisy z `..` są pomijane — rozpakowany element liczony jako `temp/../x`
    /// wskazywałby istniejący plik poza katalogiem tymczasowym.
    @Test func dotAndTraversalEntries() async throws {
        let tmp = try TempDir()
        try tmp.file("src/kat/a.txt", "A")
        try tmp.file("src/poza.txt", "P")
        func tar(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/tar")
            p.currentDirectoryURL = tmp.url.appending(path: "src")
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        try tar(["-cf", "../kropka.tar", "."])
        try tar(["-cf", "../zly.tar", "-s", ",^poza,../../poza,", "poza.txt", "kat"])

        let dot = try ArchiveFS(archive: tmp.path.appending("kropka.tar"), tool: tool)
        #expect(Set(try await dot.list(dot.root, options: ListOptions()).map(\.name)) == ["kat", "poza.txt"])
        #expect(try await dot.list(dot.root.appending("kat"), options: ListOptions()).map(\.name) == ["a.txt"])
        let (temp, items) = try dot.extract([dot.root.appending("kat").appending("a.txt")], toTemporaryIn: tmp.path, isCancelled: { false })
        #expect(try String(contentsOfFile: items[0].path, encoding: .utf8) == "A")
        try? FileManager.default.removeItem(atPath: temp.path)

        let bad = try ArchiveFS(archive: tmp.path.appending("zly.tar"), tool: tool)
        #expect(try await bad.list(bad.root, options: ListOptions()).map(\.name) == ["kat"])
        #expect(!bad.descendants(of: bad.root).contains { $0.path.contains("..") })
    }

    @Test func browseAsDirectoryAndRead() async throws {
        let tmp = try fixture()
        let archive = tmp.path.appending("a.zip")
        try tool.create(archive, format: .zip, base: tmp.path.appending("src"), names: ["zażółć.txt", "katalog"])
        let fs = try ArchiveFS(archive: archive, tool: tool)
        let root = try await fs.list(fs.root, options: ListOptions())
        #expect(Set(root.map(\.name).map { $0.precomposedStringWithCanonicalMapping }) == ["zażółć.txt", "katalog"])
        let dir = try #require(root.first { $0.isDirectory })
        let inner = try await fs.list(dir.path, options: ListOptions())
        #expect(Set(inner.map(\.name).map { $0.precomposedStringWithCanonicalMapping }) == ["b.txt", "głęboko"])
        let file = try #require(root.first { !$0.isDirectory })
        #expect(String(decoding: try await fs.readContents(file.path, range: nil), as: UTF8.self) == "gęślą jaźń")
        #expect(fs.hostLocation == archive)
        // LocalFS nie dotyka ścieżek z archiwum.
        #expect(throws: VFSError.self) { try LocalFS().itemSync(at: file.path) }
    }

    @Test func extractSelectedIntoDirectoryViaJob() async throws {
        let tmp = try fixture()
        let archive = tmp.path.appending("a.7z")
        try tool.create(archive, format: .sevenZ, base: tmp.path.appending("src"), names: ["zażółć.txt", "katalog"])
        let fs = try ArchiveFS(archive: archive, tool: tool)
        let dest = try tmp.dir("dest")
        let journal = OperationJournal()
        let queue = await JobQueue(journal: journal)
        let dir = VFSPath(provider: fs.id, path: "/katalog/głęboko")
        let job = await queue.enqueue(.extract(source: fs, sources: [dir], destination: dest), title: "x")
        #expect(await queue.wait(for: job) == .completed)
        #expect(try tmp.read("dest/głęboko/c.txt") == "C")
        // Bez śladu katalogu tymczasowego; cofnięcie usuwa wypakowane.
        #expect(try LocalFS().listSync(dest).map(\.name).map { $0.precomposedStringWithCanonicalMapping } == ["głęboko"])
        let undo = UndoPlanner.plan(for: journal.batches)
        #expect(undo.conflicts.isEmpty)
        _ = UndoPlanner.execute(undo, journal: journal)
        #expect(try LocalFS().listSync(dest).isEmpty)
    }

    @Test func passwordProtected() throws {
        let tmp = try fixture()
        let archive = tmp.path.appending("p.7z")
        try tool.create(archive, format: .sevenZ, base: tmp.path.appending("src"), names: ["zażółć.txt"], password: "tajne")
        #expect(throws: ArchiveError.passwordRequired) { try ArchiveFS(archive: archive, tool: tool) }
        #expect(throws: ArchiveError.wrongPassword) { try ArchiveFS(archive: archive, tool: tool, password: "zle") }
        let fs = try ArchiveFS(archive: archive, tool: tool, password: "tajne")
        #expect(fs.isEncrypted)
        let zip = tmp.path.appending("p.zip")
        try tool.create(zip, format: .zip, base: tmp.path.appending("src"), names: ["zażółć.txt"], password: "tajne")
        let zfs = try ArchiveFS(archive: zip, tool: tool)
        #expect(zfs.isEncrypted)
        #expect(throws: (any Error).self) { try tool.extract(zip, to: try tmp.dir("o"), password: nil) }
        try tool.extract(zip, to: try tmp.dir("o2"), password: "tajne")
        #expect(tmp.exists("o2/zażółć.txt") || tmp.exists("o2/" + "zażółć.txt".decomposedStringWithCanonicalMapping))
    }

    @Test func multiVolume() throws {
        let tmp = try TempDir()
        FileManager.default.createFile(atPath: tmp.url.appending(path: "big.bin").path, contents: Data((0..<300_000).map { _ in UInt8.random(in: 0...255) }))
        let archive = tmp.path.appending("big.7z")
        try tool.create(archive, format: .sevenZ, base: tmp.path, names: ["big.bin"], level: 0, volumeSize: "100k")
        let parts = FileSplitter.parts(startingWith: tmp.path.appending("big.7z.001"))
        #expect(parts.count >= 3)
        #expect(ArchiveFS.isArchive("big.7z.001"))
        let out = try tmp.dir("out")
        try tool.extract(tmp.path.appending("big.7z.001"), to: out, password: nil)
        #expect(try Data(contentsOf: out.appending("big.bin").url!) == Data(contentsOf: tmp.url.appending(path: "big.bin")))
        #expect(try tool.test(tmp.path.appending("big.7z.001"), password: nil))
    }

    @Test func searchInsideArchives() async throws {
        let tmp = try fixture()
        try tool.create(tmp.path.appending("pak.zip"), format: .zip, base: tmp.path.appending("src"), names: ["katalog"])
        try FileManager.default.removeItem(at: tmp.url.appending(path: "src"))
        var c = SearchCriteria(roots: [tmp.path], nameMask: "c.txt")
        #expect(try await SearchEngine.collect(c, ripgrep: nil).hits.isEmpty)
        c.archiveTool = sevenZipPath
        let hits = try await SearchEngine.collect(c, ripgrep: nil).hits
        #expect(hits.map(\.item.name) == ["pak.zip"])
        #expect(hits[0].matches.first?.text.contains("c.txt") == true)
    }

    /// „Rozpakuj archiwa” z nadpisaniem do istniejącego katalogu: stary plik w Koszu, cofnięcie go przywraca.
    @Test func extractArchivesOverwriteIsUndoable() async throws {
        let tmp = try TempDir()
        try tmp.file("src/x.txt", "nowy")
        try tmp.file("src/kat/y.txt", "Y")
        let archive = tmp.path.appending("pak.zip")
        try tool.create(archive, format: .zip, base: tmp.path.appending("src"), names: ["x.txt", "kat"])
        try tmp.file("dest/x.txt", "stary")
        try tmp.file("dest/kat/inny.txt", "I")
        let journal = OperationJournal()
        let queue = await JobQueue(journal: journal)
        let job = await queue.enqueue(.extractArchives([archive], destination: tmp.path.appending("dest"), tool: tool, overwrite: .overwrite, subfolders: false), title: "x")
        #expect(await queue.wait(for: job) == .completed)
        #expect(try tmp.read("dest/x.txt") == "nowy")
        #expect(try tmp.names("dest") == ["x.txt", "kat"])
        #expect(try tmp.names("dest/kat") == ["y.txt", "inny.txt"])
        let actions = journal.batches[0].entries.map(\.action)
        #expect(actions.contains { if case .trashed(let original, _) = $0 { original == tmp.path.appending("dest/x.txt") } else { false } })

        let undo = UndoPlanner.plan(for: journal.batches)
        #expect(undo.conflicts.isEmpty)
        let result = UndoPlanner.execute(undo, journal: journal)
        #expect(result.errors.isEmpty)
        #expect(try tmp.read("dest/x.txt") == "stary")
        #expect(try tmp.names("dest/kat") == ["inny.txt"])
    }

    /// „Rozpakuj do podkatalogów”: wpis kopii ma liczbę elementów, więc plik dopisany później do
    /// podkatalogu jest konfliktem, a nie trafia do Kosza razem z rozpakowaną zawartością.
    @Test func extractArchivesToSubfoldersRecordsItemCount() async throws {
        let tmp = try TempDir()
        try tmp.file("src/x.txt", "x")
        try tmp.file("src/kat/y.txt", "Y")
        let archive = tmp.path.appending("pak.zip")
        try tool.create(archive, format: .zip, base: tmp.path.appending("src"), names: ["x.txt", "kat"])
        try tmp.dir("dest")
        let journal = OperationJournal()
        let queue = await JobQueue(journal: journal)
        let job = await queue.enqueue(.extractArchives([archive], destination: tmp.path.appending("dest"), tool: tool, overwrite: .overwrite, subfolders: true), title: "x")
        #expect(await queue.wait(for: job) == .completed)
        let target = tmp.path.appending("dest/pak")
        let entry = try #require(journal.batches.first?.entries.first)
        #expect(entry.action == .copied(from: archive, to: target))
        #expect(entry.itemCount == 3)
        #expect(UndoPlanner.plan(for: journal.batches).conflicts.isEmpty)
        try tmp.file("dest/pak/pozniej.txt", "później")
        #expect(UndoPlanner.plan(for: journal.batches).conflicts == [.modified(target)])
    }

    /// Anulowane tworzenie archiwum (także wieloczęściowego) nie zostawia archiwum, części ani plików tymczasowych.
    @Test func cancelledCreateLeavesNothing() throws {
        let tmp = try TempDir()
        FileManager.default.createFile(atPath: tmp.url.appending(path: "src/big.bin").path, contents: nil)
        try FileManager.default.createDirectory(at: tmp.url.appending(path: "src"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.url.appending(path: "src/big.bin").path,
                                       contents: Data((0..<24_000_000).map { _ in UInt8.random(in: 0...255) }))
        for volumeSize in [nil, "1m"] as [String?] {
            let start = ContinuousClock.now
            #expect(throws: VFSError.cancelled) {
                try tool.create(tmp.path.appending("a.7z"), format: .sevenZ, base: tmp.path.appending("src"), names: ["big.bin"], level: 9,
                                volumeSize: volumeSize, isCancelled: { ContinuousClock.now - start > .milliseconds(300) })
            }
            #expect(try tmp.names() == ["src"])
        }
        // Błąd 7zz (brak pliku źródłowego) też nie zostawia śladów.
        #expect(throws: (any Error).self) {
            try tool.create(tmp.path.appending("b.zip"), format: .zip, base: tmp.path.appending("src"), names: ["nie-ma.bin"])
        }
        #expect(try tmp.names() == ["src"])
        // Sukces: właściwe nazwy części.
        try tool.create(tmp.path.appending("c.zip"), format: .zip, base: tmp.path.appending("src"), names: ["big.bin"], level: 0, volumeSize: "10m")
        #expect(try tmp.names() == ["src", "c.zip.001", "c.zip.002", "c.zip.003"])
    }

    /// Odczyt fragmentu wpisu strumieniowo i rozpakowanie jednego pliku do katalogu.
    @Test func readRangeAndExtractFile() async throws {
        let tmp = try TempDir()
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
        try FileManager.default.createDirectory(at: tmp.url.appending(path: "src/kat"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.url.appending(path: "src/kat/dane.bin").path, contents: data)
        let archive = tmp.path.appending("a.zip")
        try tool.create(archive, format: .zip, base: tmp.path.appending("src"), names: ["kat"])
        let fs = try ArchiveFS(archive: archive, tool: tool)
        let entry = fs.root.appending("kat").appending("dane.bin")
        #expect(try await fs.readContents(entry, range: 1_000_000..<1_000_016) == data.subdata(in: 1_000_000..<1_000_016))
        #expect(try await fs.readContents(entry, range: 0..<10) == data.prefix(10))
        #expect(try await fs.readContents(entry, range: 2_999_990..<4_000_000) == data.suffix(10))
        #expect(try await fs.readContents(entry, range: nil) == data)
        let out = try tmp.dir("out")
        let file = try fs.extractFile(entry, to: out)
        #expect(file == out.appending("dane.bin"))
        #expect(try Data(contentsOf: file.url!) == data)
    }

    /// Wpisy z nazwą ze znakiem sterującym (w dowolnym składniku ścieżki) są pomijane.
    @Test func unsafeEntryNamesAreSkipped() async throws {
        let tmp = try TempDir()
        func header(_ name: String, size: Int, type: UInt8) -> Data {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ offset: Int) { for (i, b) in s.utf8.enumerated() { h[offset + i] = b } }
            put(name, 0)
            put("0000644", 100); put("0000000", 108); put("0000000", 116)
            put(String(format: "%011o", size), 124)
            put(String(format: "%011o", 1_700_000_000), 136)
            h[156] = type
            put("ustar", 257); put("00", 263)
            for i in 148..<156 { h[i] = 0x20 }
            put(String(format: "%06o", h.reduce(0) { $0 + Int($1) }) + "\0", 148)
            return Data(h)
        }
        var tar = Data()
        for (name, body) in [("ok.txt", "OK"), ("zly\nplik.txt", "X"), ("   /a.txt", "Y"), ("kat\u{7F}/c.txt", "Z"), ("dobry/b.txt", "B")] {
            tar += header(name, size: body.utf8.count, type: UInt8(ascii: "0"))
            var content = Data(body.utf8)
            content += Data(count: (512 - content.count % 512) % 512)
            tar += content
        }
        tar += Data(count: 1024)
        let archive = tmp.path.appending("nazwy.tar")
        FileManager.default.createFile(atPath: archive.path, contents: tar)
        let fs = try ArchiveFS(archive: archive, tool: tool)
        // 7zz sam zamienia część znaków sterujących (np. nowa linia → „_”); reszta musi odpaść u nas.
        let paths = fs.descendants(of: fs.root).map(\.path)
        #expect(paths.allSatisfy { ArchiveFS.isUsable($0) }, "\(paths)")
        #expect(Set(try await fs.list(fs.root, options: ListOptions()).map(\.name)).isSuperset(of: ["ok.txt", "dobry"]))
        #expect(!paths.contains { $0.hasPrefix("   ") || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } })
        #expect(ArchiveFS.isUsable("./kat/a.txt") && !ArchiveFS.isUsable(".") && !ArchiveFS.isUsable("a/../b"))
        #expect(!ArchiveFS.isUsable("kat\u{7}/a.txt") && !ArchiveFS.isUsable("zly\nplik.txt") && !ArchiveFS.isUsable("   /a.txt"))
    }

    @Test func detection() {
        for n in ["a.zip", "B.RAR", "x.tar.gz", "y.tgz", "z.part1.rar", "w.zip.001"] { #expect(ArchiveFS.isArchive(n), "\(n)") }
        for n in ["a.txt", "b.001", "c"] { #expect(!ArchiveFS.isArchive(n), "\(n)") }
    }
}
