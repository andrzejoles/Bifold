import BifoldCore
import BifoldWorkspace
import Foundation
import MCP
import Testing
@testable import BifoldAgent

/// Wyszukiwanie agenta nie może być wyrocznią treści, nazw ani atrybutów zablokowanych plików:
/// zablokowane trafienia nie zwiększają licznika (`count`, `truncated` przy `maxResults`), a `rg`
/// nie czyta zablokowanych plików.
@MainActor @Suite(.serialized) struct SearchLeakTests {
    func call(_ env: AgentEnv, _ session: AgentSession, _ tool: String, _ args: [String: Value] = [:]) async -> (String, Bool) {
        let r = await env.controller.callTool(tool, arguments: args, sessionID: session.id)
        let text = r.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        return (text, r.isError ?? false)
    }

    /// Zablokowany plik `L/sekret.cfg` z treścią „TAJNE-HASLO”.
    func blockedFile(_ env: AgentEnv) throws -> String {
        try env.tmp.file("L/sekret.cfg", "TAJNE-HASLO")
        try env.tmp.file("L/jawny.txt", "nic")
        let base = env.tmp.url.path
        env.workspace.settings.agent.blockedPaths = [base + "/L/sekret.cfg"]
        return base
    }

    /// Przegląd katalogów (bez treści): nazwa zablokowanego pliku nie wpływa na `truncated`/`count`.
    @Test func nameSearchDoesNotCountBlockedFiles() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        let base = try blockedFile(env)
        let (session, _) = env.session()
        let args: [String: Value] = ["paths": [.string(base)], "nameMask": "sekret.cfg", "includeHidden": true, "maxResults": 1]
        let (text, isError) = await call(env, session, "search", args)
        #expect(!isError, "\(text)")
        #expect(text.contains("\"count\":0") && text.contains("\"truncated\":false"), "\(text)")
        // Rozmiar przez filtr też nie przecieka: ta sama odpowiedź dla dowolnego minSize.
        let (sized, _) = await call(env, session, "search", ["paths": [.string(base)], "nameMask": "*.cfg", "minSize": 5, "maxResults": 1])
        #expect(sized.contains("\"count\":0") && sized.contains("\"truncated\":false"), "\(sized)")
        // Jawny plik nadal jest znajdowany.
        let (ok, _) = await call(env, session, "search", ["paths": [.string(base)], "nameMask": "jawny.txt", "maxResults": 1])
        #expect(ok.contains("\"count\":1") && ok.contains("jawny.txt"), "\(ok)")
    }

    /// Treść (ripgrep): odpowiedź dla pasującej i niepasującej treści zablokowanego pliku jest identyczna.
    @Test func contentSearchIsNotAnOracleForBlockedFiles() async throws {
        let env = try await AgentEnv()
        defer { env.shutdown() }
        guard env.workspace.settings.toolPath("rg") != nil else { return }
        let base = try blockedFile(env)
        try env.tmp.file("D/ukryty/klucz.txt", "TAJNE-HASLO")
        try env.tmp.file("D/zwykly.txt", "TAJNE-HASLO jawnie")
        let (session, _) = env.session()
        func probe(_ content: String) async -> String {
            await call(env, session, "search", [
                "paths": [.string(base + "/L")], "nameMask": "sekret.cfg", "content": .string(content),
                "includeHidden": true, "maxResults": 1,
            ]).0
        }
        let matching = await probe("TAJNE")
        let other = await probe("BRAK-TAKIEJ-TRESCI")
        #expect(matching == other, "\(matching) ≠ \(other)")
        #expect(matching.contains("\"count\":0") && matching.contains("\"truncated\":false"), "\(matching)")
        // Zablokowany katalog głębiej w drzewie: trafienia obok niego zostają, z niego — nie.
        env.workspace.settings.agent.blockedPaths = [base + "/L/sekret.cfg", base + "/D/ukryty"]
        let (deep, deepErr) = await call(env, session, "search", ["paths": [.string(base + "/D"), .string(base + "/L")], "content": "TAJNE", "includeHidden": true])
        #expect(!deepErr && deep.contains("zwykly.txt"), "\(deep)")
        #expect(!deep.contains("klucz.txt") && !deep.contains("sekret.cfg") && deep.contains("\"count\":1"), "\(deep)")
    }

    /// Silnik bez agenta: korzeń rozpisany na rodzeństwo wykluczeń daje te same wyniki co zwykłe `rg`
    /// (ukryte, dowiązania, maski), a sam wykluczony korzeń — zero wyników zamiast przeszukania bieżącego katalogu.
    @Test func ripgrepRootsSkipOnlyExcludedSubtrees() async throws {
        let tmp = try TempDir()
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rg") else { return }
        try tmp.file("a/x.txt", "szukane")
        try tmp.file("a/b/y.txt", "szukane")
        try tmp.file("a/b/zakaz/z.txt", "szukane")
        try tmp.file("a/.ukryty.txt", "szukane")
        try tmp.file("c.md", "szukane")
        let base = tmp.url.path
        let zakaz = VFSPath.local(base + "/a/b/zakaz")
        let exclusion = SearchExclusion(
            isExcluded: { $0.path == zakaz.path || $0.path.hasPrefix(zakaz.path + "/") },
            containsExcluded: { zakaz.path == $0.path || zakaz.path.hasPrefix($0.path + "/") })
        let c = SearchCriteria(roots: [tmp.path], nameMask: "*.txt", contentText: "szukane")
        let hits = try await SearchEngine.collect(c, ripgrep: "/opt/homebrew/bin/rg", exclusion: exclusion).hits
        #expect(Set(hits.map(\.item.name)) == ["x.txt", "y.txt"])
        let excludedRoot = SearchCriteria(roots: [zakaz], contentText: "szukane")
        let none = try await SearchEngine.collect(excludedRoot, ripgrep: "/opt/homebrew/bin/rg", exclusion: exclusion)
        #expect(none.hits.isEmpty && !none.truncated)
        let walked = try await SearchEngine.collect(SearchCriteria(roots: [tmp.path], nameMask: "*.txt", includeHidden: true), ripgrep: nil, exclusion: exclusion).hits
        #expect(Set(walked.map(\.item.name)) == ["x.txt", "y.txt", ".ukryty.txt"])
    }
}
