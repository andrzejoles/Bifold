import AppKit
import BifoldCore
import SwiftTerm

/// Wbudowany terminal (SwiftTerm) z powłoką użytkownika. Linia poleceń pod panelami
/// wysyła tu polecenia (`$SHELL -lc` przez interaktywną powłokę).
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    private(set) var terminalView: LocalProcessTerminalView?
    private var started = false

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
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "pl_PL.UTF-8"
        env.removeValue(forKey: "BIFOLD_AGENT_TOKEN")
        let shell = Self.userShell
        tv.startProcess(
            executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
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

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.terminalView?.removeFromSuperview()
            self.terminalView = nil
            self.started = false
            self.isHidden = true
            (self.window?.windowController as? MainWindowController)?.terminalClosed()
        }
    }
}

/// Cytowanie argumentu dla powłoki POSIX.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
