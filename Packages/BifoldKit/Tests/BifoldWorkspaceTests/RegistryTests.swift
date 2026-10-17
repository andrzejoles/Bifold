import BifoldCore
import Foundation
import Testing
@testable import BifoldWorkspace

@MainActor @Suite struct RegistryTests {
    let registry = CommandRegistry.standard()

    @Test func everyCommandIsDescribed() {
        #expect(registry.commands.count > 60)
        for c in registry.descriptors {
            #expect(!c.title.isEmpty, "\(c.id)")
            #expect(!c.summary.isEmpty, "\(c.id)")
            // Komenda zmieniająca pliki nie może mieć poziomu „Pełny” ani „Odczyt”.
            // Wyjątek z macierzy: sumy kontrolne („Pełny”) tworzą tylko nowy plik sum (cofalne).
            if c.effect == .modifiesFiles, c.id != "file.checksumCreate" { #expect(c.agentAccess == .approval || c.agentAccess == .none, "\(c.id)") }
            if c.effect == .external { #expect(c.agentAccess == .none, "\(c.id)") }
        }
        #expect(Set(registry.descriptors.map(\.id)).count == registry.descriptors.count)
    }

    /// Poziomy z macierzy PROMPT.md (Etap 1).
    @Test(arguments: [
        ("panel.switch", AgentAccess.read), ("tab.new", .full), ("view.details", .full), ("view.columns", .full),
        ("view.toggleTree", .read), ("panel.quickFilter", .full), ("selection.calculateSizes", .read),
        ("colors.set", .full), ("file.copy", .approval), ("file.move", .approval), ("queue.setSpeedLimit", .approval),
        ("file.trash", .approval), ("file.deletePermanently", .none), ("file.mkdir", .approval), ("file.newFile", .approval),
        ("file.attributes", .approval), ("clipboard.copyPaths", .full), ("selection.byMask", .full), ("edit.undo", .approval),
        ("file.view", .read), ("view.quickLook", .read), ("view.previewPanel", .read), ("file.edit", .none),
        ("tools.commandLine", .none), ("tools.terminal", .none), ("tools.volumes", .read), ("file.tags", .approval),
        ("tools.share", .none), ("tools.openWith", .none),
        ("search.find", .full), ("search.spotlight", .full), ("search.runSaved", .full), ("search.duplicates", .read),
        ("file.multiRename", .approval), ("file.checksumCreate", .full), ("file.checksumVerify", .full),
        ("file.split", .approval), ("file.join", .approval),
        ("file.compare", .read), ("dirs.compare", .read), ("sync.run", .approval), ("sync.runSaved", .approval), ("sync.save", .approval),
        ("archive.create", .approval), ("archive.extract", .approval), ("archive.list", .read), ("archive.test", .read),
    ] as [(String, AgentAccess)])
    func accessMatrix(id: String, level: AgentAccess) {
        #expect(registry.command(CommandID(rawValue: id))?.descriptor.agentAccess == level)
    }

    @Test(arguments: ShortcutProfile.allCases)
    func noShortcutConflicts(profile: ShortcutProfile) {
        let conflicts = Keymap.conflicts(in: registry.descriptors, profile: profile)
        #expect(conflicts.isEmpty, "\(conflicts.map { "\($0.key): \($0.value)" })")
    }

    @Test func totalCommanderDefaults() {
        let km = Keymap(commands: registry.descriptors, profile: .totalCommander)
        let expected: [String: String] = [
            "f3": "file.view", "f4": "file.edit", "shift+f4": "file.newFile", "f5": "file.copy", "f6": "file.move",
            "shift+f6": "file.rename", "f7": "file.mkdir", "f8": "file.trash", "tab": "panel.switch", "ctrl+t": "tab.new",
            "ctrl+w": "tab.close", "alt+f7": "search.find", "ctrl+m": "file.multiRename", "ctrl+q": "view.previewPanel",
            "space": "selection.toggle", "cmd+=": "selection.byMask", "cmd+-": "selection.deselectByMask",
        ]
        for (chord, id) in expected where registry.command(CommandID(rawValue: id)) != nil {
            #expect(km.command(for: KeyChord(string: chord)!)?.rawValue == id, "\(chord)")
        }
        let cmd = Keymap(commands: registry.descriptors, profile: .command)
        #expect(cmd.command(for: KeyChord(string: "cmd+5")!) == "file.copy")
        #expect(cmd.command(for: KeyChord(string: "f5")!) == "file.copy")
    }

    @Test func overridesReplaceAndRemove() {
        let km = Keymap(commands: registry.descriptors, profile: .totalCommander, overrides: ["f5": "", "ctrl+k": "file.copy"])
        #expect(km.command(for: KeyChord(string: "f5")!) == nil)
        #expect(km.command(for: KeyChord(string: "ctrl+k")!) == "file.copy")
    }

    @Test func chordParsing() {
        #expect(KeyChord(string: "Shift+F6")?.description == "shift+f6")
        #expect(KeyChord(string: "cmd++")?.key == "+")
        #expect(KeyChord(string: "ctrl+alt+shift+cmd+x")?.displayString == "⌃⌥⇧⌘X")
        #expect(KeyChord(string: "hyper+x") == nil)
        #expect(KeyChord(string: "ctrl+nonsense") == nil)
    }
}
