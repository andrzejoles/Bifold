import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftTerm

/// Wbudowany terminal (SwiftTerm) z powłoką użytkownika. Linia poleceń pod panelami
/// wysyła tu polecenia (`$SHELL -lc` przez interaktywną powłokę).
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    private(set) var terminalView: LocalProcessTerminalView?
    private var started = false
    /// Skróty aplikacji, które terminal przepuszcza do menu (zamknięcie terminala).
    weak var workspace: Workspace?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static var userShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    func startIfNeeded(directory: VFSPath) {
        guard !started else { return }
        started = true
        let tv = LocalProcessTerminalView(frame: bounds)
        tv.processDelegate = self
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.nativeBackgroundColor = NSColor.textBackgroundColor
        tv.nativeForegroundColor = NSColor.textColor
        addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: trailingAnchor),
            tv.topAnchor.constraint(equalTo: topAnchor),
            tv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        terminalView = tv
        let shell = Self.userShell
        tv.startProcess(
            executable: shell, args: ["-l"], environment: Self.environment(term: "xterm-256color"),
            execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory.path)
    }

    /// Wysyła polecenie do powłoki w podanym katalogu (cd + polecenie).
    func run(command: String?, in directory: VFSPath) {
        startIfNeeded(directory: directory)
        guard let tv = terminalView else { return }
        var line = "cd \(shellQuote(directory.path))"
        if let command, !command.isEmpty { line += " && \(command)" }
        tv.send(txt: line + "\r")
    }

    func focus() {
        if let terminalView { window?.makeFirstResponder(terminalView) }
    }

    /// Środowisko procesu terminala: `TERM`, `LANG` z ustawień systemu, gdy aplikacja go nie ma
    /// (uruchomiona z Findera), bez tokenu agenta.
    static func environment(term: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = term
        if env["LANG"] == nil {
            let language = Locale.current.language.languageCode?.identifier ?? "en"
            let region = Locale.current.region?.identifier ?? "US"
            env["LANG"] = "\(language)_\(region).UTF-8"
        }
        env.removeValue(forKey: "BIFOLD_AGENT_TOKEN")
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// AppKit pyta o skróty widoki przed menu — gdy terminal ma fokus, klawisze bez Cmd (Ctrl+W, Ctrl+R,
    /// F3–F8…) idą do powłoki, a nie do komend panelu (jak w karcie-terminalu, D44). Wyjątek: skrót
    /// zamykający terminal (⌃`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let terminalView, window?.firstResponder === terminalView,
              !event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if let chord = KeyChord(event: event), workspace?.keymap.command(for: chord) == "tools.terminal" {
            return super.performKeyEquivalent(with: event)
        }
        terminalView.keyDown(with: event)
        return true
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            // Po `exit` fokus wraca do panelu (inaczej zostaje na oknie i klawisze nic nie robią).
            let hadFocus = self.terminalView != nil && self.window?.firstResponder === self.terminalView
            let controller = self.window?.windowController as? MainWindowController
            self.terminalView?.removeFromSuperview()
            self.terminalView = nil
            self.started = false
            self.isHidden = true
            controller?.terminalClosed(refocus: hadFocus)
        }
    }
}

/// Cytowanie argumentu dla powłoki POSIX.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
