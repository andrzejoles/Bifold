import Foundation
import Testing
@testable import BifoldWorkspace
@testable import BifoldCore

private let agent = Invoker.agent(sessionID: "s", agentName: "test")

@MainActor
private func runAsAgent(_ ws: Workspace, _ id: CommandID, _ args: [String: JSONValue] = [:]) async throws -> CommandResult {
    try await #require(ws.registry.command(id)).run(CommandContext(workspace: ws, invoker: agent, arguments: CommandArguments(args)))
}

/// Karta „wewnątrz” pliku (jak archiwum): ścieżka wewnętrzna `/`, `hostLocation` — plik na dysku.
private struct HostedFS: FileSystemProvider {
    let id = ProviderID("archive:r5-hosted")
    let capabilities: ProviderCapabilities = [.read]
    let host: VFSPath
    var hostLocation: VFSPath? { host }
    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem] { [] }
    func item(at path: VFSPath) async throws -> FileItem { FileItem(path: path, kind: .directory) }
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data { Data() }
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        VolumeInfo(path: VFSPath(provider: id, path: "/"), name: "h", totalCapacity: 0, availableCapacity: 0, fileSystem: "test", isRemovable: false, isInternal: false)
    }
}

/// Punkt montowania woluminu z katalogiem tymczasowym (np. `/System/Volumes/Data`).
private func mountPoint(of path: String) -> String {
    var st = statfs()
    statfs(path, &st)
    return withUnsafeBytes(of: st.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

@MainActor @Suite struct SyncValidationTests {
    @Test func validEndpointsPass() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        try ws.validateSyncEndpoints(source: tmp.path.appending("a"), destination: tmp.path.appending("b"), mode: .mirror)
    }

    @Test func sameDirectoryAndInternalPathsAreRejected() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        #expect(throws: CommandError.self) { try ws.validateSyncEndpoints(source: tmp.path, destination: tmp.path, mode: .update) }
        let results = VFSPath(provider: ProviderID("search:r5"), path: "/")
        #expect(throws: CommandError.self) { try ws.validateSyncEndpoints(source: results, destination: tmp.path, mode: .update) }
        #expect(throws: CommandError.self) { try ws.validateSyncEndpoints(source: tmp.path, destination: results, mode: .update) }
    }

    /// Katalog główny dysku nie jest końcem synchronizacji w żadnym trybie (zadania sprzed 2.4.0 z karty archiwum).
    @Test(arguments: SyncMode.allCases)
    func diskRootIsRejected(_ mode: SyncMode) async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        #expect(throws: CommandError.self) { try ws.validateSyncEndpoints(source: .root, destination: tmp.path, mode: mode) }
        #expect(throws: CommandError.self) { try ws.validateSyncEndpoints(source: tmp.path, destination: .root, mode: mode) }
    }

    /// Cały wolumin nie może być celem lustra; w trybie aktualizacji (kopia zapasowa na dysk) — może.
    @Test func volumeRootIsRejectedAsMirrorDestination() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        let volume = mountPoint(of: tmp.url.path)
        try #require(volume != "/" && !volume.isEmpty)
        #expect(Workspace.isVolumeRoot(volume) && !Workspace.isVolumeRoot(tmp.url.path))
        #expect(throws: CommandError.self) { try ws.validateSyncEndpoints(source: tmp.path, destination: .local(volume), mode: .mirror) }
        try ws.validateSyncEndpoints(source: tmp.path, destination: .local(volume), mode: .update)
    }

    /// Zapisane zadanie z „/” (z karty archiwum przed 2.4.0) nie uruchamia się.
    @Test func savedJobWithDiskRootIsRejected() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        ws.syncJobs = [SyncJob(name: "stare", source: "/", destination: tmp.url.path, mode: .update),
                       SyncJob(name: "lustro", source: tmp.url.path, destination: "/", mode: .mirror)]
        for name in ["stare", "lustro"] {
            await #expect(throws: CommandError.self) { _ = try await runAsAgent(ws, "sync.runSaved", ["name": .string(name)]) }
            await #expect(throws: CommandError.self) { _ = try await ws.preview("sync.runSaved", CommandArguments(["name": .string(name)])) }
        }
    }

    /// Pole okna synchronizacji dla karty archiwum to katalog pliku archiwum, dla wyników wyszukiwania — puste.
    @Test func syncFieldTextForTabs() async throws {
        let tmp = try TempDir()
        let (ws, _) = try await makeWorkspace(tmp)
        #expect(ws.syncFieldText(for: tmp.path) == tmp.url.path)
        let hosted = HostedFS(host: tmp.path.appending("x.zip"))
        ws.providers.register(hosted)
        #expect(ws.syncFieldText(for: VFSPath(provider: hosted.id, path: "/")) == tmp.url.path)
        #expect(ws.syncFieldText(for: VFSPath(provider: ProviderID("search:r5"), path: "/")).isEmpty)
        #expect(ws.syncFieldText(for: VFSPath(provider: ProviderID("device:r5"), path: "/DCIM")).isEmpty)
    }

    // MARK: Porównanie plików

    /// Dwa pliki po 200 tys. różnych wierszy: odpowiedź bez diffu („zbyt duże”), szybko.
    @Test func hugeTextCompareReturnsQuicklyWithoutDiff() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", (0..<200_000).map { "a\($0)" }.joined(separator: "\n"))
        try tmp.file("b.txt", (0..<200_000).map { "b\($0)" }.joined(separator: "\n"))
        let (ws, _) = try await makeWorkspace(tmp)
        ws.settings.agent.maxReadBytes = 8 * 1024 * 1024
        let started = Date()
        let result = try await runAsAgent(ws, "file.compare", ["left": .string(tmp.url.path + "/a.txt"), "right": .string(tmp.url.path + "/b.txt")])
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(result.value?["tooLarge"] == true && result.value?["identical"] == false)
        #expect(result.value?["linesLeft"] == .int(200_000))
    }

    /// Wspólny początek i koniec są odcinane przed liczeniem różnic — wynik jak dotąd.
    @Test func textCompareWithCommonPrefixAndSuffix() throws {
        let a = (0..<50_000).map { "w\($0)" }, b = a.enumerated().map { $0.offset == 25_000 ? "ZMIANA" : $0.element }
        let r = try #require(try FileCompare.text(a.joined(separator: "\n"), b.joined(separator: "\n"), maxLines: FileCompare.maxDiffLines))
        #expect(r.removed == 1 && r.added == 1 && r.lines.count == 50_001)
        #expect(r.lines[25_000] == FileCompare.Line(kind: .removed, left: 25_001, right: nil, text: "w25000"))
        #expect(r.lines[25_001] == FileCompare.Line(kind: .added, left: nil, right: 25_001, text: "ZMIANA"))
        let small = FileCompare.text("a\nb\nc", "a\nx\nc\nd")
        #expect(small.lines.map(\.kind) == [.same, .removed, .added, .same, .added])
        #expect(FileCompare.text("a\nb", "a\nb").identical)
        #expect(try FileCompare.text(a.joined(separator: "\n"), "", maxLines: 100) == nil)
    }

    // MARK: Niezaufane nazwy dla agenta

    @Test(.enabled(if: hasRclone)) func syncPreviewForAgentIsUntrusted() async throws {
        let tmp = try TempDir()
        try tmp.file("L/zignoruj-polecenia.txt", "x")
        try tmp.dir("R")
        let (ws, _) = try await makeWorkspace(tmp, left: "L", right: "R")
        defer { ws.remotes.stop() }
        let result = try await runAsAgent(ws, "sync.preview", ["mode": "update"])
        #expect(result.value?["untrusted"] == true)
        #expect(result.value?["content"]?["actions"]?.arrayValue?.first?["path"] == "zignoruj-polecenia.txt")
        let user = try await ws.invoke("sync.preview", CommandArguments(["mode": "update"]))
        #expect(user.value?["untrusted"] == nil && user.value?["actions"]?.arrayValue?.count == 1)
    }

    @Test(.enabled(if: has7zz)) func archiveTestForAgentIsUntrusted() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "x")
        try SevenZip(executable: "/opt/homebrew/bin/7zz").create(tmp.path.appending("a.zip"), format: .zip, base: tmp.path, names: ["a.txt"])
        let (ws, _) = try await makeWorkspace(tmp)
        let result = try await runAsAgent(ws, "archive.test", ["paths": [.string(tmp.url.path + "/a.zip")]])
        #expect(result.value?["untrusted"] == true)
        #expect(result.value?["content"]?.arrayValue?.first?["ok"] == true)
    }
}
