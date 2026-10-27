import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

// Czwarta runda przeglądu: tytuł karty archiwum, wyrejestrowanie dostawcy archiwum, untrusted w archive.list.

@MainActor @Suite(.enabled(if: has7zz)) struct Round4ArchiveTests {
    func archive(_ tmp: TempDir, in dir: String = "L") throws -> VFSPath {
        try tmp.file("\(dir)/src/a.txt", "a")
        let tool = SevenZip(executable: "/opt/homebrew/bin/7zz")
        let zip = tmp.path.appending("\(dir)/p.zip")
        try tool.create(zip, format: .zip, base: tmp.path.appending("\(dir)/src"), names: ["a.txt"], password: nil)
        return zip
    }

    func archiveProviders(_ ws: Workspace) -> [ProviderID] {
        ws.ephemeralProviders.keys.filter { (try? ws.providers.provider(for: $0)) != nil }
    }

    /// Wyjście z archiwum do usuniętego katalogu: tytuł karty zostaje „📦 p.zip” (wcześniej „/”).
    @Test func failedGoUpFromArchiveKeepsTitle() async throws {
        let tmp = try TempDir()
        let zip = try archive(tmp)
        let (ws, _) = try await makeWorkspace(tmp, left: "L")
        let tab = ws.activeTab
        try await ws.enterArchive(zip, in: tab)
        #expect(tab.isInArchive && tab.title == "📦 p.zip")
        try FileManager.default.moveItem(at: tmp.url.appending(path: "L"), to: tmp.url.appending(path: "L2"))
        await #expect(throws: (any Error).self) { try await tab.goUp() }
        #expect(tab.isInArchive && tab.title == "📦 p.zip")
    }

    @Test func archiveProviderLivesWhileTabOrHistoryUsesIt() async throws {
        let tmp = try TempDir()
        let zip = try archive(tmp)
        let (ws, _) = try await makeWorkspace(tmp, left: "L")
        let tab = ws.left.newTab()
        try await tab.navigate(to: tmp.path.appending("L"))
        try await ws.enterArchive(zip, in: tab)
        let id = tab.path.provider
        #expect(archiveProviders(ws) == [id])
        // Wyjście: wpis w historii karty — Wstecz wraca do archiwum.
        try await ws.invoke("panel.up")
        #expect(!tab.isInArchive && tab.title == "L" && archiveProviders(ws) == [id])
        try await ws.invoke("panel.back")
        #expect(tab.isInArchive && tab.title == "📦 p.zip")
        // Zamknięcie karty: nikt go nie używa — wyrejestrowany.
        try await ws.invoke("tab.close")
        #expect(archiveProviders(ws).isEmpty && ws.ephemeralProviders.isEmpty)
    }

    /// Nieudane wejście (karta-terminal nie pokazuje plików) nie zostawia zarejestrowanego dostawcy.
    @Test func failedEnterArchiveUnregistersProvider() async throws {
        let tmp = try TempDir()
        let zip = try archive(tmp)
        let (ws, _) = try await makeWorkspace(tmp, left: "L")
        let term = ws.right.newTab(at: VFSPath(provider: RemoteFS.providerID("aix"), path: "/"))
        term.terminal = TerminalSpec(alias: "aix", executable: "/usr/bin/ssh", arguments: [])
        await #expect(throws: CommandError.self) { try await ws.enterArchive(zip, in: term) }
        #expect(ws.ephemeralProviders.isEmpty)
        #expect(term.terminal != nil && !term.isInArchive)
    }

    @Test func archiveListIsUntrustedForAgent() async throws {
        let tmp = try TempDir()
        let zip = try archive(tmp)
        let (ws, _) = try await makeWorkspace(tmp, left: "L")
        let command = try #require(ws.registry.command("archive.list"))
        let args = CommandArguments(["path": .string(zip.path)])
        let forAgent = try await command.run(CommandContext(workspace: ws, invoker: .agent(sessionID: "s", agentName: "t"), arguments: args))
        #expect(forAgent.value?["untrusted"] == true && forAgent.value?["notice"] != nil)
        #expect(forAgent.value?["content"]?["entries"]?.arrayValue?.first?["path"] == "a.txt")
        let forUser = try await command.run(CommandContext(workspace: ws, invoker: .user, arguments: args))
        #expect(forUser.value?["entries"]?.arrayValue?.count == 1)
    }
}
