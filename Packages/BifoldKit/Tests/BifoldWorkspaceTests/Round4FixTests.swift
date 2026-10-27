import BifoldCore
import Foundation
import Synchronization
import Testing
@testable import BifoldWorkspace

// Poprawki z czwartej rundy przeglądu: martwe wpisy historii, tytuły kart, ⌃U z kartą-terminalem,
// synchronizacja kart bez katalogu lokalnego, filtrowanie wyników dla agenta, podgląd z telefonu.

private let agent = Invoker.agent(sessionID: "s", agentName: "test")

@MainActor
private func runAsAgent(_ ws: Workspace, _ id: CommandID, _ args: [String: JSONValue] = [:]) async throws -> CommandResult {
    try await #require(ws.registry.command(id)).run(CommandContext(workspace: ws, invoker: agent, arguments: CommandArguments(args)))
}

/// Dostawca, którego katalog `/zniknal` po ustawieniu `gone` przestaje istnieć (po opóźnieniu `delay`),
/// a `/wolny` wczytuje się 600 ms.
private final class VanishingFS: FileSystemProvider, Sendable {
    let id: ProviderID
    let capabilities: ProviderCapabilities = [.read]
    let gone = Atomic<Bool>(false)
    let delayMilliseconds = Atomic<Int>(0)

    init(_ id: String = "test:vanishing") { self.id = ProviderID(id) }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        if directory.path == "/wolny" { try await Task.sleep(for: .milliseconds(600)) }
        if directory.path == "/zniknal" {
            let delay = delayMilliseconds.load(ordering: .relaxed)
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            if gone.load(ordering: .relaxed) { throw VFSError.notFound(directory) }
        }
        return [FileItem(path: directory.appending("w-" + directory.name), kind: .file, size: 1)]
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: .directory) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: VFSPath(provider: id, path: "/"), name: "v", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: false, isInternal: false)
    }
}

/// Wyniki wyszukiwania (prefiks `search:`) z katalogiem na wolnym dostawcy.
private struct SlowResultsFS: FileSystemProvider {
    let id = ProviderID("search:slow-r4")
    let capabilities: ProviderCapabilities = [.read]
    let item: FileItem
    var root: VFSPath { VFSPath(provider: id, path: "/") }
    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] { [item] }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: .directory) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: "w", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: false, isInternal: false)
    }
}

/// Telefon, którego kopiowanie się nie udaje (`fail`) albo trwa, dopóki nie zostanie anulowane.
private final class StuckDeviceFS: ExtractingProvider, Sendable {
    let id = ProviderID("device:stuck")
    let capabilities: ProviderCapabilities = [.read]
    let fail: Bool
    let directory = Mutex<VFSPath?>(nil)
    let sawCancel = Atomic<Bool>(false)
    var displayName: String { "telefon" }
    var root: VFSPath { VFSPath(provider: id, path: "/") }

    init(fail: Bool) { self.fail = fail }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        [FileItem(path: directory.appending("IMG_0001.JPG"), kind: .file, size: 4)]
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: path.isRoot ? .directory : .file, size: 4) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: "telefon", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: true, isInternal: false)
    }
    func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        self.directory.withLock { $0 = directory }
        // Częściowa kopia w katalogu tymczasowym — musi zniknąć razem z nim.
        FileManager.default.createFile(atPath: directory.path + "/czesc", contents: Data("x".utf8))
        if fail { throw VFSError.io(path: paths[0], code: EIO) }
        let deadline = Date().addingTimeInterval(5)
        while !isCancelled(), Date() < deadline { usleep(10_000) }
        sawCancel.store(isCancelled(), ordering: .relaxed)
        throw VFSError.cancelled
    }
}

@MainActor @Suite struct Round4FixTests {
    // MARK: 1. Martwe wpisy historii

    @Test func backSkipsDeletedHistoryEntry() async throws {
        let tmp = try TempDir()
        for d in ["a", "b", "c"] { try tmp.dir(d) }
        let (ws, _) = try await makeWorkspace(tmp, left: "a")
        let tab = ws.activeTab
        let (a, b, c) = (tmp.path.appending("a"), tmp.path.appending("b"), tmp.path.appending("c"))
        try await tab.navigate(to: b)
        try await tab.navigate(to: c)
        try FileManager.default.removeItem(at: tmp.url.appending(path: "b"))
        try await tab.goBack()
        #expect(tab.path == a)
        #expect(tab.history == [a, c] && tab.historyIndex == 0 && !tab.canGoBack)
        try await tab.goForward()
        #expect(tab.path == c && tab.historyIndex == 1)
    }

    @Test func forwardSkipsEntryOfUnregisteredProvider() async throws {
        let tmp = try TempDir()
        try tmp.dir("a")
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = VanishingFS()
        ws.providers.register(fs)
        let tab = ws.activeTab
        let remote = VFSPath(provider: fs.id, path: "/x")
        let a = tmp.path.appending("a")
        try await tab.navigate(to: remote)
        try await tab.navigate(to: a)
        try await tab.goBack()
        try await tab.goBack()
        #expect(tab.path == tmp.path)
        // Rozłączony serwer: dostawca wyrejestrowany — Dalej przeskakuje jego wpis.
        ws.providers.unregister(fs.id)
        try await tab.goForward()
        #expect(tab.path == a)
        #expect(!tab.history.contains(remote) && !tab.canGoForward && tab.canGoBack)
    }

    /// Nowsza nawigacja wygrała z nieudanym Wstecz — historia i indeks bez zmian (D47).
    @Test func failedBackOvertakenByNewerNavigationKeepsHistory() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = VanishingFS()
        ws.providers.register(fs)
        let tab = ws.activeTab
        let dead = VFSPath(provider: fs.id, path: "/zniknal")
        let other = VFSPath(provider: fs.id, path: "/inny")
        try await tab.navigate(to: dead)
        try await tab.navigate(to: other)
        let history = tab.history
        fs.gone.store(true, ordering: .relaxed)
        fs.delayMilliseconds.store(400, ordering: .relaxed)
        let back = Task { try await tab.goBack() }
        try await Task.sleep(for: .milliseconds(100))
        try await tab.navigate(to: tmp.path, recordHistory: false)
        try await back.value
        #expect(tab.path == tmp.path)
        #expect(tab.history == history && tab.historyIndex == history.count - 1)
    }

    // MARK: 6–7. Tytuły kart

    /// Nowsza nawigacja (do innych wyników) wygrała z wejściem do katalogu z wyników — tytuł zostaje „🔍 inne”
    /// (wcześniej `panel.open` zerował go po nawigacji, której wynik pominięto).
    @Test func openFromResultsDoesNotClearTitleOfNewerNavigation() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let slowFS = VanishingFS("test:slow-r4")
        let slow = VFSPath(provider: slowFS.id, path: "/wolny")
        let results = SlowResultsFS(item: FileItem(path: slow, kind: .directory))
        ws.providers.register(slowFS)
        ws.providers.register(results)
        let tab = ws.activeTab
        try await tab.navigate(to: results.root)
        tab.customTitle = "🔍 wyniki"
        #expect(tab.isSearchResults && tab.cursorItem?.path == slow)
        let open = Task { _ = try await ws.invoke("panel.open") }
        try await Task.sleep(for: .milliseconds(100))
        let other = SearchResultsFS(title: "inne", items: [])
        ws.providers.register(other)
        try await tab.navigate(to: other.root)
        try await open.value
        #expect(tab.path == other.root && tab.title == "🔍 inne")
    }

    @Test func remoteTabTitleComesFromPath() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = ws.right.newTab(at: VFSPath(provider: RemoteFS.providerID("nas"), path: "/"))
        #expect(tab.title == "🌐 nas")
    }

    // MARK: 8. ⌃U z kartą-terminalem

    @Test func swapMovesTerminalTabButNotForAgent() async throws {
        let tmp = try TempDir()
        try tmp.dir("L")
        let (ws, _) = try await makeWorkspace(tmp, left: "L")
        let local = ws.left.activeTab
        let term = ws.right.newTab(at: VFSPath(provider: RemoteFS.providerID("aix"), path: "/"))
        term.terminal = TerminalSpec(alias: "aix", executable: "/usr/bin/ssh", arguments: [])
        term.customTitle = "⌨ aix"
        await #expect(throws: CommandError.self) { _ = try await runAsAgent(ws, "panel.swap") }
        #expect(ws.left.activeTab === local)
        try await ws.invoke("panel.swap")
        #expect(ws.left.activeTab === term && ws.right.activeTab === local)
        #expect(term.title == "⌨ aix" && term.terminal != nil && local.path == tmp.path.appending("L"))
        #expect(ws.registry.command("panel.swap")?.descriptor.summary == "Zamienia aktywne karty obu paneli.")
    }

    // MARK: 2. Zapis zadania synchronizacji z karty bez katalogu lokalnego

    @Test func syncSaveRejectsInternalPathsAndListShowsExclude() async throws {
        let tmp = try TempDir()
        try tmp.dir("a")
        try tmp.dir("b")
        let (ws, _) = try await makeWorkspace(tmp, left: "a", right: "b")
        // Karta wyników: ścieżka wewnętrzna `/` zapisana tekstem oznaczałaby cały dysk.
        let results = try await ws.showResults(title: "x", items: [], side: .left)
        #expect(ws.activeTab === results)
        await #expect(throws: CommandError.self) {
            try await ws.invoke("sync.save", CommandArguments(["name": "zle", "mode": "mirror"]))
        }
        #expect(ws.syncJobs.isEmpty)
        try await ws.invoke("tab.close")
        try await ws.invoke("sync.save", CommandArguments(["name": "ok", "mode": "update", "exclude": ["tmp/x"]]))
        let listed = try await ws.invoke("sync.listSaved")
        let job = try #require(listed.value?.arrayValue?.first)
        #expect(job["source"]?.stringValue == tmp.url.path + "/a" && job["exclude"]?.arrayValue == [.string("tmp/x")])
    }

    @Test func oldSyncJobsFileWithoutExcludeIsRead() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        try FileManager.default.createDirectory(at: ws.paths.root, withIntermediateDirectories: true)
        try Data(#"[{"name":"stare","source":"/a","destination":"nas:/b","mode":"mirror"}]"#.utf8).write(to: ws.syncJobsURL)
        #expect(ws.syncJobs == [SyncJob(name: "stare", source: "/a", destination: "nas:/b", mode: .mirror, exclude: [])])
    }

    // MARK: 4, 9. Porównanie katalogów dla agenta

    @Test func compareDirsHidesBlockedFilesFromAgent() async throws {
        let tmp = try TempDir()
        try tmp.file("L/.netrc", "TAJNE")
        try tmp.file("L/a.txt", "a")
        try tmp.file("R/.netrc", "TAJNE")
        try tmp.dir("R")
        let (ws, _) = try await makeWorkspace(tmp, left: "L", right: "R")
        ws.settings.agent.blockedPaths = [tmp.url.path + "/L/.netrc", tmp.url.path + "/R/.netrc"]
        let result = try await runAsAgent(ws, "dirs.compare", ["byContent": true])
        #expect(result.value?["untrusted"] == true && result.value?["notice"] != nil)
        let content = try #require(result.value?["content"])
        #expect(content["onlyLeft"]?.arrayValue == [.string("a.txt")])
        #expect(content["identical"] == .int(0) && content["different"]?.arrayValue?.isEmpty == true)
        #expect(!(result.value?.description.contains(".netrc") ?? true))
        #expect(ws.left.activeTab.selectedItems.map(\.name) == ["a.txt"])
        // Użytkownik widzi wszystko (bez opakowania).
        try await ws.invoke("dirs.compare", CommandArguments(["byContent": true]))
        #expect(ws.left.activeTab.selectedItems.map(\.name) == ["a.txt"])
    }

    // MARK: 5, 9. Plik sum wskazujący zablokowane pliki

    @Test func checksumVerifyDoesNotRevealBlockedEntries() async throws {
        let tmp = try TempDir()
        try tmp.file(".ssh/id_ed25519", "KLUCZ")
        try tmp.file("a.txt", "a")
        let sums = Checksums.format([
            (hash: try Checksums.hash(tmp.path.appending(".ssh/id_ed25519"), algorithm: .sha256), relativePath: ".ssh/id_ed25519"),
            (hash: String(repeating: "0", count: 64), relativePath: ".ssh/brak"),
            (hash: try Checksums.hash(tmp.path.appending("a.txt"), algorithm: .sha256), relativePath: "a.txt"),
        ])
        try tmp.file("sumy.sha256", sums)
        let (ws, _) = try await makeWorkspace(tmp)
        ws.settings.agent.blockedPaths = [tmp.url.path + "/.ssh"]
        let result = try await runAsAgent(ws, "file.checksumVerify", ["paths": [.string(tmp.url.path + "/sumy.sha256")]])
        #expect(result.value?["untrusted"] == true)
        let statuses = Dictionary(uniqueKeysWithValues: (result.value?["content"]?.arrayValue ?? []).compactMap { e in
            e["path"]?.stringValue.map { ($0, e["status"]?.stringValue ?? "") }
        })
        #expect(statuses == [".ssh/id_ed25519": "invalid", ".ssh/brak": "invalid", "a.txt": "ok"])
        // Użytkownik: prawdziwy wynik.
        let user = try await ws.invoke("file.checksumVerify", CommandArguments(["paths": [.string(tmp.url.path + "/sumy.sha256")]]))
        #expect(user.value?.arrayValue?.first?["status"] == "ok")
    }

    // MARK: 10. Podgląd z telefonu: sprzątanie i anulowanie

    @Test func failedDeviceMaterializeRemovesTemporaryDirectory() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = StuckDeviceFS(fail: true)
        ws.providers.register(device)
        let item = FileItem(path: device.root.appending("IMG_0001.JPG"), kind: .file, size: 4)
        await #expect(throws: VFSError.self) { _ = try await ws.materialize(item) }
        let dir = try #require(device.directory.withLock { $0 })
        #expect(dir.path.contains("bifold-view-") && !FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func deviceMaterializeCanBeCancelled() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = StuckDeviceFS(fail: false)
        ws.providers.register(device)
        let item = FileItem(path: device.root.appending("IMG_0001.JPG"), kind: .file, size: 4)
        let task = Task { try await ws.materialize(item) }
        for _ in 0..<200 where device.directory.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let sawCancel = device.sawCancel.load(ordering: .relaxed)
        #expect(sawCancel)
        let dir = try #require(device.directory.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: 11. Podgląd kopiowania z telefonu

    @Test func copyPreviewFromDeviceMentionsDevice() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = StuckDeviceFS(fail: true)
        ws.providers.register(device)
        try await ws.activeTab.navigate(to: device.root)
        ws.activeTab.cursor = device.root.appending("IMG_0001.JPG")
        let preview = try await ws.preview("file.copy")
        #expect(preview.summary.hasPrefix("Kopiowanie z urządzenia"), "\(preview.summary)")
    }

    // MARK: 14. processNow czeka na nowsze przeliczenie

    @Test func processNowWaitsForNewerReprocess() async throws {
        let tmp = try TempDir()
        for i in 0..<300 { try tmp.file("a\(i).txt") }
        try tmp.file("b.txt")
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = ws.activeTab
        let waiting = Task { await tab.processNow() }
        await Task.yield()
        tab.quickFilter = "b"
        await waiting.value
        #expect(tab.visibleItems.map(\.name).filter { $0 != ".." } == ["b.txt"])
    }
}

/// Dostawca do wyścigu kursora (D47): lista po `ready` ma 60 000 elementów gotowych od razu (przeliczenie
/// trwa dłużej niż wczytanie), a po `ready` `volumeInfo` jest wolne dla nawigacji i szybkie dla
/// odświeżenia (wartość zadania `fastVolume`) — kolejność wznowień po wspólnym przeliczeniu nie ma znaczenia.
private final class CursorRaceFS: FileSystemProvider, Sendable {
    let id = ProviderID("test:cursor-race")
    let capabilities: ProviderCapabilities = [.read]
    let ready = Atomic<Bool>(false)
    @TaskLocal static var fastVolume = false
    let directory: VFSPath
    let items: [FileItem]

    init() {
        let dir = VFSPath(provider: ProviderID("test:cursor-race"), path: "/katalog")
        directory = dir
        items = [FileItem(path: dir.appending("nowy"), kind: .directory)]
            + (0..<60_000).map { FileItem(path: dir.appending("plik-\($0)"), kind: .file, size: 1) }
    }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        ready.load(ordering: .relaxed) ? items : []
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: .directory) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        if ready.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(Self.fastVolume ? 30 : 400)) }
        return VolumeInfo(path: VFSPath(provider: id, path: "/"), name: "r", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: false, isInternal: false)
    }
}

@MainActor @Suite struct NavigateWhitespaceTests {
    /// Katalog z odstępem na końcu nazwy jest osiągalny przez `panel.navigate` (drzewo, pasek ścieżki);
    /// spacje obcinane tylko, gdy ścieżka dosłowna nie istnieje.
    @Test func trailingSpaceDirectoryIsReachable() async throws {
        let tmp = try TempDir()
        try tmp.dir("Projekt ")
        try tmp.dir("Inny")
        let (ws, _) = try await makeWorkspace(tmp)
        try await ws.invoke("panel.navigate", CommandArguments(["path": .string(tmp.url.path + "/Projekt ")]))
        #expect(ws.activeTab.path.name == "Projekt ")
        try await ws.invoke("panel.navigate", CommandArguments(["path": .string("  " + tmp.url.path + "/Inny  ")]))
        #expect(ws.activeTab.path.name == "Inny")
    }
}

@MainActor @Suite struct CursorRaceTests {
    /// Odświeżenie rozpoczęte, gdy jawna nawigacja (F7 z fokusem) czeka na przeliczenie listy, wznawia
    /// się przed nią i czeka na swoje `volumeInfo`; po nim nie może przywrócić kursora sprzed nawigacji („..”).
    @Test func reloadResumingFirstDoesNotRestoreCursorOverFocusedNavigation() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = CursorRaceFS()
        ws.providers.register(fs)
        let tab = ws.activeTab
        let dir = fs.directory
        try await tab.navigate(to: dir)
        #expect(tab.cursorItem?.isParentLink == true)
        fs.ready.store(true, ordering: .relaxed)
        let navigation = Task { try await tab.navigate(to: dir, focus: "nowy", recordHistory: false) }
        // Odświeżenie startuje, gdy nawigacja ma już listę i przelicza ją (jak zdarzenie FSEvents po F7).
        for _ in 0..<500 where tab.items.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        await CursorRaceFS.$fastVolume.withValue(true) { await tab.reload() }
        try await navigation.value
        #expect(tab.cursorItem?.name == "nowy")
    }
}
