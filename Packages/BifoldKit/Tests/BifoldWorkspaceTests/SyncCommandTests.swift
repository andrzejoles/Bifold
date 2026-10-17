import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

let hasRclone = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rclone")

@MainActor @Suite(.serialized, .enabled(if: hasRclone)) struct SyncCommandTests {
    @Test func compareDirsMarksAndSyncRun() async throws {
        let tmp = try TempDir()
        try tmp.file("L/nowy.txt", "n")
        try tmp.file("L/wspolny.txt", "1", modified: Date(timeIntervalSince1970: 1_600_000_000))
        try tmp.file("R/wspolny.txt", "1", modified: Date(timeIntervalSince1970: 1_600_000_000))
        try tmp.file("R/stary.txt", "s")
        let (ws, ui) = try await makeWorkspace(tmp, left: "L", right: "R")
        defer { ws.remotes.stop() }
        try await ws.invoke("dirs.compare")
        #expect(ws.left.activeTab.selectedItems.map(\.name) == ["nowy.txt"])
        #expect(ws.right.activeTab.selectedItems.map(\.name) == ["stary.txt"])

        let preview = try await ws.invoke("sync.preview", CommandArguments(["mode": "mirror"]))
        #expect(preview.value?["actions"]?.arrayValue?.count == 2)
        try await ws.invoke("sync.run", CommandArguments(["mode": "mirror"]))
        #expect(tmp.exists("R/nowy.txt") && !tmp.exists("R/stary.txt"))
        // Usunięty plik lokalny jest w Koszu — cofnięcie go przywraca.
        try await ws.invoke("edit.undo")
        #expect(tmp.exists("R/stary.txt") && !tmp.exists("R/nowy.txt"))

        try await ws.invoke("sync.save", CommandArguments(["name": "kopia", "mode": "update"]))
        #expect(ws.syncJobs.map(\.name) == ["kopia"])

        // Porównanie plików w obu panelach (użytkownik → okno).
        ws.left.activeTab.quickSearch("wspolny")
        ws.right.activeTab.quickSearch("wspolny")
        try await ws.invoke("file.compare")
        #expect(ui.compared?.0.name == "wspolny.txt")
    }

    @Test func agentStyleCompareReturnsDiff() async throws {
        let tmp = try TempDir()
        try tmp.file("L/a.txt", "jeden\ndwa\n")
        try tmp.file("R/a.txt", "jeden\nDWA\n")
        let (ws, _) = try await makeWorkspace(tmp, left: "L", right: "R")
        let ctxResult = try await ws.registry.command("file.compare")!.run(CommandContext(workspace: ws, invoker: .agent(sessionID: "x", agentName: "t"), arguments: CommandArguments(["left": .string(tmp.url.path + "/L/a.txt"), "right": .string(tmp.url.path + "/R/a.txt")])))
        #expect(ctxResult.value?["diff"]?.stringValue?.contains("-dwa\n+DWA") == true)
    }
}
