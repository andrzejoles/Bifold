import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

@MainActor @Suite struct Stage3CommandTests {
    @Test func searchToPanelAndOperateOnResults() async throws {
        let tmp = try TempDir()
        try tmp.file("a/raport1.txt", "x")
        try tmp.file("b/c/raport2.txt", "y")
        try tmp.file("b/inne.md")
        try tmp.dir("dst")
        let (ws, _) = try await makeWorkspace(tmp, right: "dst")
        try await ws.invoke("search.find", CommandArguments(["nameMask": "raport*", "toPanel": true]))
        let tab = ws.activeTab
        #expect(tab.isSearchResults)
        #expect(tab.title.contains("raport"))
        #expect(Set(tab.visibleItems.map(\.name)) == ["raport1.txt", "raport2.txt"])
        // Operacje na wynikach działają na prawdziwych ścieżkach.
        tab.selectAll()
        try await ws.invoke("file.copy", CommandArguments(["wait": true]))
        #expect(tmp.exists("dst/raport1.txt") && tmp.exists("dst/raport2.txt"))
        // Tworzenie plików w liście wyników jest zablokowane.
        await #expect(throws: CommandError.self) { try await ws.invoke("file.mkdir", CommandArguments(["name": "x"])) }
    }

    @Test func agentSearchReturnsJSON() async throws {
        let tmp = try TempDir()
        try tmp.file("a.jpg")
        try tmp.file("b.png")
        let (ws, _) = try await makeWorkspace(tmp)
        let r = try await ws.invoke("search.find", CommandArguments(["nameMask": "*.jpg", "toPanel": false]))
        #expect(r.value?["count"]?.intValue == 1)
        #expect(!ws.activeTab.isSearchResults)
    }

    @Test func savedSearches() async throws {
        let tmp = try TempDir()
        try tmp.file("x.log")
        let (ws, _) = try await makeWorkspace(tmp)
        try await ws.invoke("search.save", CommandArguments(["name": "logi", "nameMask": "*.log"]))
        #expect(ws.savedSearches.map(\.name) == ["logi"])
        try await ws.invoke("search.runSaved", CommandArguments(["name": "logi", "toPanel": true]))
        #expect(ws.activeTab.visibleItems.map(\.name) == ["x.log"])
    }

    @Test func multiRenameWithUndo() async throws {
        let tmp = try TempDir()
        for n in ["IMG_1.JPG", "IMG_2.JPG"] { try tmp.file(n) }
        let (ws, _) = try await makeWorkspace(tmp)
        ws.activeTab.selectAll()
        let preview = try await ws.preview("file.multiRename", CommandArguments(["nameMask": "wakacje_[C]", "counterDigits": 2, "extensionCase": "lower"]))
        #expect(preview.operations.count == 2 && preview.conflicts.isEmpty)
        try await ws.invoke("file.multiRename", CommandArguments(["nameMask": "wakacje_[C]", "counterDigits": 2, "extensionCase": "lower"]))
        #expect(tmp.exists("wakacje_01.jpg") && tmp.exists("wakacje_02.jpg"))
        try await ws.invoke("edit.undo")
        #expect(tmp.exists("IMG_1.JPG") && tmp.exists("IMG_2.JPG"))
    }

    @Test func multiRenameOpensWindowForUser() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt")
        let (ws, ui) = try await makeWorkspace(tmp)
        ws.activeTab.quickSearch("a.txt")
        try await ws.invoke("file.multiRename")
        #expect(ui.multiRenameItems.map(\.name) == ["a.txt"])
    }

    @Test func checksumsSplitJoinDuplicates() async throws {
        let tmp = try TempDir()
        try tmp.file("src/abc.txt", "abc")
        try tmp.file("src/kopia.txt", "abc")
        try tmp.dir("dst")
        let (ws, ui) = try await makeWorkspace(tmp, left: "src", right: "dst")
        ws.activeTab.quickSearch("abc.txt")
        try await ws.invoke("file.checksumCreate", CommandArguments(["algorithm": "md5"]))
        #expect(try tmp.read("src/abc.txt.md5").hasPrefix("900150983cd24fb0d6963f7d28e17f72 *abc.txt"))
        let verify = try await ws.invoke("file.checksumVerify", CommandArguments(["paths": ["abc.txt.md5"]]))
        #expect(verify.message?.contains("Błędy: 0") == true)
        #expect(!ui.reports.isEmpty)

        let dup = try await ws.invoke("search.duplicates", CommandArguments(["toPanel": false]))
        #expect(dup.value?.arrayValue?.count == 1)

        FileManager.default.createFile(atPath: tmp.url.appending(path: "src/big.bin").path, contents: Data(repeating: 1, count: 3000))
        try await ws.invoke("file.split", CommandArguments(["path": "big.bin", "partSize": "1K"]))
        #expect(tmp.exists("dst/big.bin.001") && tmp.exists("dst/big.bin.003") && tmp.exists("dst/big.bin.sha256"))
        let joined = try await ws.invoke("file.join", CommandArguments(["path": .string(tmp.url.path + "/dst/big.bin.001"), "target": .string(tmp.url.path + "/big-joined.bin")]))
        #expect(joined.value?["verified"]?.boolValue == true)
        #expect(parseSize("1,5G") == 1_610_612_736 && parseSize("700k") == 716_800 && parseSize("12") == 12)
    }
}
