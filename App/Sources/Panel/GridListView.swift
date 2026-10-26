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

    /// Szerokość komórki miniatury (etykieta pod ikoną zawija się w tej szerokości).
    static let thumbnailItemWidth: CGFloat = 120
    private let layout = NSCollectionViewFlowLayout()
    private var layoutFontSize: CGFloat = 0

    private var fontSize: CGFloat { CGFloat(workspace.settings.fontSize) }

    /// Rozmiar komórki dla bieżącej czcionki: skrócony — wysokość wiersza z czcionki, miniatury —
    /// ikona i etykieta w dwóch liniach.
    private func itemSize(for size: CGFloat) -> NSSize {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let line = ceil(font.ascender - font.descender + font.leading)
        switch style {
        case .brief: return NSSize(width: 220, height: max(20, line + 5))
        case .thumbnails: return NSSize(width: Self.thumbnailItemWidth, height: 4 + 88 + 2 + 2 * line + 6)
        }
    }

    private func updateItemSize() {
        guard layoutFontSize != fontSize else { return }
        layoutFontSize = fontSize
        layout.itemSize = itemSize(for: fontSize)
        layout.invalidateLayout()
    }

    private func setup() {
        switch style {
        case .brief:
            layout.scrollDirection = .horizontal
            layout.minimumInteritemSpacing = 0
            layout.minimumLineSpacing = 8
            layout.sectionInset = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        case .thumbnails:
            layout.scrollDirection = .vertical
            layout.minimumInteritemSpacing = 8
            layout.minimumLineSpacing = 8
            layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        }
        updateItemSize()
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
        updateItemSize()
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

    /// Oznaczenia, reguły kolorów i czcionka — tylko etykiety i tło (bez ponownego żądania miniatur).
    func refreshMarks(_ tab: Tab) {
        if layoutFontSize != fontSize {
            updateItemSize()
            collection.reloadData()
            return
        }
        for case let item as GridItem in collection.visibleItems() {
            if let ip = collection.indexPath(for: item), ip.item < items.count {
                configureAppearance(item, items[ip.item])
            }
        }
    }

    func focus() { window?.makeFirstResponder(collection) }
    var isFocused: Bool { window?.firstResponder === collection }

    fileprivate func configure(_ cell: GridItem, _ item: FileItem) {
        configureAppearance(cell, item)
        cell.icon.image = IconCache.shared.icon(for: item)
        cell.representedPath = item.path
        // Pusty plik nie ma czego pokazać w podglądzie (byłaby pusta kartka) — zostaje ikona typu.
        if self.style == .thumbnails, !item.isNavigable, item.size != 0, let url = item.path.url {
            let path = item.path
            cell.thumbnailRequest = thumbnails.thumbnail(for: url, item: item, size: NSSize(width: 96, height: 96)) { [weak cell] image in
                guard let cell, cell.representedPath == path else { return }
                cell.thumbnailRequest = nil
                if let image { cell.icon.image = image }
            }
        }
    }

    /// Etykieta (oznaczenie, reguła kolorów, czcionka) i tło komórki.
    private func configureAppearance(_ cell: GridItem, _ item: FileItem) {
        let marked = tab?.selection.contains(item.path) ?? false
        let style = item.isParentLink ? nil : workspace.colorRules.style(for: item)
        // Miniatury: zawijanie słów, a ostatnia z dwóch linii z wielokropkiem (truncatesLastVisibleLine);
        // skrócony: jedna linia z wielokropkiem w środku.
        let lineBreak: NSLineBreakMode = cell.label.maximumNumberOfLines == 1 ? .byTruncatingMiddle : .byWordWrapping
        cell.label.attributedStringValue = NSAttributedString(
            string: item.name, attributes: Theme.attributes(size: fontSize, style: style, marked: marked, lineBreak: lineBreak))
        cell.marked = marked
        cell.ruleBackground = style?.backgroundColor.map(Theme.color)
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
    /// Trwające żądanie miniatury (anulowane przy ponownym użyciu komórki).
    var thumbnailRequest: QLThumbnailGenerator.Request?
    private var gridStyle: GridListView.Style = .brief
    var marked = false { didSet { if marked != oldValue { updateBackground() } } }
    var ruleBackground: NSColor? { didSet { if ruleBackground != oldValue { updateBackground() } } }

    override var isSelected: Bool { didSet { updateBackground() } }

    override func loadView() {
        let v = GridItemView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        // Kolory warstwy (CGColor) nie śledzą motywu — ponowne ustawienie po zmianie wyglądu.
        v.onAppearanceChange = { [weak self] in self?.updateBackground() }
        view = v
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.allowsExpansionToolTips = true
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
            label.cell?.wraps = false
            label.preferredMaxLayoutWidth = 0
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
            label.cell?.wraps = true
            // Szerokość komórki minus marginesy — bez niej wieloliniowe pole w Auto Layout obcina drugą
            // linię bez wielokropka.
            label.preferredMaxLayoutWidth = GridListView.thumbnailItemWidth - 4
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
        let color: NSColor
        if isSelected {
            color = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45)
        } else if marked {
            color = Theme.markedBackground
        } else {
            color = ruleBackground ?? .clear
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = color.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        thumbnailRequest = nil
        representedPath = nil
        icon.image = nil
    }
}

/// Widok komórki siatki zgłaszający zmianę wyglądu (jasny/ciemny).
final class GridItemView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
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
        // Cmd+klik oznacza plik (jak w widoku szczegółów i Ctrl+klik w TC), zamiast zmieniać kursor.
        if event.modifierFlags.contains(.command) {
            if let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)), let tab = owner?.controller?.tab,
               ip.item < tab.visibleItems.count {
                tab.toggleSelection(tab.visibleItems[ip.item].path)
            }
            return
        }
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

/// Miniatury z QuickLook, buforowane w pamięci (ograniczona liczba; klucz z datą modyfikacji
/// i rozmiarem — edytowany plik dostaje nową miniaturę).
@MainActor
final class ThumbnailCache {
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    /// - Returns: żądanie do anulowania (`nil`, gdy miniatura była w pamięci).
    @discardableResult
    func thumbnail(for url: URL, item: FileItem, size: NSSize, completion: @escaping @MainActor (NSImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let key = "\(url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size)"
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return nil
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        // Jak w Finderze: dokument w ramce z zagiętym rogiem — biała strona tekstu bez ramki ginęła na białym tle.
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            // Pusty podgląd (np. pusty plik tekstowy — biała strona bez treści) nic nie mówi: zostaje
            // ikona typu pliku. Nie trafia do pamięci podręcznej — plik może zaraz dostać treść.
            let image = rep.flatMap { Self.isBlank($0.cgImage) ? nil : $0.nsImage }
            Task { @MainActor in
                if let image { self?.cache.setObject(image, forKey: key as NSString) }
                completion(image)
            }
        }
        return request
    }

    /// Obraz jednolity (jeden kolor) w próbce 32×32 — w mniejszej próbce plik z jednym znakiem też
    /// wyglądałby na pusty.
    nonisolated static func isBlank(_ image: CGImage) -> Bool {
        let side = 32
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt32.self, capacity: side * side)
        let first = pixels[0]
        return (1..<side * side).allSatisfy { pixels[$0] == first }
    }
}
