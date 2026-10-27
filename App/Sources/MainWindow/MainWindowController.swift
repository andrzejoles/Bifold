import AppKit
import BifoldCore
import BifoldWorkspace

/// Okno główne: dwa panele, pod nimi terminal (zwijany), linia poleceń, kolejka operacji
/// i pasek klawiszy funkcyjnych.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    let workspace: Workspace
    let services: AppUIServices
    let left: PanelViewController
    let right: PanelViewController
    /// Wspólne dla obu paneli — ⌃U przenosi kartę-terminal z sesją do drugiego panelu.
    private let panelTerminals: PanelTerminalRegistry
    private let panelsSplit = NSSplitView()
    private let verticalSplit = NSSplitView()
    /// Dolna część okna: terminal i panel agenta (każde może być ukryte).
    private let bottomSplit = NSSplitView()
    let terminal: TerminalPane
    let commandLine: CommandLineBar
    let jobsBar: JobsBar
    var agentPane: AgentPane? {
        didSet {
            guard let agentPane, oldValue == nil else { return }
            agentPane.isHidden = true
            bottomSplit.addArrangedSubview(agentPane)
        }
    }
    private let functionBar: FunctionKeyBar
    private let observations = ObservationBag()

    init(workspace: Workspace, services: AppUIServices) {
        self.workspace = workspace
        self.services = services
        panelTerminals = PanelTerminalRegistry(workspace: workspace)
        left = PanelViewController(workspace: workspace, side: .left, terminals: panelTerminals)
        right = PanelViewController(workspace: workspace, side: .right, terminals: panelTerminals)
        terminal = TerminalPane()
        commandLine = CommandLineBar(workspace: workspace)
        jobsBar = JobsBar(workspace: workspace)
        functionBar = FunctionKeyBar(workspace: workspace)
        terminal.workspace = workspace

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = Brand.appName
        window.minSize = NSSize(width: 800, height: 480)
        window.setFrameAutosaveName("MainWindow")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        if window.frame.origin == .zero { window.center() }
        buildLayout()
        bind()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        panelsSplit.isVertical = true
        panelsSplit.dividerStyle = .thin
        panelsSplit.delegate = self
        panelsSplit.addArrangedSubview(left.view)
        panelsSplit.addArrangedSubview(right.view)
        panelsSplit.autosaveName = "PanelsSplit"

        verticalSplit.isVertical = false
        verticalSplit.dividerStyle = .thin
        verticalSplit.delegate = self
        bottomSplit.isVertical = false
        bottomSplit.dividerStyle = .thin
        bottomSplit.addArrangedSubview(terminal)
        bottomSplit.isHidden = true
        verticalSplit.addArrangedSubview(panelsSplit)
        verticalSplit.addArrangedSubview(bottomSplit)
        verticalSplit.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        verticalSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        terminal.isHidden = true

        let stack = NSStackView(views: [verticalSplit, commandLine, jobsBar, functionBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        verticalSplit.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        DispatchQueue.main.async { [self] in
            if panelsSplit.subviews.count == 2, abs(panelsSplit.subviews[0].frame.width - panelsSplit.subviews[1].frame.width) > panelsSplit.bounds.width * 0.6 {
                panelsSplit.setPosition(panelsSplit.bounds.width / 2, ofDividerAt: 0)
            }
        }
    }

    private func bind() {
        observations.add { [weak self] in
            guard let self else { return }
            let side = self.workspace.activeSide
            self.left.setActive(side == .left)
            self.right.setActive(side == .right)
            // Fokus idzie za aktywnym panelem, jeśli był w którymś panelu (lista, drzewo, karta-terminal)
            // albo nigdzie — ale nie z pól tekstowych (filtr, linia poleceń) ani z dolnego terminala.
            let responder = self.window?.firstResponder
            let inPanel = (responder as? NSView).map { $0.isDescendant(of: self.left.view) || $0.isDescendant(of: self.right.view) } ?? false
            if responder == nil || responder === self.window || (inPanel && !(responder is NSText)) {
                self.focusActivePanel()
            }
        }
        observations.add { [weak self] in
            guard let self else { return }
            let tab = self.workspace.activeTab
            self.window?.title = "\(Brand.appName) — \(tab.path.description)"
            self.window?.representedURL = tab.path.url
            self.commandLine.directory = tab.path
        }
    }

    func panel(_ side: PanelSide) -> PanelViewController { side == .left ? left : right }
    var activePanel: PanelViewController { panel(workspace.activeSide) }

    func focusActivePanel() {
        activePanel.focus()
    }

    // MARK: Terminal

    func toggleTerminal(directory: VFSPath) {
        if terminal.isHidden {
            showTerminal(directory: directory)
            terminal.focus()
        } else if window?.firstResponder === terminal.terminalView {
            terminal.isHidden = true
            updateBottom()
            focusActivePanel()
        } else {
            terminal.focus()
        }
    }

    func showTerminal(directory: VFSPath) {
        terminal.startIfNeeded(directory: directory)
        if terminal.isHidden {
            terminal.isHidden = false
            updateBottom()
        }
    }

    func setAgentPane(visible: Bool) {
        guard let agentPane else { return }
        if visible == !agentPane.isHidden { return }
        agentPane.isHidden = !visible
        updateBottom()
        if visible { agentPane.focusTerminal() } else { focusActivePanel() }
    }

    func terminalClosed(refocus: Bool) {
        updateBottom()
        if refocus || window?.firstResponder == nil || window?.firstResponder === window { focusActivePanel() }
    }

    /// Pokazuje dolną część okna, gdy widoczny jest terminal lub panel agenta.
    private func updateBottom() {
        let anyVisible = !terminal.isHidden || !(agentPane?.isHidden ?? true)
        let wasHidden = bottomSplit.isHidden
        bottomSplit.isHidden = !anyVisible
        bottomSplit.adjustSubviews()
        verticalSplit.adjustSubviews()
        if anyVisible && wasHidden {
            verticalSplit.setPosition(verticalSplit.bounds.height * 0.55, ofDividerAt: 0)
        }
        if !terminal.isHidden, let agentPane, !agentPane.isHidden {
            bottomSplit.setPosition(bottomSplit.bounds.height * 0.4, ofDividerAt: 0)
        }
    }

    func run(command: String?, directory: VFSPath) {
        showTerminal(directory: directory)
        terminal.run(command: command, in: directory)
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === panelsSplit ? 280 : 120
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === panelsSplit ? splitView.bounds.width - 280 : splitView.bounds.height - 80
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView === panelsSplit, splitView.subviews.count == 2, oldSize.width > 0 else {
            splitView.adjustSubviews()
            return
        }
        // Panele zachowują proporcję przy zmianie rozmiaru okna.
        let ratio = splitView.subviews[0].frame.width / max(1, oldSize.width - splitView.dividerThickness)
        let available = splitView.bounds.width - splitView.dividerThickness
        let leftWidth = (available * ratio).rounded()
        splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: leftWidth, height: splitView.bounds.height)
        splitView.subviews[1].frame = NSRect(x: leftWidth + splitView.dividerThickness, y: 0, width: available - leftWidth, height: splitView.bounds.height)
    }

    func windowWillClose(_ notification: Notification) {
        workspace.saveSession()
        panelTerminals.stopAll()
    }
}

/// Pasek klawiszy funkcyjnych jak w Total Commanderze (przyciski wywołują komendy z rejestru).
final class FunctionKeyBar: NSView {
    private let workspace: Workspace
    private let stack = NSStackView()
    private let observations = ObservationBag()

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        observations.add { [weak self] in
            guard let self else { return }
            _ = self.workspace.keymap
            self.rebuild()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let commands: [(CommandID, String)] = [
        ("file.view", L10n.tr("Podgląd")), ("file.edit", L10n.tr("Edycja")), ("file.copy", L10n.tr("Kopiuj")),
        ("file.move", L10n.tr("Przenieś")), ("file.mkdir", L10n.tr("Nowy katalog")), ("file.trash", L10n.tr("Do Kosza")),
        ("tools.terminal", L10n.tr("Terminal")), ("tools.commandPalette", L10n.tr("Komendy")),
    ]

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (id, title) in Self.commands {
            let chord = workspace.keymap.chords(for: id).first?.displayString ?? ""
            let button = NSButton(title: chord.isEmpty ? title : "\(chord) \(title)", target: self, action: #selector(press(_:)))
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            button.refusesFirstResponder = true
            stack.addArrangedSubview(button)
        }
    }

    @objc private func press(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        workspace.perform(CommandID(rawValue: raw))
    }
}
