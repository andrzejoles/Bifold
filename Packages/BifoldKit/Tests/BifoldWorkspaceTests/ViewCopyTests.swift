import BifoldCore
import Foundation
import Synchronization
import Testing
@testable import BifoldWorkspace

/// Telefon z plikiem `IMG_0001.JPG`, katalogiem `DCIM` i dowiązaniem do katalogu `Link`; liczy wywołania `extract`.
private final class CountingDeviceFS: ExtractingProvider, Sendable {
    let id = ProviderID("device:r5-view")
    let capabilities: ProviderCapabilities = [.read]
    let extractCalls = Atomic<Int>(0)
    var displayName: String { "telefon" }
    var root: VFSPath { VFSPath(provider: id, path: "/") }

    var file: FileItem { FileItem(path: root.appending("IMG_0001.JPG"), kind: .file, size: 4) }
    var directory: FileItem { FileItem(path: root.appending("DCIM"), kind: .directory) }
    var link: FileItem { FileItem(path: root.appending("Link"), kind: .symlink, flags: .symlinkToDirectory) }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] {
        directory.isRoot ? [file, self.directory, link] : []
    }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: path.isRoot ? .directory : .file, size: 4) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data("jpeg".utf8) }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: root, name: "telefon", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: true, isInternal: false)
    }
    func extract(_ paths: [VFSPath], toTemporaryIn directory: VFSPath, isCancelled: @escaping @Sendable () -> Bool) throws -> (temp: VFSPath, items: [VFSPath]) {
        extractCalls.add(1, ordering: .relaxed)
        let temp = directory.appending(".fake-device")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: true)
        let items = paths.map { temp.appending($0.name) }
        for item in items { try Data("jpeg".utf8).write(to: URL(filePath: item.path)) }
        return (temp, items)
    }
}

@MainActor @Suite struct ViewCopyTests {
    /// Kopia do podglądu (F3, Quick Look, Enter) z telefonu znika przy zamykaniu aplikacji (`saveSession`).
    @Test func viewCopyIsRemovedOnExit() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = CountingDeviceFS()
        ws.providers.register(device)
        let local = try await ws.materialize(device.file)
        let dir = try #require(local.path.parent?.parent)
        #expect(dir.name.hasPrefix("bifold-view-") && FileManager.default.fileExists(atPath: local.path.path))
        ws.saveSession()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// Kopia otwarta do edycji (F4) zostaje po zamknięciu — edytor może ją jeszcze trzymać.
    @Test func editCopySurvivesExit() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = CountingDeviceFS()
        ws.providers.register(device)
        let local = try await ws.materialize(device.file, removeOnExit: false)
        let dir = try #require(local.path.parent?.parent)
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        ws.saveSession()
        #expect(FileManager.default.fileExists(atPath: local.path.path))
    }

    /// Katalog ani dowiązanie do katalogu z telefonu nie są kopiowane do podglądu (całe drzewo bez limitu).
    @Test(arguments: [false, true])
    func navigableNonLocalItemIsNotMaterialized(_ symlink: Bool) async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = CountingDeviceFS()
        ws.providers.register(device)
        await #expect(throws: CommandError.self) { _ = try await ws.materialize(symlink ? device.link : device.directory) }
        #expect(device.extractCalls.load(ordering: .relaxed) == 0)
        #expect(ws.temporaryViewDirectories.isEmpty)
    }

    /// F3 na dowiązaniu do katalogu w telefonie nie pobiera drzewa.
    @Test func viewOnDeviceDirectoryLinkDoesNotCopy() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let device = CountingDeviceFS()
        ws.providers.register(device)
        try await ws.activeTab.navigate(to: device.root)
        ws.activeTab.cursor = device.link.path
        try await ws.invoke("file.view")
        #expect(device.extractCalls.load(ordering: .relaxed) == 0)
    }

    /// Przy starcie znikają tylko własne katalogi `bifold-view-…` starsze niż doba.
    @Test func staleViewCopiesAreRemovedAtStart() throws {
        let tmp = try TempDir()
        let old = Date().addingTimeInterval(-2 * 86_400)
        try tmp.file("bifold-view-stary/a.txt", "x")
        try tmp.file("bifold-view-nowy/a.txt", "x")
        try tmp.file("inny-stary/a.txt", "x")
        try tmp.file("bifold-view-plik", "x")
        for name in ["bifold-view-stary", "inny-stary", "bifold-view-plik"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: tmp.url.appending(path: name).path)
        }
        Workspace.removeStaleViewCopies(in: tmp.url)
        #expect(!tmp.exists("bifold-view-stary"))
        #expect(tmp.exists("bifold-view-nowy") && tmp.exists("inny-stary") && tmp.exists("bifold-view-plik"))
    }
}
