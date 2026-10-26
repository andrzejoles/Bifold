import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftTerm

/// Terminal w karcie panelu (SSH do zapisanego serwera). Wszystkie klawisze bez Cmd idą do
/// programu na serwerze (także F-klawisze, Tab, Esc — mc i podobne działają); Ctrl+Tab przełącza
/// panel (Tab, czyli zwykłe „Przełącz panel”, trafia do serwera), skróty z Cmd zostają dla aplikacji.
/// Kartę zamyka skrót „Zamknij kartę” z Cmd, a gdy profil go nie ma (TC: ⌃W idzie do serwera) — ⌘W.
final class PanelTerminal: LocalProcessTerminalView {}

final class PanelTerminalView: NSView, LocalProcessTerminalViewDelegate {
    let terminal: PanelTerminal
    let spec: TerminalSpec
    var onSwitchPanel: (() -> Void)?
    var onCloseTab: (() -> Void)?
    private(set) var finished = false
    private weak var workspace: Workspace?

    init(spec: TerminalSpec, workspace: Workspace) {
        self.spec = spec
        self.workspace = workspace
        terminal = PanelTerminal(frame: .zero)
        super.init(frame: .zero)
        terminal.processDelegate = self
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeBackgroundColor = NSColor.textBackgroundColor
        terminal.nativeForegroundColor = NSColor.textColor
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Aplikacja z Findera zwykle nie ma LANG — z ustawień systemu (ssh przekazuje go na serwer).
        terminal.startProcess(executable: spec.executable, args: spec.arguments, environment: TerminalPane.environment(term: spec.term),
                              execName: nil, currentDirectory: NSHomeDirectory())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// AppKit pyta o skróty widoki od góry hierarchii — pojemnik przejmuje je przed menu, gdy
    /// terminal ma fokus (F5 ma trafić do programu na serwerze, nie do kopiowania plików).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === terminal else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) {
            // ⌘W bez przypisanej komendy (profil TC) zamyka kartę-terminal.
            if let chord = KeyChord(event: event), chord == Self.fallbackClose, let workspace, workspace.keymap.command(for: chord) == nil {
                onCloseTab?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 48, event.modifierFlags.contains(.control) {
            onSwitchPanel?()
            return true
        }
        terminal.keyDown(with: event)
        return true
    }

    private static let fallbackClose = KeyChord(key: "w", modifiers: .command)

    /// Skrót zamykający kartę-terminal: „Zamknij kartę” z Cmd (klawisze bez Cmd idą do serwera),
    /// a bez takiego — ⌘W, jeśli nie jest przypisany innej komendzie.
    static func closeChord(_ keymap: Keymap) -> KeyChord? {
        if let chord = keymap.chords(for: "tab.close").first(where: { $0.modifiers.contains(.command) }) { return chord }
        return keymap.command(for: fallbackClose) == nil ? fallbackClose : nil
    }

    func stop() {
        if !finished { terminal.terminate() }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.finished = true
            let message = self.workspace.flatMap { Self.closeChord($0.keymap) }.map { L10n.tr("[Sesja SSH zakończona — \($0.displayString) zamyka kartę]") }
                ?? L10n.tr("[Sesja SSH zakończona]")
            self.terminal.feed(text: "\r\n\u{1B}[2m" + message + "\u{1B}[0m\r\n")
        }
    }
}
