import BifoldCore
import Foundation
import Synchronization
import Testing
@testable import BifoldWorkspace

/// Dostawca do testów odświeżania i historii: `/k` ma listę `names` (zmienną w trakcie testu),
/// pozostałe katalogi — jeden plik; `slow` spowalnia każdy listing o 600 ms, a katalogi z `failing`
/// rzucają błąd wejścia-wyjścia (limit czasu, zerwane połączenie), nie „nie istnieje”.
private final class ReloadFS: FileSystemProvider, Sendable {
    let id: ProviderID
    let capabilities: ProviderCapabilities = [.read]
    let slow = Atomic<Bool>(false)
    let names = Mutex<[String]>((0..<10).map { "f\($0)" })
    let failing = Mutex<Set<String>>([])

    init(_ id: ProviderID = ProviderID("test:reload-r5")) { self.id = id }

    func path(_ p: String) -> VFSPath { VFSPath(provider: id, path: p) }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        // Treść ustalona na początku wczytania (jak listing katalogu przed późniejszą zmianą).
        let current = names.withLock { $0 }
        if slow.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(600)) }
        if failing.withLock({ $0.contains(directory.path) }) { throw VFSError.io(path: directory, code: ETIMEDOUT) }
        if directory.path == "/k" { return current.map { FileItem(path: directory.appending($0), kind: .file, size: 1) } }
        return [FileItem(path: directory.appending("w-" + directory.name), kind: .file, size: 1)]
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: .directory) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: VFSPath(provider: id, path: "/"), name: "r", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: false, isInternal: false)
    }
}

/// Telefon (prefiks `device:`) o nazwie modelu „Pixel”.
private struct TitleDeviceFS: ExtractingProvider {
    let id = ProviderID("device:r5-title")
    let capabilities: ProviderCapabilities = [.read]
    var displayName: String { "Pixel" }
    var root: VFSPath { VFSPath(provider: id, path: "/") }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        [FileItem(path: directory.appending("IMG_0001.JPG"), kind: .file, size: 4)]
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: path.isRoot ? .directory : .file, size: 4) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: "Pixel", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: true, isInternal: false)
    }
    func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        throw VFSError.unsupported("extract")
    }
}

@MainActor @Suite struct HistoryReloadTests {
    /// Kursor przesunięty przez użytkownika w trakcie (wolnego) odświeżenia zostaje tam, gdzie go przesunął.
    @Test func cursorMovedDuringReloadIsKept() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = ReloadFS()
        ws.providers.register(fs)
        let tab = ws.activeTab
        try await tab.navigate(to: fs.path("/k"))
        #expect(tab.cursorIndex == 1)
        fs.slow.store(true, ordering: .relaxed)
        let reload = Task { await tab.reload() }
        try await Task.sleep(for: .milliseconds(100))
        tab.moveCursor(to: 5)
        await reload.value
        #expect(tab.cursorIndex == 5)
    }

    /// Odświeżenie bez ruchu użytkownika nadal zachowuje kursor (po indeksie, gdy element zniknął).
    @Test func reloadStillRestoresCursorWithoutUserMove() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = ReloadFS()
        ws.providers.register(fs)
        let tab = ws.activeTab
        try await tab.navigate(to: fs.path("/k"))
        tab.moveCursor(to: 4)
        fs.names.withLock { $0.removeAll { $0 == "f3" } }
        await tab.reload()
        #expect(tab.cursorIndex == 4 && tab.cursorItem?.name == "f4")
    }

    /// Błąd inny niż „katalog nie istnieje” (limit czasu, zerwane połączenie) nie przenosi karty do katalogu
    /// nadrzędnego: ścieżka i historia bez zmian, komunikat w `loadError`.
    @Test func reloadIOErrorKeepsTabInPlace() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = ReloadFS()
        ws.providers.register(fs)
        let tab = ws.activeTab
        try await tab.navigate(to: fs.path("/x"))
        try await tab.navigate(to: fs.path("/x/y"))
        let history = tab.history, index = tab.historyIndex
        _ = fs.failing.withLock { $0.insert("/x/y") }
        await tab.reload()
        #expect(tab.path == fs.path("/x/y"))
        #expect(tab.history == history && tab.historyIndex == index)
        #expect(tab.loadError != nil)
    }

    /// Katalog, którego już nie ma, nadal przenosi kartę do pierwszego istniejącego przodka.
    @Test func reloadOfDeletedDirectoryClimbsUp() async throws {
        let tmp = try TempDir()
        try tmp.dir("a/b")
        let (ws, _) = try await makeWorkspace(tmp, left: "a/b")
        let tab = ws.activeTab
        try FileManager.default.removeItem(at: tmp.url.appending(path: "a/b"))
        await tab.reload()
        #expect(tab.path == tmp.path.appending("a"))
    }

    /// Brak dostawcy dla zapisanego aliasu serwera (np. po zapisie połączenia) nie jest martwym wpisem:
    /// Wstecz nie kasuje historii serwera.
    @Test func backDoesNotDropHistoryOfKnownServer() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        try ws.remotes.save(RemoteConnection(alias: "srv-r5", kind: .sftp, host: "127.0.0.1", user: "u"), secret: nil)
        let fs = ReloadFS(RemoteFS.providerID("srv-r5"))
        ws.providers.register(fs)
        let tab = ws.activeTab
        try await tab.navigate(to: fs.path("/a"))
        try await tab.navigate(to: fs.path("/b"))
        let history = tab.history
        ws.providers.unregister(fs.id)
        await #expect(throws: (any Error).self) { try await tab.goBack() }
        #expect(tab.history == history && tab.historyIndex == 2 && tab.path == fs.path("/b"))
    }

    /// Alias usunięty z Menedżera połączeń — wpisy są martwe i znikają (jak dotąd); `[tmp, a, tmp]` bez `a`
    /// to jeden wpis, więc nie ma dokąd wrócić (błąd martwego wpisu, karta na miejscu).
    @Test func backDropsHistoryOfUnknownServer() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = ReloadFS(RemoteFS.providerID("nieznany-r5"))
        ws.providers.register(fs)
        let tab = ws.activeTab
        try await tab.navigate(to: fs.path("/a"))
        try await tab.navigate(to: tmp.path)
        ws.providers.unregister(fs.id)
        await #expect(throws: VFSError.self) { try await tab.goBack() }
        #expect(tab.path == tmp.path && tab.history == [tmp.path] && tab.historyIndex == 0)
    }

    /// Odświeżenie, które przegrało z jawną nawigacją w tym samym katalogu (jej listing sprzed zmiany),
    /// wraca po jej zakończeniu: lista się odświeża, kursor z nawigacji zostaje.
    @Test func reloadSkippedByNavigationRunsAgainAfterIt() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let fs = ReloadFS()
        fs.names.withLock { $0 = ["a", "b"] }
        ws.providers.register(fs)
        let tab = ws.activeTab
        let dir = fs.path("/k")
        try await tab.navigate(to: dir)
        fs.slow.store(true, ordering: .relaxed)
        let navigation = Task { try await tab.navigate(to: dir, focus: "b", recordHistory: false) }
        try await Task.sleep(for: .milliseconds(100))
        fs.names.withLock { $0 = ["a", "b", "c"] }
        await tab.reload()
        fs.slow.store(false, ordering: .relaxed)
        try await navigation.value
        for _ in 0..<300 where !tab.items.contains(where: { $0.name == "c" }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tab.items.map(\.name) == ["a", "b", "c"])
        #expect(tab.cursorItem?.name == "b")
    }

    /// `[x, a, b, a]` po usunięciu `b`: Wstecz z `a` trafia do `x`, a nie do „tego samego” `a`.
    @Test func removingDeadEntryCollapsesAdjacentDuplicates() async throws {
        let tmp = try TempDir()
        for d in ["x", "a", "b"] { try tmp.dir(d) }
        let (ws, _) = try await makeWorkspace(tmp, left: "x")
        let tab = ws.activeTab
        let (x, a, b) = (tmp.path.appending("x"), tmp.path.appending("a"), tmp.path.appending("b"))
        try await tab.navigate(to: a)
        try await tab.navigate(to: b)
        try await tab.navigate(to: a)
        #expect(tab.history.suffix(4) == [x, a, b, a])
        let prefix = tab.history.count - 4
        try FileManager.default.removeItem(at: tmp.url.appending(path: "b"))
        try await tab.goBack()
        #expect(tab.path == x)
        #expect(Array(tab.history.dropFirst(prefix)) == [x, a] && tab.historyIndex == prefix)
        try await tab.goForward()
        #expect(tab.path == a && !tab.canGoForward)
    }

    /// Tytuł karty telefonu wynika z dostawcy: nowa karta i powrót przez historię dają „📱 Pixel”, nie „/”.
    @Test func deviceTabTitleComesFromProvider() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = TitleDeviceFS()
        ws.providers.register(device)
        let tab = ws.activePanel.newTab(at: device.root)
        #expect(tab.title == "📱 Pixel")
        try await tab.navigate(to: device.root)
        try await tab.navigate(to: tmp.path)
        #expect(tab.title == tmp.path.name)
        try await tab.goBack()
        #expect(tab.title == "📱 Pixel")
    }
}
