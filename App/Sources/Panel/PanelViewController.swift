import AppKit
import BifoldCore
import BifoldWorkspace

/// Widok plików karty (szczegóły, lista skrócona, miniatury, kolumny).
@MainActor
protocol FileListView: NSView {
    var controller: PanelViewController? { get set }
    /// Pełne przeładowanie (zmiana katalogu, sortowania, filtra).
    func reload(_ tab: Tab)
    /// Kursor zmieniony w modelu — przewiń i zaznacz wiersz.
    func syncCursor(_ tab: Tab)
    /// Zmieniło się zaznaczenie (oznaczenie) albo rozmiary katalogów — odśwież widoczne wiersze.
    func refreshMarks(_ tab: Tab)
    func focus()
    var isFocused: Bool { get }
}

/// Jeden panel: karty, ścieżka, (drzewo +) lista plików, filtr, pasek stanu.
final class PanelViewController: NSViewController {
    let workspace: Workspace
    let side: PanelSide
    private let tabBar = TabBarView()
    private let pathBar = PathBarView()
    private let statusBar = NSTextField(labelWithString: "")
    private let filterField = NSSearchField()
    private let contentSplit = NSSplitView()
    private let fileContainer = NSView()
    private let tree: DirectoryTreeView
    private var currentView: (any FileListView)?
    private var currentMode: ViewMode?
    private var previewView: QuickViewPane?
    private let quickSearch = QuickSearchOverlay()
    private let observations = ObservationBag()
    private var lastGeneration = -1
    private var lastTabID: UUID?
    private(set) var isActive = false

    init(workspace: Workspace, side: PanelSide) {
        self.workspace = workspace
        self.side = side
        tree = DirectoryTreeView(workspace: workspace)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var panel: Panel { workspace.panel(side) }
    var tab: Tab { panel.activeTab }

    override func loadView() {
        let root = PanelRootView()
        root.onMouseDown = { [weak self] in self?.activate() }
        view = root

        tabBar.onSelect = { [weak self] i in self?.activate(); self?.panel.selectTab(i) }
        tabBar.onClose = { [weak self] i in self?.panel.closeTab(at: i) }
        tabBar.onNew = { [weak self] in
            guard let self else { return }
            self.activate()
            self.workspace.perform("tab.new")
        }
        pathBar.onNavigate = { [weak self] path in
            guard let self else { return }
            self.activate()
            Task { try? await self.tab.navigate(to: path) }
        }
        pathBar.onVolumes = { [weak self] in
            self?.activate()
            self?.workspace.perform("tools.volumes")
        }

        filterField.placeholderString = L10n.tr("Filtr: fragment nazwy lub maska (*.jpg)")
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.delegate = self
        filterField.isHidden = true
        filterField.controlSize = .small

        statusBar.font = .systemFont(ofSize: 11)
        statusBar.textColor = .secondaryLabelColor
        statusBar.lineBreakMode = .byTruncatingMiddle

        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.addArrangedSubview(tree)
        contentSplit.addArrangedSubview(fileContainer)
        contentSplit.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        tree.onNavigate = { [weak self] path in
            guard let self else { return }
            self.activate()
            Task { try? await self.tab.navigate(to: path) }
        }

        let statusRow = NSStackView(views: [statusBar])
        statusRow.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 3, right: 6)

        let stack = NSStackView(views: [tabBar, pathBar, contentSplit, filterField, statusRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        contentSplit.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tree.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        quickSearch.isHidden = true
        quickSearch.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(quickSearch)
        NSLayoutConstraint.activate([
            quickSearch.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            quickSearch.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -8),
        ])
        bind()
    }

    private func bind() {
        // Karty
        observations.add { [weak self] in
            guard let self else { return }
            let panel = self.panel
            self.tabBar.update(titles: panel.tabs.map(\.title), active: panel.activeTabIndex)
        }
        // Widok, katalog, listing
        observations.add { [weak self] in
            guard let self else { return }
            let tab = self.tab
            let mode = tab.viewMode
            let generation = tab.generation
            let quickView = self.workspace.quickViewActive && self.workspace.activeSide != self.side
            self.updateContent(tab: tab, mode: mode, generation: generation, quickView: quickView)
        }
        // Kursor
        observations.add { [weak self] in
            guard let self else { return }
            let tab = self.tab
            _ = tab.cursor
            self.currentView?.syncCursor(tab)
        }
        // Zaznaczenie, rozmiary katalogów, reguły kolorów
        observations.add { [weak self] in
            guard let self else { return }
            let tab = self.tab
            _ = tab.selection
            _ = tab.directorySizes
            _ = self.workspace.colorRules
            _ = self.workspace.settings.fontSize
            self.currentView?.refreshMarks(tab)
        }
        // Ścieżka, wolne miejsce, stan
        observations.add { [weak self] in
            guard let self else { return }
            let tab = self.tab
            self.pathBar.update(path: tab.path, volume: tab.volume, error: tab.loadError, loading: tab.isLoading)
            self.updateStatus(tab)
        }
        // Drzewo
        observations.add { [weak self] in
            guard let self else { return }
            let shows = self.panel.showsTree
            self.tree.isHidden = !shows
            if shows { self.tree.reveal(self.tab.path) }
            self.contentSplit.adjustSubviews()
            if shows, self.tree.frame.width < 100 { self.contentSplit.setPosition(220, ofDividerAt: 0) }
        }
        // Filtr
        observations.add { [weak self] in
            guard let self else { return }
            let filter = self.tab.quickFilter
            if self.filterField.stringValue != filter { self.filterField.stringValue = filter }
            if !filter.isEmpty { self.filterField.isHidden = false }
        }
    }

    private func updateContent(tab: Tab, mode: ViewMode, generation: Int, quickView: Bool) {
        if quickView {
            if previewView == nil {
                let pane = QuickViewPane(workspace: workspace)
                previewView = pane
                install(pane)
                currentView = nil
                currentMode = nil
            }
            return
        }
        if previewView != nil {
            previewView?.removeFromSuperview()
            previewView = nil
        }
        if currentMode != mode || currentView == nil {
            let newView: any FileListView = switch mode {
            case .details: DetailsListView(workspace: workspace)
            case .brief: GridListView(workspace: workspace, style: .brief)
            case .thumbnails: GridListView(workspace: workspace, style: .thumbnails)
            case .columns: ColumnListView(workspace: workspace)
            }
            newView.controller = self
            let wasFocused = currentView?.isFocused ?? false
            currentView?.removeFromSuperview()
            install(newView)
            currentView = newView
            currentMode = mode
            lastGeneration = -1
            if wasFocused || isActive { DispatchQueue.main.async { newView.focus() } }
        }
        if generation != lastGeneration || tab.id != lastTabID {
            lastGeneration = generation
            lastTabID = tab.id
            currentView?.reload(tab)
            currentView?.syncCursor(tab)
        }
    }

    private func install(_ v: NSView) {
        fileContainer.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        fileContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: fileContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: fileContainer.trailingAnchor),
            v.topAnchor.constraint(equalTo: fileContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: fileContainer.bottomAnchor),
        ])
    }

    private func updateStatus(_ tab: Tab) {
        let sel = tab.selectionSummary
        let total = tab.totalSummary
        var parts: [String] = []
        parts.append(L10n.tr("Zaznaczono \(sel.count) z \(total.files + total.directories), \(Format.bytes(sel.bytes)) z \(Format.bytes(total.bytes))"))
        if let v = tab.volume {
            parts.append(L10n.tr("Wolne: \(Format.bytes(v.availableCapacity)) z \(Format.bytes(v.totalCapacity))"))
        }
        if !tab.quickFilter.isEmpty { parts.append(L10n.tr("Filtr: \(tab.quickFilter)")) }
        statusBar.stringValue = parts.joined(separator: "   ·   ")
    }

    // MARK: Aktywacja i fokus

    func setActive(_ active: Bool) {
        isActive = active
        pathBar.isActive = active
        (view as? PanelRootView)?.isActive = active
    }

    func activate() {
        if workspace.activeSide != side { workspace.activeSide = side }
    }

    func focus() {
        if let currentView { view.window?.makeFirstResponder(currentView); currentView.focus() }
    }

    // MARK: Klawiatura

    /// Obsługa klawisza w widoku plików. Zwraca `false`, jeśli widok ma obsłużyć klawisz sam
    /// (strzałki, Page Up/Down, Home/End).
    func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        activate()

        if !quickSearch.isHidden {
            switch chord.key {
            case "escape":
                endQuickSearch()
                return true
            case "backspace" where chord.modifiers.isEmpty:
                quickSearch.text.removeLast()
                if quickSearch.text.isEmpty { endQuickSearch() } else { tab.quickSearch(quickSearch.text) }
                return true
            case "down" where chord.modifiers.contains(.control), "tab" where chord.modifiers.contains(.control):
                tab.quickSearch(quickSearch.text, startingAfterCursor: true)
                return true
            default:
                break
            }
        }

        if chord.key == "escape" && chord.modifiers.isEmpty {
            if !tab.quickFilter.isEmpty || !filterField.isHidden {
                closeFilter()
                return true
            }
            if !tab.selection.isEmpty {
                tab.clearSelection()
                return true
            }
        }

        // Litery bez Cmd/Ctrl rozpoczynają (lub kontynuują) szybkie wyszukiwanie.
        let typing = !chord.modifiers.contains(.command) && !chord.modifiers.contains(.control)
        if typing, let chars = event.characters, chars.count == 1, let ch = chars.first,
           !ch.isWhitespace, ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0.value < 0xF700 }),
           workspace.keymap.command(for: chord) == nil || !quickSearch.isHidden {
            if quickSearch.isHidden { quickSearch.text = "" }
            let candidate = quickSearch.text + String(ch)
            if tab.quickSearch(candidate) {
                quickSearch.text = candidate
                quickSearch.isHidden = false
            } else {
                NSSound.beep()
            }
            quickSearch.restartTimer { [weak self] in self?.endQuickSearch() }
            return true
        }

        if !quickSearch.isHidden { endQuickSearch() }

        if let id = workspace.keymap.command(for: chord) {
            workspace.perform(id)
            return true
        }
        return false
    }

    private func endQuickSearch() {
        quickSearch.isHidden = true
        quickSearch.text = ""
    }

    // MARK: Filtr

    func showFilter() {
        filterField.isHidden = false
        view.window?.makeFirstResponder(filterField)
    }

    func closeFilter() {
        tab.quickFilter = ""
        filterField.stringValue = ""
        filterField.isHidden = true
        focus()
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        tab.quickFilter = sender.stringValue
    }

    // MARK: Myszka

    func openItem(at index: Int) {
        tab.moveCursor(to: index)
        workspace.perform("panel.open")
    }

    func contextMenu(for index: Int?) -> NSMenu {
        if let index { tab.moveCursor(to: index) }
        let menu = NSMenu()
        let ids: [CommandID?] = [
            "panel.open", "tools.openWith", "view.quickLook", "file.view", "file.edit", nil,
            "file.copy", "file.move", "file.rename", "file.trash", nil,
            "clipboard.copyPaths", "clipboard.copyNames", nil,
            "file.tags", "file.attributes", "selection.calculateSizes", nil,
            "tools.share", "tools.revealInFinder",
        ]
        for id in ids {
            guard let id else { menu.addItem(.separator()); continue }
            guard let c = workspace.registry.command(id) else { continue }
            let item = NSMenuItem(title: c.descriptor.title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        activate()
        workspace.perform(CommandID(rawValue: raw))
    }
}

extension PanelViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            closeFilter()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            focus()
            return true
        default:
            return false
        }
    }
}

/// Tło panelu: aktywny panel ma wyraźną ramkę akcentu.
final class PanelRootView: NSView {
    var onMouseDown: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown || NSApp.currentEvent?.type == .rightMouseDown { onMouseDown?() }
        return hit
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isActive else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
    }

    override var isFlipped: Bool { false }
}

/// Nakładka szybkiego wyszukiwania (wpisywane litery).
final class QuickSearchOverlay: NSView {
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    var text = "" { didSet { label.stringValue = "🔍 " + text } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func restartTimer(_ expired: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated { expired() }
        }
    }
}
