import AppKit
import BifoldAgent
import BifoldCore
import BifoldWorkspace
import SwiftTerm

/// Panel agenta: terminal z natywnym interfejsem CLI (SwiftTerm) i obok panel aktywności
/// (wywołania API, zatwierdzenia). Kilka sesji — wybór z listy.
final class AgentPane: NSView {
    let controller: AgentController
    var onUndo: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onShowLog: (() -> Void)?

    private final class SessionView {
        let id: String
        let kind: AgentKind
        let terminal: AgentTerminalView
        var ended = false
        let warnings: [String]
        let command: String
        init(id: String, kind: AgentKind, terminal: AgentTerminalView, warnings: [String], command: String) {
            self.id = id
            self.kind = kind
            self.terminal = terminal
            self.warnings = warnings
            self.command = command
        }
    }

    private var sessions: [SessionView] = []
    private let picker = NSPopUpButton()
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let terminalContainer = NSView()
    private let activityTable = NSTableView()
    private var rows: [AgentActivity] = []
    private let observations = ObservationBag()
    private let split = NSSplitView()

    var selectedSessionID: String? {
        let i = picker.indexOfSelectedItem
        return i >= 0 && i < sessions.count ? sessions[i].id : nil
    }

    init(controller: AgentController) {
        self.controller = controller
        super.init(frame: .zero)
        build()
        observations.add { [weak self] in
            guard let self else { return }
            _ = self.controller.activities
            _ = self.controller.pending
            _ = self.controller.sessions
            self.refreshActivity()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        picker.target = self
        picker.action = #selector(pickSession)
        picker.controlSize = .small
        let undo = NSButton(title: L10n.tr("Cofnij sesję…"), target: self, action: #selector(undo))
        let end = NSButton(title: L10n.tr("Zakończ"), target: self, action: #selector(end))
        let log = NSButton(title: L10n.tr("Dziennik"), target: self, action: #selector(showLog))
        for b in [undo, end, log] { b.controlSize = .small; b.bezelStyle = .accessoryBarAction; b.refusesFirstResponder = true }
        warningLabel.font = .systemFont(ofSize: 10.5)
        warningLabel.textColor = .systemOrange
        warningLabel.maximumNumberOfLines = 2
        warningLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)!), picker, warningLabel, NSView(), undo, end, log])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

        for (id, title, width) in [("time", L10n.tr("Czas"), 60.0), ("tool", L10n.tr("Narzędzie"), 120.0), ("status", L10n.tr("Stan"), 110.0), ("args", L10n.tr("Parametry / wynik"), 300.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            activityTable.addTableColumn(c)
        }
        activityTable.dataSource = self
        activityTable.delegate = self
        activityTable.rowHeight = 18
        activityTable.usesAlternatingRowBackgroundColors = true
        activityTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let activityScroll = NSScrollView()
        activityScroll.documentView = activityTable
        activityScroll.hasVerticalScroller = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(terminalContainer)
        split.addArrangedSubview(activityScroll)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        let stack = NSStackView(views: [header, split])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            activityScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    /// Dodaje sesję i zwraca terminal, w którym aplikacja uruchomi CLI.
    func addSession(session: AgentSession, warnings: [String], command: String, onExit: @escaping @MainActor () -> Void) -> LocalProcessTerminalView {
        let tv = AgentTerminalView(frame: .zero)
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.nativeBackgroundColor = .textBackgroundColor
        tv.nativeForegroundColor = .textColor
        let view = SessionView(id: session.id, kind: session.kind, terminal: tv, warnings: warnings, command: command)
        tv.onExit = { [weak self, weak view] in
            view?.ended = true
            onExit()
            self?.rebuildPicker()
        }
        tv.processDelegate = tv.exitDelegate
        sessions.append(view)
        rebuildPicker()
        picker.selectItem(at: sessions.count - 1)
        show(view)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.split.subviews.count == 2 else { return }
            self.split.setPosition(self.split.bounds.width * 0.66, ofDividerAt: 0)
        }
        return tv
    }

    /// Kończy CLI jak zamknięcie okna terminala: SIGHUP do całej grupy procesów (powłoka i CLI —
    /// część CLI przechwytuje SIGTERM), po 2 s SIGKILL, jeśli coś jeszcze działa.
    func terminateSession(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }), !s.ended else { return }
        let pid = s.terminal.process.shellPid
        guard pid > 0 else {
            s.terminal.terminate()
            return
        }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // Cała grupa: powłoka mogła się już zakończyć, a CLI ignorujące SIGHUP — nie.
            guard kill(-pid, 0) == 0 || kill(pid, 0) == 0 else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    /// Czy działa jeszcze jakaś sesja poza `excluding`.
    func hasRunningSessions(excluding id: String? = nil) -> Bool {
        sessions.contains { !$0.ended && $0.id != id }
    }

    private func rebuildPicker() {
        let selected = picker.indexOfSelectedItem
        picker.removeAllItems()
        for s in sessions {
            picker.addItem(withTitle: "\(s.kind.displayName) · \(s.id)\(s.ended ? " — " + L10n.tr("zakończona") : "")")
        }
        if selected >= 0, selected < sessions.count { picker.selectItem(at: selected) }
    }

    private func show(_ s: SessionView) {
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        s.terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(s.terminal)
        NSLayoutConstraint.activate([
            s.terminal.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            s.terminal.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            s.terminal.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            s.terminal.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])
        warningLabel.stringValue = s.warnings.joined(separator: " ")
        warningLabel.toolTip = s.command
        refreshActivity()
    }

    @objc private func pickSession() {
        let i = picker.indexOfSelectedItem
        guard i >= 0, i < sessions.count else { return }
        show(sessions[i])
    }

    @objc private func undo() { if let id = selectedSessionID { onUndo?(id) } }
    @objc private func end() { if let id = selectedSessionID { onClose?(id) } }
    @objc private func showLog() { onShowLog?() }

    private func refreshActivity() {
        let id = selectedSessionID
        rows = controller.activities.filter { $0.sessionID == id }.reversed()
        activityTable.reloadData()
    }

    func focusTerminal() {
        guard let i = Optional(picker.indexOfSelectedItem), i >= 0, i < sessions.count else { return }
        window?.makeFirstResponder(sessions[i].terminal)
    }
}

extension AgentPane: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = rows[row]
        let text: String
        var color = NSColor.labelColor
        switch tableColumn?.identifier.rawValue {
        case "time":
            text = Self.time.string(from: a.started)
        case "tool":
            text = a.toolText
        case "status":
            switch a.status {
            case .running: text = L10n.tr("w toku")
            case .waitingForApproval: text = L10n.tr("czeka na zgodę"); color = .systemOrange
            case .succeeded: text = "✓ " + (a.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? ""); color = .systemGreen
            case .denied(let why): text = "✕ " + why; color = .systemRed
            case .failed: text = L10n.tr("błąd"); color = .systemRed
            }
        default:
            text = a.detailText
        }
        // Nazwa narzędzia, argumenty i wynik pochodzą od agenta i z plików: znaki sterujące, bidi (U+202E)
        // i separatory wierszy jako `\u{…}`, jak w oknie zgody (także powód odmowy).
        let safe = ApprovalText.sanitize(text)
        let field = NSTextField(labelWithString: safe)
        field.font = .systemFont(ofSize: 11)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = safe
        return field
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Terminal procesu CLI agenta z powiadomieniem o zakończeniu.
final class AgentTerminalView: LocalProcessTerminalView {
    var onExit: (@MainActor () -> Void)? {
        didSet { exitDelegate.onExit = onExit }
    }
    let exitDelegate = TerminalExitDelegate()
}

final class TerminalExitDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onExit: (@MainActor () -> Void)?

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.onExit?() }
    }
}

/// Przeglądarka dziennika agentów (pliki JSONL w agent-logs/).
final class AgentLogWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let directory: URL
    private let files = NSTableView()
    private let content = NSTextView()
    private var urls: [URL] = []

    init(directory: URL) {
        self.directory = directory
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Dziennik agentów")
        super.init(window: window)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("f"))
        col.title = L10n.tr("Plik")
        col.width = 260
        files.addTableColumn(col)
        files.dataSource = self
        files.delegate = self
        let left = NSScrollView()
        left.documentView = files
        left.hasVerticalScroller = true
        let right = NSScrollView()
        content.isEditable = false
        content.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.autoresizingMask = [.width]
        right.documentView = content
        right.hasVerticalScroller = true
        let split = NSSplitView()
        split.isVertical = true
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        window.contentView = split
        split.setPosition(280, ofDividerAt: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        files.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: urls[row].lastPathComponent)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard files.selectedRow >= 0 else { return }
        content.string = (try? String(contentsOf: urls[files.selectedRow], encoding: .utf8)) ?? ""
    }
}
