import AppKit
import BifoldCore
import BifoldWorkspace

/// Widok kolumnowy jak w Finderze (`NSBrowser`). Katalog karty = katalog ostatniej kolumny
/// z zaznaczeniem, kursor = zaznaczony element.
final class ColumnListView: NSView, FileListView {
    weak var controller: PanelViewController?
    private let workspace: Workspace
    private let browser = NSBrowser()
    private let root = BrowserNode(path: .root, name: "/", isDirectory: true)
    private var tab: Tab?
    private var programmatic = false
    private var keyMonitor: Any?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        browser.delegate = self
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.doubleAction = #selector(doubleClicked)
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 160
        browser.setDefaultColumnWidth(220)
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.allowsMultipleSelection = false
        browser.translatesAutoresizingMaskIntoConstraints = false
        addSubview(browser)
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: trailingAnchor),
            browser.topAnchor.constraint(equalTo: topAnchor),
            browser.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] incoming in
            nonisolated(unsafe) let event = incoming
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isFocused else { return false }
                // Strzałki obsługuje przeglądarka (przechodzenie między kolumnami).
                if [123, 124, 125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
                return self.controller?.handleKey(event) == true
            }
            return consumed ? nil : event
        }
    }

    func reload(_ tab: Tab) {
        self.tab = tab
        root.invalidate()
        programmatic = true
        browser.loadColumnZero()
        programmatic = false
        syncCursor(tab)
    }

    func syncCursor(_ tab: Tab) {
        let target = tab.cursorItem.flatMap { $0.isParentLink ? nil : $0.path } ?? tab.path
        let comps = target.components
        programmatic = true
        defer { programmatic = false }
        var node = root
        for (column, name) in comps.enumerated() {
            let children = node.children(showHidden: tab.showHidden)
            guard let row = children.firstIndex(where: { $0.name == name }) else { break }
            if browser.selectedRow(inColumn: column) != row {
                browser.selectRow(row, inColumn: column)
            }
            node = children[row]
        }
        browser.scrollColumnToVisible(max(0, comps.count - 1))
    }

    func refreshMarks(_ tab: Tab) {}

    func focus() { window?.makeFirstResponder(browser) }

    var isFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === browser || responder.isDescendant(of: browser)
    }

    @objc private func selectionChanged() {
        guard !programmatic, let tab, let node = browser.selectedCell().flatMap({ _ in selectedNode() }) else { return }
        controller?.activate()
        guard let parent = node.path.parent else { return }
        if parent != tab.path {
            Task { try? await tab.navigate(to: parent, focus: node.name) }
        } else {
            tab.cursor = node.path
        }
    }

    @objc private func doubleClicked() {
        guard let node = selectedNode(), !node.isDirectory, let url = node.path.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func selectedNode() -> BrowserNode? {
        let column = browser.selectedColumn
        guard column >= 0 else { return nil }
        let row = browser.selectedRow(inColumn: column)
        guard row >= 0, let parent = column == 0 ? root : browser.parentForItems(inColumn: column) as? BrowserNode else { return nil }
        let children = parent.children(showHidden: tab?.showHidden ?? false)
        return row < children.count ? children[row] : nil
    }
}

extension ColumnListView: NSBrowserDelegate {
    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? BrowserNode ?? root).children(showHidden: tab?.showHidden ?? false).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        (item as? BrowserNode ?? root).children(showHidden: tab?.showHidden ?? false)[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        !((item as? BrowserNode)?.isDirectory ?? true)
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? BrowserNode)?.name
    }

    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell,
              let parent = column == 0 ? root : browser.parentForItems(inColumn: column) as? BrowserNode else { return }
        let children = parent.children(showHidden: tab?.showHidden ?? false)
        guard row < children.count else { return }
        let node = children[row]
        let image = IconCache.shared.icon(for: node.item)
        image.size = NSSize(width: 16, height: 16)
        cell.image = image
        if let style = workspace.colorRules.style(for: node.item), let c = style.textColor {
            cell.attributedStringValue = NSAttributedString(string: node.name, attributes: [.foregroundColor: Theme.color(c)])
        }
    }
}

/// Węzeł przeglądarki kolumnowej z leniwie wczytywanymi dziećmi.
final class BrowserNode: NSObject {
    let path: VFSPath
    let name: String
    let isDirectory: Bool
    let item: FileItem
    private var cached: [BrowserNode]?
    private var cachedHidden = false

    init(path: VFSPath, name: String, isDirectory: Bool, item: FileItem? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.item = item ?? FileItem(path: path, name: name, kind: isDirectory ? .directory : .file)
    }

    func invalidate() { cached = nil }

    func children(showHidden: Bool) -> [BrowserNode] {
        if let cached, cachedHidden == showHidden { return cached }
        guard isDirectory, let listed = try? LocalFS().listSync(path) else { return [] }
        let sorted = ListingProcessor.process(listed, in: .root, options: .init(showHidden: showHidden))
        let nodes = sorted.filter { !$0.isParentLink }.map {
            BrowserNode(path: $0.path, name: $0.name, isDirectory: $0.isNavigable, item: $0)
        }
        cached = nodes
        cachedHidden = showHidden
        return nodes
    }
}
