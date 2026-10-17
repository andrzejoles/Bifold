import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

let has7zz = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/7zz")

@MainActor @Suite(.enabled(if: has7zz)) struct ArchiveCommandTests {
    @Test func packEnterBrowseCopyOutAndUp() async throws {
        let tmp = try TempDir()
        try tmp.file("L/dokument.txt", "treść")
        try tmp.file("L/foto/x.jpg", "jpg")
        try tmp.dir("R")
        let (ws, _) = try await makeWorkspace(tmp, left: "L", right: "R")
        ws.activeTab.selectAll()
        try await ws.invoke("archive.create", CommandArguments(["destination": .string(tmp.url.path + "/L/paczka.zip")]))
        #expect(tmp.exists("L/paczka.zip"))
        await ws.activeTab.reload()
        ws.activeTab.quickSearch("paczka")
        try await ws.invoke("panel.open")
        let tab = ws.activeTab
        #expect(tab.isInArchive)
        #expect(Set(tab.visibleItems.map(\.name)) == ["..", "dokument.txt", "foto"])
        tab.quickSearch("foto")
        try await ws.invoke("file.copy", CommandArguments(["wait": true]))
        #expect(try tmp.read("R/foto/x.jpg") == "jpg")
        // Archiwum jest tylko do odczytu.
        await #expect(throws: (any Error).self) { try await ws.invoke("file.trash") }
        #expect(tmp.exists("L/paczka.zip"))
        try await ws.invoke("panel.up")
        #expect(tab.path == tmp.path.appending("L"))
        #expect(tab.cursorItem?.name == "paczka.zip")
    }

    @Test func extractCommandIntoSubfolder() async throws {
        let tmp = try TempDir()
        try tmp.file("src/a.txt", "a")
        let (ws, _) = try await makeWorkspace(tmp, left: "src")
        ws.activeTab.quickSearch("a.txt")
        try await ws.invoke("archive.create", CommandArguments(["destination": .string(tmp.url.path + "/arch.7z")]))
        try await ws.invoke("archive.extract", CommandArguments(["paths": .array([.string(tmp.url.path + "/arch.7z")]), "destination": .string(tmp.url.path + "/out")]))
        #expect(try tmp.read("out/arch/a.txt") == "a")
        try await ws.invoke("edit.undo")
        #expect(!tmp.exists("out/arch"))
    }

    @Test func agentCannotOpenPasswordArchive() async throws {
        let tmp = try TempDir()
        try tmp.file("s/a.txt", "a")
        let tool = SevenZip(executable: "/opt/homebrew/bin/7zz")
        try tool.create(tmp.path.appending("p.7z"), format: .sevenZ, base: tmp.path.appending("s"), names: ["a.txt"], password: "x")
        let (ws, ui) = try await makeWorkspace(tmp)
        await #expect(throws: ArchiveError.passwordRequired) {
            _ = try await ws.openArchive(tmp.path.appending("p.7z"), invoker: .agent(sessionID: "s", agentName: "t"))
        }
        // Użytkownik podaje hasło w oknie.
        ui.passwordAnswer = "x"
        let fs = try await ws.openArchive(tmp.path.appending("p.7z"), invoker: .user)
        #expect(fs.isEncrypted)
    }
}
