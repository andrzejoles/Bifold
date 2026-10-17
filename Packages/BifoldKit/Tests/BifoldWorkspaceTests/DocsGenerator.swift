import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

/// `BIFOLD_WRITE_DOCS=1 swift test --filter DocsGenerator` — zapisuje docs/SKROTY.md z rejestru komend.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["BIFOLD_WRITE_DOCS"] == "1"))
struct DocsGenerator {
    @Test func writeShortcuts() throws {
        let registry = CommandRegistry.standard()
        let tc = Keymap(commands: registry.descriptors, profile: .totalCommander)
        let cmd = Keymap(commands: registry.descriptors, profile: .command)
        var out = """
        # Skróty i komendy

        Wygenerowane z rejestru komend (`BIFOLD_WRITE_DOCS=1 swift test --filter DocsGenerator`).
        Komendy dodawane przez aplikację (agenci, pomocnik administratora) są w palecie komend (⇧⌘P).
        Poziom agenta: Brak — narzędzie niewidoczne; Odczyt; Za zgodą — okno zatwierdzania; Pełny.


        """
        for category in CommandCategory.allCases {
            let commands = registry.commands.filter { $0.descriptor.category == category }
            guard !commands.isEmpty else { continue }
            out += "## \(category.displayName)\n\n| Komenda | Id | Profil TC | Profil Cmd | Agent |\n|---|---|---|---|---|\n"
            for c in commands {
                let a = tc.chords(for: c.id).map(\.displayString).joined(separator: " ")
                let b = cmd.chords(for: c.id).map(\.displayString).joined(separator: " ")
                out += "| \(c.descriptor.title) | `\(c.id.rawValue)` | \(a) | \(b) | \(c.descriptor.agentAccess.displayName) |\n"
            }
            out += "\n"
        }
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/SKROTY.md")
        try Data(out.utf8).write(to: url)
    }
}
