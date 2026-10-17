import AppKit
import BifoldCore
import BifoldWorkspace

/// Drzewo katalogów obok listy plików: katalog domowy, dysk systemowy i woluminy.
final class DirectoryTreeView: NSView {
    var onNavigate: ((VFSPath) -> Void)?
    private let workspace: Workspace
    private let outline = TreeOutlineView()
    private let scroll = NSScrollView()
    private var roots: [TreeNode] = []
    private var revealing = false

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
        outline.owner = self
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
        reloadRoots()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reloadRoots() {
        var r = [TreeNode(path: .local(NSHomeDirectory()), title: L10n.tr("Katalog domowy"))]
        r.append(TreeNode(path: .root, title: "/"))
        for v in Volumes.mounted() where v.path != .root {
            r.append(TreeNode(path: v.path, title: v.name))
        }
        roots = r
        outline.reloadData()
    }

    /// Rozwija drzewo do podanej ścieżki i zaznacza ją.
    func reveal(_ path: VFSPath) {
        guard !isHidden else { return }
        let root = roots.filter { path.isDescendant(of: $0.path) }.max { $0.path.components.count < $1.path.components.count }
        guard var node = root else { return }
        revealing = true
        defer { revealing = false }
        outline.expandItem(node)
        let rest = path.components.dropFirst(node.path.components.count)
        for name in rest {
            guard let child = node.children(showHidden: workspace.settings.showHiddenFiles).first(where: { $0.path.name == name }) else { break }
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
        return node.children(showHidden: workspace.settings.showHiddenFiles).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return roots[index] }
        return node.children(showHidden: workspace.settings.showHiddenFiles)[index]
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
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.path.path)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !revealing, let node = outline.item(atRow: outline.selectedRow) as? TreeNode else { return }
        onNavigate?(node.path)
    }
}

final class TreeOutlineView: NSOutlineView {
    weak var owner: DirectoryTreeView?
}

final class TreeNode: NSObject {
    let path: VFSPath
    let title: String
    private var cached: [TreeNode]?

    init(path: VFSPath, title: String? = nil) {
        self.path = path
        self.title = title ?? path.name
    }

    func children(showHidden: Bool) -> [TreeNode] {
        if let cached { return cached }
        let items = (try? LocalFS().listSync(path)) ?? []
        let dirs = ListingProcessor.process(items.filter { $0.isNavigable }, in: .root, options: .init(showHidden: showHidden))
            .filter { !$0.isParentLink }
        let nodes = dirs.map { TreeNode(path: $0.path) }
        cached = nodes
        return nodes
    }
}
