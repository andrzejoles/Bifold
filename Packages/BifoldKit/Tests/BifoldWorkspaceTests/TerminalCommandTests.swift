import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

/// Linia poleceń wysyła do powłoki `cd '<katalog>' && polecenie` jak z klawiatury — nazwa katalogu
/// ze znakami sterującymi (Ctrl+U kasuje wiersz, CR go wykonuje) nie może stać się poleceniem.
@MainActor @Suite struct TerminalCommandTests {
    @Test func runCommandRefusesDirectoryWithControlCharacters() async throws {
        let tmp = try TempDir()
        let evil = "x\u{15}touch pwned\r"
        try tmp.dir(evil)
        try tmp.dir("zwykły")
        let (ws, ui) = try await makeWorkspace(tmp, left: evil)
        await #expect(throws: CommandError.self) {
            try await ws.invoke("tools.runCommand", CommandArguments(["command": .string("ls")]))
        }
        #expect(ui.terminalRuns.isEmpty)

        try await ws.activeTab.navigate(to: tmp.path.appending("zwykły"))
        try await ws.invoke("tools.runCommand", CommandArguments(["command": .string("ls")]))
        #expect(ui.terminalRuns.count == 1 && ui.terminalRuns.first?.command == "ls")
    }

    @Test func controlCharacterDetection() {
        #expect(containsControlCharacters("a\u{15}b"))
        #expect(containsControlCharacters("a\rb"))
        #expect(containsControlCharacters("a\u{85}b"))
        #expect(containsControlCharacters("a\u{2028}b"))
        #expect(!containsControlCharacters("/Users/zażółć gęślą jaźń/'x' \"y\""))
    }
}
