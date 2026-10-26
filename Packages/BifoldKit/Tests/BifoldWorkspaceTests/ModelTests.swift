import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

@MainActor @Suite struct TabTests {
    @Test func navigationSortFilterSelection() async throws {
        let tmp = try TempDir()
        try tmp.file("b.txt", "22")
        try tmp.file("a10.txt", "1")
        try tmp.file("a2.txt", "333")
        try tmp.file(".ukryty")
        try tmp.dir("Katalog")
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = ws.activeTab
        // „..”, potem katalogi, potem pliki w kolejności naturalnej (a2 przed a10).
        #expect(tab.visibleItems.map(\.name) == ["..", "Katalog", "a2.txt", "a10.txt", "b.txt"])
        #expect(tab.cursorItem?.name == "Katalog")

        tab.sort = SortSpec(field: .size, ascending: false)
        await tab.processNow()
        #expect(tab.visibleItems.map(\.name) == ["..", "Katalog", "a2.txt", "b.txt", "a10.txt"])

        tab.showHidden = true
        await tab.processNow()
        #expect(tab.visibleItems.contains { $0.name == ".ukryty" })

        tab.quickFilter = "a"
        await tab.processNow()
        #expect(tab.visibleItems.map(\.name).filter { $0 != ".." && $0 != "Katalog" }.sorted() == ["a10.txt", "a2.txt"])
        tab.quickFilter = "*.txt|b*"
        await tab.processNow()
        #expect(!tab.visibleItems.contains { $0.name == "b.txt" })
        tab.quickFilter = ""
        await tab.processNow()

        #expect(tab.select(mask: "a*.txt") == 2)
        #expect(tab.selectionSummary.count == 2 && tab.selectionSummary.bytes == 4)
        tab.invertSelection()
        #expect(tab.selectedItems.map(\.name).sorted() == [".ukryty", "b.txt"])
        tab.selectAll()
        #expect(tab.selection.count == 5)
        #expect(!tab.selection.contains(tmp.path.appending("..")))
    }

    @Test func goUpFocusesPreviousDirectoryAndHistory() async throws {
        let tmp = try TempDir()
        try tmp.dir("x/y")
        let (ws, _) = try await makeWorkspace(tmp, left: "x/y")
        let tab = ws.activeTab
        try await tab.goUp()
        #expect(tab.path == tmp.path.appending("x"))
        #expect(tab.cursorItem?.name == "y")
        try await tab.goBack()
        #expect(tab.path == tmp.path.appending("x/y"))
        try await tab.goForward()
        #expect(tab.path == tmp.path.appending("x"))
    }

    @Test func quickSearchJumps() async throws {
        let tmp = try TempDir()
        for n in ["alfa", "beta", "Żaba", "żółw"] { try tmp.file(n) }
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = ws.activeTab
        #expect(tab.quickSearch("be"))
        #expect(tab.cursorItem?.name == "beta")
        #expect(tab.quickSearch("za"))
        #expect(tab.cursorItem?.name == "Żaba")
        #expect(tab.quickSearch("z", startingAfterCursor: true))
        #expect(tab.cursorItem?.name == "żółw")
        #expect(!tab.quickSearch("qq"))
    }

    @Test func watcherReloadsAfterExternalChange() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        try await Task.sleep(for: .milliseconds(300))
        try tmp.file("pojawil-sie.txt")
        for _ in 0..<40 where !ws.activeTab.visibleItems.contains(where: { $0.name == "pojawil-sie.txt" }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ws.activeTab.visibleItems.contains { $0.name == "pojawil-sie.txt" })
    }

    @Test func directorySizeAndSortBySize() async throws {
        let tmp = try TempDir()
        try tmp.file("big/a", String(repeating: "x", count: 1000))
        try tmp.file("small/a", "x")
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = ws.activeTab
        for item in tab.visibleItems where item.isDirectory && !item.isParentLink { tab.calculateSize(of: item) }
        for _ in 0..<50 where tab.directorySizes.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(tab.directorySizes[tmp.path.appending("big")]?.bytes == 1000)
        tab.sort = SortSpec(field: .size, ascending: false)
        await tab.processNow()
        #expect(tab.visibleItems.map(\.name) == ["..", "big", "small"])
    }
}

/// Dostawca z wolnym katalogiem `/wolny` (wyścig nawigacji: późny listing nie może nadpisać nowszego).
private struct SlowFS: FileSystemProvider {
    let id = ProviderID("test:slow")
    let capabilities: ProviderCapabilities = [.read]
    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        if directory.path == "/wolny" { try await Task.sleep(for: .milliseconds(600)) }
        return [FileItem(path: directory.appending("w-" + directory.name), kind: .file, size: 1)]
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: .directory) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: VFSPath(provider: id, path: "/"), name: "slow", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: false, isInternal: false)
    }
}

@MainActor @Suite struct NavigationRaceTests {
    @Test func lateListingDoesNotOverwriteNewerNavigation() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        ws.providers.register(SlowFS())
        let tab = ws.activeTab
        let slow = VFSPath(provider: ProviderID("test:slow"), path: "/wolny")
        let fast = VFSPath(provider: ProviderID("test:slow"), path: "/szybki")
        let first = Task { try? await tab.navigate(to: slow) }
        try await Task.sleep(for: .milliseconds(100))
        try await tab.navigate(to: fast)
        await first.value
        #expect(tab.path == fast)
        #expect(tab.items.map(\.name).contains("w-szybki") && !tab.items.map(\.name).contains("w-wolny"))
        #expect(!tab.isLoading)
    }

    /// Odświeżenie (np. po zdarzeniu FSEvents) w trakcie jawnej nawigacji jej nie unieważnia.
    @Test func reloadDuringNavigationDoesNotCancelIt() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        ws.providers.register(SlowFS())
        let tab = ws.activeTab
        let slow = VFSPath(provider: ProviderID("test:slow"), path: "/wolny")
        let fast = VFSPath(provider: ProviderID("test:slow"), path: "/szybki")
        try await tab.navigate(to: fast)
        let navigation = Task { try await tab.navigate(to: slow) }
        try await Task.sleep(for: .milliseconds(100))
        await tab.reload()
        try await navigation.value
        #expect(tab.path == slow && tab.items.map(\.name) == ["w-wolny"])
        #expect(!tab.isLoading)
    }
}

@MainActor @Suite struct PanelAndSessionTests {
    /// Workspace bez cyklu referencji: po teście znika razem z obserwowaniem katalogów i katalogiem
    /// konfiguracji SSH (wcześniej karty porzuconych obiektów odświeżały w kółko $TMPDIR).
    @Test func workspaceIsReleasedWithItsSSHDirectory() async throws {
        let tmp = try TempDir()
        weak var released: Workspace?
        var sshDir = ""
        do {
            let (ws, _) = try await makeWorkspace(tmp)
            released = ws
            sshDir = try #require(ws.remotes.sshConfigFile.map { ($0 as NSString).deletingLastPathComponent })
            #expect(FileManager.default.fileExists(atPath: sshDir))
        }
        for _ in 0..<40 where released != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(released == nil)
        #expect(!FileManager.default.fileExists(atPath: sshDir))
    }

    /// Panel z samymi kartami-terminalami: w zapisie sesji katalog domowy, nie serwer z karty-terminala.
    @Test func sessionWithOnlyTerminalTabsFallsBackToHome() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let term = ws.right.newTab(at: VFSPath(provider: RemoteFS.providerID("aix"), path: "/"))
        term.terminal = TerminalSpec(alias: "aix", executable: "/usr/bin/ssh", arguments: [])
        #expect(ws.right.closeTab(at: 0) && ws.right.tabs.count == 1)
        let state = ws.right.snapshot(home: ws.homePath)
        #expect(state.tabs.map(\.path) == [ws.homePath] && state.activeTab == 0)
    }

    @Test func tabsOpenCloseAndPersist() async throws {
        let tmp = try TempDir()
        try tmp.dir("a")
        try tmp.dir("b")
        let paths = AppPaths(root: tmp.url.appending(path: "support"))
        do {
            let ws = Workspace(paths: paths, persists: true, home: tmp.path)
            await ws.start()
            try await ws.left.activeTab.navigate(to: tmp.path.appending("a"))
            let t = ws.left.newTab(at: tmp.path.appending("b"))
            try await t.navigate(to: tmp.path.appending("b"))
            t.viewMode = .thumbnails
            #expect(ws.left.tabs.count == 2 && ws.left.activeTabIndex == 1)
            ws.activeSide = .right
            ws.saveSession()
        }
        let restored = Workspace(paths: paths, persists: true, home: tmp.path)
        await restored.start()
        #expect(restored.left.tabs.map(\.path) == [tmp.path.appending("a"), tmp.path.appending("b")])
        #expect(restored.left.activeTabIndex == 1)
        #expect(restored.left.tabs[1].viewMode == .thumbnails)
        #expect(restored.activeSide == .right)
        #expect(!restored.left.closeTab(at: 5))
        #expect(restored.left.closeTab())
        #expect(!restored.left.closeTab())
    }

    @Test func missingDirectoryFallsBackToParent() async throws {
        let tmp = try TempDir()
        try tmp.dir("gone/deeper")
        let paths = AppPaths(root: tmp.url.appending(path: "support"))
        do {
            let ws = Workspace(paths: paths, persists: true, home: tmp.path)
            try await ws.left.activeTab.navigate(to: tmp.path.appending("gone/deeper"))
            ws.saveSession()
        }
        try FileManager.default.removeItem(at: tmp.url.appending(path: "gone"))
        let ws = Workspace(paths: paths, persists: true, home: tmp.path)
        await ws.start()
        #expect(ws.left.activeTab.path == tmp.path)
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"showHiddenFiles": true}"#.utf8))
        #expect(s.showHiddenFiles)
        #expect(s.editorBundleID == "org.nextpadplusplus.mac")
        #expect(s.agent.maxReadBytes == 2 * 1024 * 1024)
        #expect(s.agent.blockedPaths.contains("~/.ssh"))
    }
}

@Suite struct PerformanceTests {
    /// 100 000 elementów: sortowanie i filtrowanie muszą zmieścić się z zapasem w budżecie 1 s.
    @Test func sortHundredThousandItems() {
        let dir = VFSPath.local("/perf")
        let items = (0..<100_000).map { i in
            FileItem(path: dir.appending("plik-\(i % 977)-\(i).txt"), kind: i % 50 == 0 ? .directory : .file, size: Int64(i), modified: Date(timeIntervalSince1970: Double(i)))
        }.shuffled()
        let start = ContinuousClock.now
        let sorted = ListingProcessor.process(items, in: dir, options: .init())
        let elapsed = ContinuousClock.now - start
        #expect(sorted.count == 100_001)
        #expect(elapsed < .milliseconds(700), "sortowanie: \(elapsed)")
        let t2 = ContinuousClock.now
        _ = ListingProcessor.process(items, in: dir, options: .init(sort: SortSpec(field: .modified, ascending: false), filter: "77"))
        #expect(ContinuousClock.now - t2 < .milliseconds(500))
    }

    /// Prawdziwy katalog ze 100 000 plików: listowanie + sortowanie poniżej 1 s.
    /// Tworzenie i usuwanie plików poza MainActor — inaczej przez ~minutę stały wszystkie testy MainActor.
    @MainActor @Test func listHundredThousandFiles() async throws {
        let tmp = try TempDir()
        let base = tmp.url.path
        await Task.detached(priority: .userInitiated) {
            for i in 0..<100_000 {
                let fd = open(base + "/plik-\(i).dat", O_CREAT | O_WRONLY, 0o644)
                close(fd)
            }
        }.value
        let (ws, _) = try await makeWorkspace(tmp)
        let tab = ws.activeTab
        let t0 = ContinuousClock.now
        let listed = try LocalFS().listSync(tmp.path)
        let t1 = ContinuousClock.now
        _ = ListingProcessor.process(listed, in: tmp.path, options: .init())
        let t2 = ContinuousClock.now
        try await tab.navigate(to: tmp.path)
        let elapsed = ContinuousClock.now - t2
        #expect(tab.visibleItems.count == 100_001)
        // Kryterium odbioru (1 s) sprawdzane ściśle w `make test-release` (BIFOLD_PERF_STRICT=1);
        // w zwykłym przebiegu debug inne zestawy testów działają równolegle i zabierają CPU.
        let strict = ProcessInfo.processInfo.environment["BIFOLD_PERF_STRICT"] == "1"
        #expect(elapsed < .seconds(strict ? 1 : 3), "pierwsze wyświetlenie: \(elapsed)")
        print("100k: listowanie \(t1 - t0), sortowanie \(t2 - t1), razem w karcie \(elapsed)")
        // Sprzątanie też w tle (`TempDir.deinit` usuwałby 100 000 plików na MainActor).
        let url = tmp.url
        await Task.detached(priority: .userInitiated) { try? FileManager.default.removeItem(at: url) }.value
    }
}
