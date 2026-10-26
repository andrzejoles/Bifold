import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

// Poprawki z przeglądu: walidacja argumentów agenta, cele kopiowania, tytuły i historia kart,
// rozmiary katalogów, dostawcy tymczasowi.

private let agent = Invoker.agent(sessionID: "s", agentName: "test")

/// Komenda wywołana jak przez agenta (bez bramki uprawnień — sprawdzamy samą komendę).
@MainActor
private func runAsAgent(_ ws: Workspace, _ id: CommandID, _ args: [String: JSONValue] = [:]) async throws -> CommandResult {
    try await #require(ws.registry.command(id)).run(CommandContext(workspace: ws, invoker: agent, arguments: CommandArguments(args)))
}

/// Telefon (AFC/MTP) bez urządzenia: katalog `/DCIM` z jednym zdjęciem; `extract` kopiuje do katalogu tymczasowego.
private struct FakeDeviceFS: ExtractingProvider {
    let id: ProviderID
    let capabilities: ProviderCapabilities = [.read]
    var displayName: String { "telefon" }
    var root: VFSPath { VFSPath(provider: id, path: "/") }

    init(_ id: String = "device:test") { self.id = ProviderID(id) }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        [FileItem(path: directory.appending("IMG_0001.JPG"), kind: .file, size: 4)]
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: path.isRoot ? .directory : .file, size: 4) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data("jpeg".utf8) }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: "telefon", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: true, isInternal: false)
    }
    func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        let temp = directory.appending(".fake-device")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: true)
        let items = paths.map { temp.appending($0.name) }
        for item in items { try Data("jpeg".utf8).write(to: URL(filePath: item.path)) }
        return (temp, items)
    }
}

@MainActor @Suite struct ReviewFixTests {
    // MARK: 1. Podgląd pliku z telefonu

    @Test func materializeCopiesDeviceFileToLocalPath() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = FakeDeviceFS()
        ws.providers.register(device)
        let item = FileItem(path: device.root.appending("DCIM/IMG_0001.JPG"), kind: .file, size: 4)
        let local = try await ws.materialize(item)
        #expect(local.path.isLocal && local.name == "IMG_0001.JPG")
        #expect(try String(contentsOfFile: local.path.path, encoding: .utf8) == "jpeg")
        try? FileManager.default.removeItem(atPath: try #require(local.path.parent?.parent).path)
    }

    // MARK: 2. Liczby i ścieżki od agenta

    @Test(arguments: [
        ["owner": JSONValue.int(-1)], ["group": .int(Int64(UInt32.max) + 1)], ["owner": .int(Int64.min)],
    ])
    func attributeIDsOutOfRangeAreRejected(_ args: [String: JSONValue]) {
        #expect(throws: CommandError.self) { try attributeChange(from: CommandArguments(args)) }
        #expect((try? attributeChange(from: CommandArguments(["owner": .int(501), "group": .int(20)])))?.owner == 501)
    }

    @Test(arguments: ["/", "~/../.."])
    func renameOfRootIsRejected(_ path: String) async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        await #expect(throws: CommandError.self) {
            _ = try await ws.preview("file.rename", CommandArguments(["path": .string(path), "newName": "x"]), invoker: agent)
        }
        await #expect(throws: CommandError.self) {
            _ = try await runAsAgent(ws, "file.rename", ["path": .string(path), "newName": "x"])
        }
    }

    @Test(arguments: ["inf", "nan", "1e20", "-1"])
    func speedLimitTextMustBeFiniteAndInRange(_ text: String) async throws {
        let tmp = try TempDir()
        let (ws, ui) = try await makeWorkspace(tmp)
        ui.textAnswers = [text]
        await #expect(throws: CommandError.invalidArgument("bytesPerSecond", text)) {
            try await ws.invoke("queue.setSpeedLimit")
        }
    }

    @Test(.enabled(if: has7zz)) func archiveListWithNegativeLimitReturnsNoEntries() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        let (ws, _) = try await makeWorkspace(tmp)
        try await ws.invoke("archive.create", CommandArguments(["paths": .array([.string(tmp.url.path + "/a.txt")]), "destination": .string(tmp.url.path + "/p.zip")]))
        let result = try await runAsAgent(ws, "archive.list", ["path": .string(tmp.url.path + "/p.zip"), "limit": .int(-5)])
        #expect(result.value?["entries"]?.arrayValue?.isEmpty == true)
    }

    // MARK: 3. Karty-terminale a agent

    @Test func agentCannotCloseTerminalTab() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let term = ws.right.newTab(at: VFSPath(provider: RemoteFS.providerID("aix"), path: "/"))
        term.terminal = TerminalSpec(alias: "aix", executable: "/usr/bin/ssh", arguments: [])
        await #expect(throws: CommandError.self) { _ = try await runAsAgent(ws, "tab.close", ["side": "right"]) }
        #expect(ws.right.tabs.count == 2)
        // Użytkownik zamyka kartę-terminal.
        try await ws.invoke("tab.close", CommandArguments(["side": "right"]))
        #expect(ws.right.tabs.count == 1 && ws.right.activeTab.terminal == nil)
    }

    // MARK: 4. Cel kopiowania i rozpakowania w panelu, który nie jest dyskiem

    @Test func copyToResultsOrDevicePanelNeedsExplicitLocalDestination() async throws {
        let tmp = try TempDir()
        try tmp.file("L/plik.txt", "x")
        let (ws, _) = try await makeWorkspace(tmp, left: "L")
        ws.activeTab.quickSearch("plik")
        // Drugi panel: telefon w `/docs` — wewnętrzna ścieżka nie jest celem na dysku.
        let device = FakeDeviceFS()
        ws.providers.register(device)
        try await ws.right.activeTab.navigate(to: device.root.appending("docs"))
        await #expect(throws: CommandError.notAvailable("Katalog docelowy musi być lokalny")) {
            _ = try await runAsAgent(ws, "file.copy", ["wait": true])
        }
        await #expect(throws: CommandError.notAvailable("Katalog docelowy musi być lokalny")) {
            try await ws.invoke("file.copy", CommandArguments(["wait": true]))
        }
        // Jawny cel lokalny działa.
        try await ws.invoke("file.copy", CommandArguments(["destination": .string(tmp.url.path + "/R/"), "wait": true]))
        #expect(tmp.exists("R/plik.txt"))
    }

    @Test func copyFromDeviceIntoResultsPanelIsRefused() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = FakeDeviceFS()
        ws.providers.register(device)
        try await ws.left.activeTab.navigate(to: device.root.appending("DCIM"))
        try await ws.showResults(title: "x", items: [], side: .right)
        ws.activeSide = .left
        await #expect(throws: CommandError.notAvailable("Katalog docelowy musi być lokalny")) {
            _ = try await ws.preview("file.copy", .empty, invoker: agent)
        }
        await #expect(throws: CommandError.notAvailable("Katalog docelowy musi być lokalny")) {
            _ = try await runAsAgent(ws, "file.copy", ["wait": true])
        }
    }

    @Test func extractWithNonLocalOtherPanelIsRefusedForAgent() async throws {
        let tmp = try TempDir()
        try tmp.file("a.zip", "nie-zip")
        let (ws, _) = try await makeWorkspace(tmp)
        ws.activeTab.quickSearch("a.zip")
        let device = FakeDeviceFS()
        ws.providers.register(device)
        try await ws.right.activeTab.navigate(to: device.root.appending("tmp"))
        await #expect(throws: CommandError.notAvailable("Katalog docelowy musi być lokalny")) {
            _ = try await ws.preview("archive.extract", .empty, invoker: agent)
        }
        await #expect(throws: CommandError.notAvailable("Katalog docelowy musi być lokalny")) {
            _ = try await runAsAgent(ws, "archive.extract")
        }
    }

    // MARK: 5. Tytuł karty nadąża za dostawcą

    @Test func titleFollowsProviderWhenLeavingResults() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = try await ws.showResults(title: "raport", items: [])
        #expect(tab.title == "🔍 raport")
        try await ws.invoke("panel.home")
        #expect(ws.activeTab === tab && tab.path == ws.homePath)
        #expect(tab.title == ws.homePath.name)
        try await ws.invoke("panel.back")
        #expect(tab.title == "🔍 raport")
    }

    @Test func swapMovesWholeTabsBetweenMachines() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let server = FakeDeviceFS(RemoteFS.providerID("prod").rawValue)
        ws.providers.register(server)
        try await ws.left.activeTab.navigate(to: server.root.appending("var"))
        #expect(ws.left.activeTab.title == "🌐 prod")
        let remoteTab = ws.left.activeTab, localTab = ws.right.activeTab
        try await ws.invoke("panel.swap")
        #expect(ws.left.activeTab === localTab && ws.right.activeTab === remoteTab)
        #expect(ws.left.activeTab.path.isLocal && ws.left.activeTab.title == tmp.path.name)
        #expect(ws.right.activeTab.title == "🌐 prod")
    }

    // MARK: 6. Walidacja `side` i indeksów

    @Test func invalidSideAndIndexAreRejected() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        for id: CommandID in ["panel.switch", "tab.new", "tab.close"] {
            await #expect(throws: CommandError.invalidArgument("side", "left | right")) {
                try await ws.invoke(id, CommandArguments(["side": "srodek"]))
            }
        }
        await #expect(throws: CommandError.self) { try await ws.invoke("tab.select", CommandArguments(["index": 0, "side": "srodek"])) }
        await #expect(throws: CommandError.invalidArgument("index", "brak karty")) {
            try await ws.invoke("tab.close", CommandArguments(["index": 7]))
        }
        #expect(ws.activeSide == .left && ws.left.tabs.count == 1)
    }

    @Test func newTabWithMissingPathIsClosed() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let before = ws.activeTab
        await #expect(throws: (any Error).self) {
            try await ws.invoke("tab.new", CommandArguments(["path": .string(tmp.url.path + "/brak")]))
        }
        #expect(ws.left.tabs.count == 1 && ws.activeTab === before)
    }

    // MARK: 7. Rozmiary katalogów

    @Test func directorySizeOnlyForLocalAndCancelledOnClose() async throws {
        let tmp = try TempDir()
        for i in 0..<300 { try tmp.file("duzy/\(i)/a", "x") }
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = ws.activeTab
        tab.calculateSize(of: FileItem(path: VFSPath(provider: RemoteFS.providerID("prod"), path: "/var"), kind: .directory))
        #expect(tab.pendingSizeCount == 0)

        let extra = ws.left.newTab(at: tmp.path)
        try await extra.navigate(to: tmp.path)
        extra.calculateSize(of: FileItem(path: tmp.path.appending("duzy"), kind: .directory))
        #expect(extra.pendingSizeCount == 1)
        try await ws.invoke("tab.close")
        #expect(extra.pendingSizeCount == 0 && extra.directorySizes.isEmpty)
    }

    /// Powrót do katalogu i ponowne liczenie: anulowane wcześniejsze zadanie nie kasuje wpisu nowego.
    @Test func cancelledSizeTaskDoesNotDropNewerOne() async throws {
        let tmp = try TempDir()
        for i in 0..<300 { try tmp.file("A/duzy/\(i)/a", "x") }
        try tmp.dir("B")
        let (ws, _) = try await makeWorkspace(tmp, left: "A")
        let tab = ws.activeTab
        let dir = FileItem(path: tmp.path.appending("A/duzy"), kind: .directory)
        tab.calculateSize(of: dir)
        try await tab.navigate(to: tmp.path.appending("B"))
        #expect(tab.pendingSizeCount == 0)
        try await tab.navigate(to: tmp.path.appending("A"))
        tab.calculateSize(of: dir)
        #expect(tab.pendingSizeCount == 1)
        for _ in 0..<100 where tab.directorySizes[dir.path] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(tab.directorySizes[dir.path]?.files == 300 && tab.pendingSizeCount == 0)
    }

    // MARK: 8–9. Historia i błąd nawigacji

    @Test func failedBackKeepsHistoryIndexAndNoLoadError() async throws {
        let tmp = try TempDir()
        try tmp.dir("a")
        try tmp.dir("b")
        let (ws, _) = try await makeWorkspace(tmp, left: "a")
        let tab = ws.activeTab
        try await tab.navigate(to: tmp.path.appending("b"))
        let index = tab.historyIndex
        try FileManager.default.removeItem(at: tmp.url.appending(path: "a"))
        await #expect(throws: (any Error).self) { try await tab.goBack() }
        #expect(tab.path == tmp.path.appending("b") && tab.historyIndex == index && !tab.canGoForward)
        #expect(tab.loadError == nil)

        await #expect(throws: (any Error).self) { try await tab.navigate(to: tmp.path.appending("brak")) }
        #expect(tab.loadError == nil && tab.path == tmp.path.appending("b"))
    }

    // MARK: 10. Wyrejestrowanie wyników wyszukiwania

    @Test func resultsProviderIsUnregisteredWhenNoTabUsesIt() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = try await ws.showResults(title: "x", items: [])
        let root = tab.path
        try await ws.invoke("panel.home")
        // Wpis w historii karty — dostawca zostaje (Wstecz wraca do wyników).
        #expect((try? ws.providers.provider(for: root)) != nil)
        try await ws.invoke("tab.close")
        #expect((try? ws.providers.provider(for: root)) == nil)
    }
}
