import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftTerm

/// Terminal w karcie panelu (SSH do zapisanego serwera). Wszystkie klawisze bez Cmd idą do
/// programu na serwerze (także F-klawisze, Tab, Esc — mc i podobne działają); Ctrl+Tab przełącza
/// panel, skróty z Cmd zostają dla aplikacji (⌘W zamyka kartę).
final class PanelTerminal: LocalProcessTerminalView {}

final class PanelTerminalView: NSView, LocalProcessTerminalViewDelegate {
    let terminal: PanelTerminal
    let spec: TerminalSpec
    var onSwitchPanel: (() -> Void)?
    private(set) var finished = false

    init(spec: TerminalSpec) {
        self.spec = spec
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
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "pl_PL.UTF-8"
        env.removeValue(forKey: "BIFOLD_AGENT_TOKEN")
        terminal.startProcess(executable: spec.executable, args: spec.arguments, environment: env.map { "\($0.key)=\($0.value)" },
                              execName: nil, currentDirectory: NSHomeDirectory())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// AppKit pyta o skróty widoki od góry hierarchii — pojemnik przejmuje je przed menu, gdy
    /// terminal ma fokus (F5 ma trafić do programu na serwerze, nie do kopiowania plików).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === terminal, !event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 48, event.modifierFlags.contains(.control) {
            onSwitchPanel?()
            return true
        }
        terminal.keyDown(with: event)
        return true
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
            self.terminal.feed(text: "\r\n\u{1B}[2m" + L10n.tr("[Sesja SSH zakończona — ⌘W zamyka kartę]") + "\u{1B}[0m\r\n")
        }
    }
}
