import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

@MainActor @Suite struct CommandTests {
    @Test func copyWithDialogDefaultsToOtherPanel() async throws {
        let tmp = try TempDir()
        try tmp.file("L/a.txt", "a")
        try tmp.dir("R")
        let (ws, _) = try await makeWorkspace(tmp, left: "L", right: "R")
        ws.activeTab.quickSearch("a.txt")
        let result = try await ws.invoke("file.copy", CommandArguments(["wait": true]))
        #expect(result.value?["state"]?.stringValue == "completed")
        #expect(try tmp.read("R/a.txt") == "a")
    }

    @Test func moveWithExplicitDestinationAndRename() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        let (ws, _) = try await makeWorkspace(tmp)
        try await ws.invoke("file.move", CommandArguments(["paths": ["a.txt"], "destination": "nowy/b.txt", "wait": true]))
        // Jeden element i nieistniejąca ścieżka → nowa nazwa (katalog nadrzędny musi istnieć).
        #expect(!tmp.exists("a.txt"))
        #expect(try tmp.read("nowy/b.txt") == "a")
    }

    @Test func mkdirNestedAndUndo() async throws {
        let tmp = try TempDir()
        let (ws, ui) = try await makeWorkspace(tmp)
        ui.textAnswers = ["a/b/c"]
        try await ws.invoke("file.mkdir")
        #expect(tmp.exists("a/b/c"))
        #expect(ws.activeTab.cursorItem?.name == "a")
        for _ in 0..<3 { try await ws.invoke("edit.undo") }
        #expect(!tmp.exists("a"))
    }

    @Test func newFileOpensEditor() async throws {
        let tmp = try TempDir()
        let (ws, ui) = try await makeWorkspace(tmp)
        try await ws.invoke("file.newFile", CommandArguments(["name": "notatka.md"]))
        #expect(tmp.exists("notatka.md"))
        #expect(ui.openedInEditor.map(\.lastPathComponent) == ["notatka.md"])
        #expect(ws.activeTab.cursorItem?.name == "notatka.md")
    }

    @Test func renameTrashUndo() async throws {
        let tmp = try TempDir()
        try tmp.file("stary.txt", "x")
        let (ws, ui) = try await makeWorkspace(tmp)
        ws.activeTab.quickSearch("stary")
        ui.textAnswers = ["nowy.txt"]
        try await ws.invoke("file.rename")
        #expect(tmp.exists("nowy.txt"))
        try await ws.invoke("file.trash")
        #expect(!tmp.exists("nowy.txt"))
        try await ws.invoke("edit.undo")
        #expect(tmp.exists("nowy.txt"))
        try await ws.invoke("edit.undo")
        #expect(tmp.exists("stary.txt"))
    }

    @Test func attributesTagsClipboardColors() async throws {
        let tmp = try TempDir()
        try tmp.file("f.txt", "x")
        let (ws, ui) = try await makeWorkspace(tmp)
        try await ws.invoke("file.attributes", CommandArguments(["paths": ["f.txt"], "permissions": "640", "hidden": true]))
        let item = try LocalFS().itemSync(at: tmp.path.appending("f.txt"))
        #expect(item.permissions == 0o640 && item.flags.contains(.hidden))
        try await ws.invoke("file.tags", CommandArguments(["paths": ["f.txt"], "tags": ["Czerwony"]]))
        #expect(try LocalFS().tagsSync(of: item.path) == ["Czerwony"])
        try await ws.invoke("clipboard.copyPaths", CommandArguments(["paths": ["f.txt"]]))
        #expect(ui.pasteboard == [tmp.path.appending("f.txt").path])

        let rules = try await ws.invoke("colors.get").value!
        var obj = rules.objectValue!
        obj["rules"] = .array([])
        try await ws.invoke("colors.set", CommandArguments(["rules": .object(obj)]))
        #expect(ws.colorRules.rules.isEmpty)
        await #expect(throws: CommandError.self) {
            try await ws.invoke("colors.set", CommandArguments(["rules": ["rules": [["bad": 1]]]]))
        }
    }

    @Test func previewDoesNotModify() async throws {
        let tmp = try TempDir()
        try tmp.file("L/a.txt", "12345")
        let (ws, _) = try await makeWorkspace(tmp, left: "L")
        let preview = try await ws.preview("file.copy", CommandArguments(["paths": ["a.txt"], "destination": .string(tmp.url.path + "/nowy-katalog/")]))
        #expect(preview.totalBytes == 5 && preview.fileCount == 1)
        #expect(!tmp.exists("nowy-katalog"))
    }

    @Test func agentInvocationWithoutGateIsRefused() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        await #expect(throws: CommandError.self) {
            try await ws.invoke("panel.refresh", invoker: .agent(sessionID: "x", agentName: "test"))
        }
    }

    @Test func selectionCommands() async throws {
        let tmp = try TempDir()
        for n in ["a.jpg", "b.jpg", "c.png", "d.txt"] { try tmp.file(n) }
        let (ws, ui) = try await makeWorkspace(tmp)
        ui.textAnswers = ["*.jpg;*.png"]
        try await ws.invoke("selection.byMask")
        #expect(ws.activeTab.selection.count == 3)
        try await ws.invoke("selection.deselectByMask", CommandArguments(["mask": "*.png"]))
        #expect(ws.activeTab.selection.count == 2)
        try await ws.invoke("selection.save")
        try await ws.invoke("selection.none")
        #expect(ws.activeTab.selection.isEmpty)
        try await ws.invoke("selection.restore")
        #expect(ws.activeTab.selection.count == 2)
        ws.activeTab.quickSearch("d.txt")
        try await ws.invoke("selection.toggle")
        #expect(ws.activeTab.selection.contains(tmp.path.appending("d.txt")))
    }

    /// Karta-terminal zostaje terminalem: nowa karta i katalogi lokalne otwierają się obok niej.
    @Test func terminalTabKeepsItsMachine() async throws {
        let tmp = try TempDir()
        try tmp.dir("sub")
        let (ws, _) = try await makeWorkspace(tmp)
        let term = ws.left.newTab(at: VFSPath(provider: RemoteFS.providerID("aix"), path: "/"))
        term.terminal = TerminalSpec(alias: "aix", executable: "/usr/bin/ssh", arguments: [], term: "xterm")
        try await ws.invoke("tab.new")
        #expect(ws.left.tabs.count == 3 && ws.activeTab.terminal == nil && ws.activeTab.path == tmp.path)

        ws.left.selectTab(id: term.id)
        try await ws.invoke("panel.navigate", CommandArguments(["path": .string(tmp.url.path + "/sub")]))
        #expect(ws.left.tabs.count == 4 && ws.activeTab.path == tmp.path.appending("sub"))
        #expect(term.terminal != nil && term.path.provider == RemoteFS.providerID("aix"))
        await #expect(throws: (any Error).self) { try await term.navigate(to: tmp.path) }
        ws.left.selectTab(id: term.id)
        try await ws.invoke("panel.home")
        #expect(ws.left.tabs.count == 5 && ws.activeTab.path == tmp.path)

        // Ta sama maszyna (dysk lokalny) — ta sama karta.
        ws.left.selectTab(0)
        try await ws.invoke("panel.navigate", CommandArguments(["path": .string(tmp.url.path + "/sub")]))
        #expect(ws.left.tabs.count == 5 && ws.left.activeTabIndex == 0 && ws.activeTab.path == tmp.path.appending("sub"))
    }

    @Test func tabsAndViews() async throws {
        let tmp = try TempDir()
        try tmp.dir("sub")
        let (ws, _) = try await makeWorkspace(tmp)
        try await ws.invoke("tab.new", CommandArguments(["path": "sub"]))
        #expect(ws.left.tabs.count == 2 && ws.activeTab.path == tmp.path.appending("sub"))
        try await ws.invoke("view.thumbnails")
        #expect(ws.activeTab.viewMode == .thumbnails)
        try await ws.invoke("tab.previous")
        #expect(ws.activeTab.path == tmp.path)
        try await ws.invoke("panel.switch")
        #expect(ws.activeSide == .right)
        try await ws.invoke("panel.navigate", CommandArguments(["path": .string(tmp.url.path + "/sub")]))
        #expect(ws.right.activeTab.path == tmp.path.appending("sub"))
    }
}
