import AppKit
import BifoldCore
import BifoldWorkspace
import QuickLookThumbnailing

/// Lista skrócona (kolumny nazw, przewijanie poziome) i miniatury (siatka z podglądami).
final class GridListView: NSView, FileListView {
    enum Style { case brief, thumbnails }

    weak var controller: PanelViewController?
    private let workspace: Workspace
    private let style: Style
    private let scroll = NSScrollView()
    let collection = FileCollectionView()
    private var items: [FileItem] = []
    private var tab: Tab?
    private var updatingSelection = false
    private let thumbnails = ThumbnailCache()

    init(workspace: Workspace, style: Style) {
        self.workspace = workspace
        self.style = style
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let layout = NSCollectionViewFlowLayout()
        switch style {
        case .brief:
            layout.scrollDirection = .horizontal
            layout.itemSize = NSSize(width: 220, height: 20)
            layout.minimumInteritemSpacing = 0
            layout.minimumLineSpacing = 8
            layout.sectionInset = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        case .thumbnails:
            layout.scrollDirection = .vertical
            layout.itemSize = NSSize(width: 120, height: 128)
            layout.minimumInteritemSpacing = 8
            layout.minimumLineSpacing = 8
            layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        }
        collection.owner = self
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.allowsEmptySelection = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(GridItem.self, forItemWithIdentifier: GridItem.id)
        collection.backgroundColors = [.controlBackgroundColor]

        scroll.documentView = collection
        scroll.hasVerticalScroller = style == .thumbnails
        scroll.hasHorizontalScroller = style == .brief
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload(_ tab: Tab) {
        self.tab = tab
        items = tab.visibleItems
        collection.reloadData()
    }

    func syncCursor(_ tab: Tab) {
        guard let index = tab.cursorIndex, index < items.count else { return }
        let path = IndexPath(item: index, section: 0)
        if !collection.selectionIndexPaths.contains(path) {
            updatingSelection = true
            collection.selectionIndexPaths = [path]
            updatingSelection = false
        }
        collection.scrollToItems(at: [path], scrollPosition: style == .brief ? .nearestVerticalEdge : .nearestHorizontalEdge)
        if style == .brief { collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge) }
    }

    func refreshMarks(_ tab: Tab) {
        for case let item as GridItem in collection.visibleItems() {
            if let ip = collection.indexPath(for: item), ip.item < items.count {
                configure(item, items[ip.item])
            }
        }
    }

    func focus() { window?.makeFirstResponder(collection) }
    var isFocused: Bool { window?.firstResponder === collection }

    fileprivate func configure(_ cell: GridItem, _ item: FileItem) {
        let marked = tab?.selection.contains(item.path) ?? false
        let style = item.isParentLink ? nil : workspace.colorRules.style(for: item)
        cell.label.attributedStringValue = NSAttributedString(string: item.name, attributes: Theme.attributes(size: CGFloat(workspace.settings.fontSize), style: style, marked: marked))
        cell.marked = marked
        let icon = IconCache.shared.icon(for: item)
        cell.icon.image = icon
        if self.style == .thumbnails, !item.isNavigable, let url = item.path.url {
            let path = item.path
            cell.representedPath = path
            thumbnails.thumbnail(for: url, size: NSSize(width: 96, height: 96)) { [weak cell] image in
                guard let cell, cell.representedPath == path, let image else { return }
                cell.icon.image = image
            }
        }
    }
}

extension GridListView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: GridItem.id, for: indexPath) as! GridItem
        cell.setStyle(style)
        if indexPath.item < items.count { configure(cell, items[indexPath.item]) }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !updatingSelection, let tab, let ip = indexPaths.first, ip.item < items.count else { return }
        tab.cursor = items[ip.item].path
    }
}

final class GridItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("grid-item")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    var representedPath: VFSPath?
    private var gridStyle: GridListView.Style = .brief
    var marked = false { didSet { updateBackground() } }

    override var isSelected: Bool { didSet { updateBackground() } }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        view = v
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        v.addSubview(icon)
        v.addSubview(label)
    }

    func setStyle(_ style: GridListView.Style) {
        guard view.constraints.isEmpty || gridStyle != style else { return }
        gridStyle = style
        NSLayoutConstraint.deactivate(view.constraints)
        switch style {
        case .brief:
            label.alignment = .left
            label.maximumNumberOfLines = 1
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        case .thumbnails:
            label.alignment = .center
            label.maximumNumberOfLines = 2
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: 96),
                icon.heightAnchor.constraint(equalToConstant: 88),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            ])
        }
    }

    private func updateBackground() {
        if isSelected {
            view.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).cgColor
        } else if marked {
            view.layer?.backgroundColor = Theme.markedBackground.cgColor
        } else {
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedPath = nil
        icon.image = nil
    }
}

final class FileCollectionView: NSCollectionView {
    weak var owner: GridListView?

    override func keyDown(with event: NSEvent) {
        if owner?.controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        owner?.controller?.activate()
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        owner?.controller?.activate()
        super.mouseDown(with: event)
        if event.clickCount == 2, let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            owner?.controller?.openItem(at: ip.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return owner?.controller?.contextMenu(for: ip?.item)
    }
}

/// Miniatury z QuickLook, buforowane w pamięci.
@MainActor
final class ThumbnailCache {
    private let cache = NSCache<NSURL, NSImage>()

    func thumbnail(for url: URL, size: NSSize, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage
            Task { @MainActor in
                if let image { self?.cache.setObject(image, forKey: url as NSURL) }
                completion(image)
            }
        }
    }
}
