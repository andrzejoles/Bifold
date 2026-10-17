import Foundation
import Testing
@testable import BifoldCore

@Suite struct LocalFSTests {
    let fs = LocalFS()

    @Test func bulkListingMatchesLstat() async throws {
        let tmp = try TempDir()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try tmp.file("a.txt", "hello", modified: old)
        try tmp.file(".hidden", "x")
        try tmp.file("zażółć gęślą jaźń.md", "polskie znaki")
        try tmp.dir("sub")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appending(path: "link").path, withDestinationPath: "sub")
        chmod(tmp.url.appending(path: "a.txt").path, 0o751)

        let items = try fs.listSync(tmp.path)
        #expect(Set(items.map(\.name)) == ["a.txt", ".hidden", "zażółć gęślą jaźń.md", "sub", "link"])

        for item in items {
            let viaStat = try fs.itemSync(at: item.path)
            #expect(item.kind == viaStat.kind, "\(item.name)")
            #expect(item.size == viaStat.size, "\(item.name)")
            #expect(item.permissions == viaStat.permissions, "\(item.name)")
            #expect(item.inode == viaStat.inode, "\(item.name)")
            #expect(item.owner == viaStat.owner)
            #expect(item.modified == viaStat.modified, "\(item.name)")
        }
        let a = try #require(items.first { $0.name == "a.txt" })
        #expect(a.size == 5)
        #expect(a.permissions == 0o751)
        #expect(a.modified == old)
        #expect(a.isExecutable)
        let link = try #require(items.first { $0.name == "link" })
        #expect(link.kind == .symlink && link.isNavigable)
        #expect(try #require(items.first { $0.name == "sub" }).size == -1)
        #expect(try fs.listSync(tmp.path, options: ListOptions(includeHidden: false)).count == 4)
    }

    @Test func fileManagerFallbackGivesSameResult() throws {
        let tmp = try TempDir()
        for i in 0..<50 { try tmp.file("f\(i).dat", String(repeating: "x", count: i)) }
        let bulk = try fs.listSync(tmp.path).sorted { $0.name < $1.name }
        let slow = try fs.listWithFileManager(tmp.path).sorted { $0.name < $1.name }
        #expect(bulk == slow)
    }

    @Test func listingManyFilesUsesSeveralBulkCalls() throws {
        let tmp = try TempDir()
        for i in 0..<5000 { FileManager.default.createFile(atPath: tmp.url.appending(path: "file-\(i)-\(String(repeating: "n", count: 60))").path, contents: nil) }
        #expect(try fs.listSync(tmp.path).count == 5000)
    }

    @Test func listingMissingDirectoryThrowsNotFound() {
        #expect(throws: VFSError.notFound(.local("/nonexistent-bifold"))) {
            try fs.listSync(.local("/nonexistent-bifold"))
        }
    }

    @Test func createRenameTrashDelete() async throws {
        let tmp = try TempDir()
        let dir = tmp.path.appending("nowy")
        try await fs.createDirectory(dir)
        await #expect(throws: VFSError.alreadyExists(dir)) { try await fs.createDirectory(dir) }

        let file = dir.appending("plik.txt")
        try await fs.createFile(file, contents: Data("abc".utf8))
        await #expect(throws: VFSError.self) { try await fs.createFile(file, contents: Data()) }

        let renamed = try await fs.rename(file, to: "inny.txt")
        #expect(tmp.exists("nowy/inny.txt") && !tmp.exists("nowy/plik.txt"))

        // Zmiana tylko wielkości liter.
        let upper = try await fs.rename(renamed, to: "INNY.txt")
        #expect(try fs.listSync(dir).map(\.name) == ["INNY.txt"])

        try tmp.file("nowy/zajety.txt")
        await #expect(throws: VFSError.alreadyExists(dir.appending("zajety.txt"))) {
            _ = try await fs.rename(upper, to: "zajety.txt")
        }

        let trashed = try #require(try await fs.trash(upper))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(!tmp.exists("nowy/INNY.txt"))
        try FileManager.default.removeItem(atPath: trashed.path)

        try await fs.deletePermanently(dir)
        #expect(!tmp.exists("nowy"))
    }

    @Test func invalidNamesAreRejected() async throws {
        let tmp = try TempDir()
        let f = try tmp.file("a")
        for bad in ["", "..", "a/b", "   "] {
            await #expect(throws: VFSError.invalidName(bad)) { _ = try await fs.rename(f, to: bad) }
        }
    }

    @Test func attributesAndTags() async throws {
        let tmp = try TempDir()
        let f = try tmp.file("a.txt", "x")
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try await fs.setAttributes(f, AttributeChange(permissions: 0o600, modified: date, hidden: true, locked: true))
        var item = try fs.itemSync(at: f)
        #expect(item.permissions == 0o600)
        #expect(item.modified == date)
        #expect(item.flags.contains(.hidden) && item.flags.contains(.locked))
        #expect(item.isReadOnly)

        try await fs.setAttributes(f, AttributeChange(permissions: 0o644, locked: false))
        item = try fs.itemSync(at: f)
        #expect(item.permissions == 0o644 && !item.flags.contains(.locked) && item.flags.contains(.hidden))

        try await fs.setTags(["Czerwony", "Projekt"], on: f)
        #expect(try await fs.tags(of: f).sorted() == ["Czerwony", "Projekt"])
    }

    @Test func readRange() async throws {
        let tmp = try TempDir()
        let f = try tmp.file("r.bin", "0123456789")
        #expect(String(decoding: try await fs.readContents(f, range: 2..<5), as: UTF8.self) == "234")
        #expect(try await fs.readContents(f, range: nil).count == 10)
        #expect(try await fs.readContents(f, range: 8..<100).count == 2)
    }

    @Test func watcherReportsNewFile() async throws {
        let tmp = try TempDir()
        let stream = fs.watch(tmp.path)
        let task = Task { () -> DirectoryChange? in
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(for: .milliseconds(400))
        try tmp.file("nowy.txt", "x")
        let result = try await withThrowingTaskGroup(of: DirectoryChange?.self) { group in
            group.addTask { await task.value }
            group.addTask { try await Task.sleep(for: .seconds(5)); task.cancel(); return nil }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        #expect(result == .contentsChanged)
    }

    @Test func volumeInfoForRoot() throws {
        let info = try Volumes.info(for: .root)
        #expect(info.totalCapacity > 0)
        #expect(info.availableCapacity > 0)
        #expect(!Volumes.mounted().isEmpty)
    }
}
