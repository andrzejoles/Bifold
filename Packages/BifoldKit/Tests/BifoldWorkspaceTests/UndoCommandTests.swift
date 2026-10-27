import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

@MainActor @Suite struct UndoCommandTests {
    /// Okno dziennika cofa wskazaną partię przez komendę `edit.undo` z argumentem `batch`, nie tylko ostatnią.
    @Test func undoGivenBatch() async throws {
        let tmp = try TempDir()
        let (ws, ui) = try await makeWorkspace(tmp)
        ui.textAnswers = ["a", "b"]
        try await ws.invoke("file.mkdir")
        try await ws.invoke("file.mkdir")
        let first = try #require(ws.journal.batches.first { $0.entries.contains { $0.action == .created(path: tmp.path.appending("a"), isDirectory: true) } })
        try await ws.invoke("edit.undo", CommandArguments(["batch": .string(first.id.uuidString)]))
        #expect(!tmp.exists("a") && tmp.exists("b"))
        // Partia już cofnięta albo nieznana — nic się nie dzieje.
        let again = try await ws.invoke("edit.undo", CommandArguments(["batch": .string(first.id.uuidString)]))
        #expect(again.message == L10n.tr("Nie ma czego cofać") && tmp.exists("b"))
        let unknown = try await ws.invoke("edit.undo", CommandArguments(["batch": .string(UUID().uuidString)]))
        #expect(unknown.message == L10n.tr("Nie ma czego cofać") && tmp.exists("b"))
        await #expect(throws: CommandError.self) { try await ws.invoke("edit.undo", CommandArguments(["batch": "nie-uuid"])) }
    }

    /// Wzorzec nazwy odrzucony jako zbyt złożony to błąd, a nie ciche „0 wyników”.
    @Test func searchWithUnsafeNameRegexFails() async throws {
        let tmp = try TempDir()
        try tmp.file("aaaa.txt", "x")
        let (ws, _) = try await makeWorkspace(tmp)
        await #expect(throws: CommandError.self) {
            try await ws.invoke("search.find", CommandArguments(["nameRegex": "(a*)*b", "toPanel": true]))
        }
    }
}
