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
        guard !finished else { return }
        finished = true
        terminal.terminate()
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

/// Terminale kart-terminali obu paneli. Jeden rejestr na okno, bo ⌃U przenosi kartę razem z sesją
/// do drugiego panelu — panel źródłowy nie może jej wtedy uznać za zamkniętą (SIGTERM dla ssh
/// zabijałby program na serwerze). Proces kończy się dopiero, gdy karty nie ma w żadnym panelu.
final class PanelTerminalRegistry {
    private let workspace: Workspace
    private var views: [UUID: PanelTerminalView] = [:]
    private var sweepScheduled = false

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Widok terminala karty — istniejący (także przeniesiony z drugiego panelu) albo nowy.
    func view(for tab: Tab, spec: TerminalSpec) -> PanelTerminalView {
        if let existing = views[tab.id], existing.spec == spec { return existing }
        if let old = views[tab.id] {
            old.stop()
            old.removeFromSuperview()
        }
        let view = PanelTerminalView(spec: spec, workspace: workspace)
        view.onSwitchPanel = { [weak self] in self?.workspace.perform("panel.switch") }
        let id = tab.id
        // Karta mogła przejść do drugiego panelu — panel szukany w chwili zamykania.
        view.onCloseTab = { [weak self] in self?.closeTab(id) }
        views[tab.id] = view
        return view
    }

    /// Sprząta terminale zamkniętych kart w następnym obrocie pętli — dopiero gdy oba panele
    /// odczytały zmianę kart (przy zamianie panel źródłowy reaguje, zanim docelowy przejmie widok).
    func scheduleSweep() {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sweepScheduled = false
            self.sweep()
        }
    }

    private func sweep() {
        let ids = Set(PanelSide.allCases.flatMap { workspace.panel($0).tabs.map(\.id) })
        for (id, view) in views where !ids.contains(id) {
            view.stop()
            view.removeFromSuperview()
            views[id] = nil
        }
    }

    /// Zamknięcie okna kończy wszystkie sesje kart-terminali.
    func stopAll() {
        for view in views.values { view.stop() }
        views = [:]
    }

    private func closeTab(_ id: UUID) {
        for side in PanelSide.allCases {
            guard let index = workspace.panel(side).tabs.firstIndex(where: { $0.id == id }) else { continue }
            workspace.perform("tab.close", CommandArguments(["index": .int(Int64(index)), "side": .string(side.rawValue)]))
            return
        }
    }
}
