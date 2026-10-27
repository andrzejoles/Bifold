import AppKit
import BifoldCore
import BifoldWorkspace

/// Drzewo katalogów obok listy plików: katalog domowy, dysk systemowy i woluminy.
/// Poziomy wczytywane poza wątkiem głównym; przy nawigacji poziomy na ścieżce są wczytywane
/// ponownie (nowe katalogi), zmiana „Pokaż pliki ukryte” i podłączenie woluminu odświeżają drzewo.
final class DirectoryTreeView: NSView {
    var onNavigate: ((VFSPath) -> Void)?
    private let workspace: Workspace
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var roots: [TreeNode] = []
    private var revealing = false
    /// Ścieżka do pokazania, gdy wczytają się brakujące poziomy.
    private var pendingReveal: VFSPath?
    private var rootVolumes: [VFSPath] = []
    private var lastHidden: Bool?
    private let observations = ObservationBag()

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        outline.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.style = .sourceList
        outline.rowHeight = 20
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = true
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observations.add { [weak self] in
            guard let self else { return }
            // Woluminy podłączone i odłączone po starcie.
            let volumes = self.workspace.volumes.map(\.path).filter { $0 != .root }
            if volumes != self.rootVolumes || self.roots.isEmpty { self.reloadRoots() }
        }
        observations.add { [weak self] in
            guard let self else { return }
            let hidden = self.workspace.settings.showHiddenFiles
            guard hidden != self.lastHidden else { return }
            self.lastHidden = hidden
            self.outline.reloadData()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var showHidden: Bool { workspace.settings.showHiddenFiles }

    func reloadRoots() {
        let volumes = workspace.volumes.isEmpty ? Volumes.mounted() : workspace.volumes
        let previous = Dictionary(roots.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        func node(_ path: VFSPath, _ title: String) -> TreeNode {
            if let existing = previous[path], existing.title == title { return existing }
            let n = TreeNode(path: path, title: title, icon: NSWorkspace.shared.icon(forFile: path.path))
            n.onLoaded = { [weak self] node in self?.loaded(node) }
            return n
        }
        var r = [node(.local(NSHomeDirectory()), L10n.tr("Katalog domowy")), node(.root, "/")]
        for v in volumes where v.path != .root {
            r.append(node(v.path, v.name))
        }
        rootVolumes = workspace.volumes.map(\.path).filter { $0 != .root }
        roots = r
        outline.reloadData()
    }

    /// Wczytany (albo zmieniony) poziom — przeładowanie węzła i dokończenie odsłaniania ścieżki.
    private func loaded(_ node: TreeNode) {
        revealing = true
        if outline.row(forItem: node) >= 0 || roots.contains(node) {
            outline.reloadItem(node, reloadChildren: true)
        }
        revealing = false
        if let pendingReveal {
            self.pendingReveal = nil
            reveal(pendingReveal, refresh: false)
        }
    }

    /// Rozwija drzewo do podanej ścieżki i zaznacza ją.
    /// - Parameter refresh: poziomy na ścieżce są wczytywane ponownie (nowe lub usunięte katalogi).
    func reveal(_ path: VFSPath, refresh: Bool = true) {
        // Nowe odsłanianie zastępuje odłożone — inaczej wczytany później poziom zaznaczyłby katalog,
        // którego panel już nie pokazuje (także gdy drzewo jest ukryte albo ścieżka spoza korzeni).
        pendingReveal = nil
        guard !isHidden else { return }
        let root = roots.filter { path.isDescendant(of: $0.path) }.max { $0.path.components.count < $1.path.components.count }
        guard var node = root else { return }
        revealing = true
        defer { revealing = false }
        if refresh { node.markStale() }
        outline.expandItem(node)
        let rest = path.components.dropFirst(node.path.components.count)
        for name in rest {
            // Poziom jeszcze się wczytuje — `loaded(_:)` dokończy odsłanianie.
            guard let children = node.loadedChildren(showHidden: showHidden) else {
                pendingReveal = path
                return
            }
            guard let child = children.first(where: { $0.path.name == name }) else { break }
            if refresh { child.markStale() }
            outline.expandItem(node)
            node = child
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }
}

extension DirectoryTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return roots.count }
        return node.children(showHidden: showHidden).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return roots[index] }
        let children = node.children(showHidden: showHidden)
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("tree-cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(image)
            c.addSubview(text)
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = node.title
        // Ikona katalogu z pamięci podręcznej (pobieranie ikony dla każdej komórki było wolne).
        cell.imageView?.image = node.icon ?? IconCache.shared.icon(for: node.item)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !revealing, let node = outline.item(atRow: outline.selectedRow) as? TreeNode else { return }
        onNavigate?(node.path)
    }
}

final class TreeNode: NSObject {
    let path: VFSPath
    let title: String
    /// Własna ikona (korzenie: dom, dysk, woluminy); katalogi — z `IconCache`.
    let icon: NSImage?
    var onLoaded: ((TreeNode) -> Void)?
    private var cached: [TreeNode]?
    private var cachedHidden = false
    private var stale = false
    private var loadingHidden: Bool?

    init(path: VFSPath, title: String? = nil, icon: NSImage? = nil) {
        self.path = path
        self.title = title ?? path.name
        self.icon = icon
    }

    var item: FileItem { FileItem(path: path, name: path.name, kind: .directory) }

    /// Przy następnym użyciu poziom zostanie wczytany ponownie (do tego czasu stara zawartość).
    func markStale() { stale = true }

    /// Podkatalogi, jeśli wczytane; `nil` (i wczytywanie w tle), gdy poziom jeszcze się wczytuje.
    func loadedChildren(showHidden: Bool) -> [TreeNode]? {
        if let cached, cachedHidden == showHidden {
            if stale { startLoading(showHidden: showHidden) }
            return cached
        }
        startLoading(showHidden: showHidden)
        return nil
    }

    func children(showHidden: Bool) -> [TreeNode] {
        loadedChildren(showHidden: showHidden) ?? []
    }

    private func startLoading(showHidden: Bool) {
        guard loadingHidden != showHidden else { return }
        loadingHidden = showHidden
        stale = false
        let path = path
        Task.detached(priority: .userInitiated) {
            let dirs = Self.listDirectories(path, showHidden: showHidden)
            await MainActor.run { self.finish(dirs, showHidden: showHidden) }
        }
    }

    private func finish(_ dirs: [VFSPath], showHidden: Bool) {
        guard loadingHidden == showHidden else { return }
        loadingHidden = nil
        let unchanged = cachedHidden == showHidden && cached?.map(\.path) == dirs
        cachedHidden = showHidden
        guard !unchanged else { return }
        let previous = Dictionary((cached ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        cached = dirs.map { dir in
            if let node = previous[dir] { return node }
            let node = TreeNode(path: dir)
            node.onLoaded = onLoaded
            return node
        }
        onLoaded?(self)
    }

    nonisolated private static func listDirectories(_ path: VFSPath, showHidden: Bool) -> [VFSPath] {
        let items = (try? LocalFS().listSync(path)) ?? []
        return ListingProcessor.process(items.filter { $0.isNavigable }, in: .root, options: .init(showHidden: showHidden))
            .filter { !$0.isParentLink }
            .map(\.path)
    }
}
