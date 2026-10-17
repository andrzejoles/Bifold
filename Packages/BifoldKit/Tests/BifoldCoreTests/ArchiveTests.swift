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

    @Test func detection() {
        for n in ["a.zip", "B.RAR", "x.tar.gz", "y.tgz", "z.part1.rar", "w.zip.001"] { #expect(ArchiveFS.isArchive(n), "\(n)") }
        for n in ["a.txt", "b.001", "c"] { #expect(!ArchiveFS.isArchive(n), "\(n)") }
    }
}
