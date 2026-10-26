import AppKit
import BifoldCore
import BifoldWorkspace

/// Widok szczegółów (`NSTableView`). Wiersz zaznaczony w tabeli = kursor modelu;
/// pliki oznaczone (Spacja, maska) są wyróżnione kolorem jak w Total Commanderze.
final class DetailsListView: NSView, FileListView {
    weak var controller: PanelViewController?
    private let workspace: Workspace
    private let scroll = NSScrollView()
    let table = FileTableView()
    private var items: [FileItem] = []
    /// Numer wiersza według ścieżki (odświeżanie wiersza po wczytaniu tagów bez szukania liniowego).
    private var rowByPath: [VFSPath: Int] = [:]
    private var tab: Tab?
    private var updatingSelection = false
    private var tagCache: [VFSPath: [String]] = [:]

    private enum Column: String, CaseIterable {
        case name, ext, size, modified, attributes, tags

        var title: String {
            switch self {
            case .name: L10n.tr("Nazwa")
            case .ext: L10n.tr("Rozsz.")
            case .size: L10n.tr("Rozmiar")
            case .modified: L10n.tr("Data")
            case .attributes: L10n.tr("Atrybuty")
            case .tags: L10n.tr("Tagi")
            }
        }

        var sortField: SortField? {
            switch self {
            case .name: .name
            case .ext: .ext
            case .size: .size
            case .modified: .modified
            default: nil
            }
        }
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        table.owner = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.autosaveName = "DetailsTable"
        table.autosaveTableColumns = true
        table.focusRingType = .none

        for col in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = col.title
            switch col {
            case .name: c.width = 280; c.minWidth = 120
            case .ext: c.width = 56
            case .size: c.width = 96; c.headerCell.alignment = .right
            case .modified: c.width = 124
            case .attributes: c.width = 84
            case .tags: c.width = 90
            }
            if let field = col.sortField {
                c.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
            }
            table.addTableColumn(c)
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    var fontSize: CGFloat { CGFloat(workspace.settings.fontSize) }
    private var rowHeightForFont: CGFloat { max(18, fontSize + 7) }

    func reload(_ tab: Tab) {
        self.tab = tab
        items = tab.visibleItems
        rowByPath = Dictionary(items.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        tagCache = [:]
        table.rowHeight = rowHeightForFont
        let field = tab.sort.field
        updatingSelection = true
        if let col = Column.allCases.first(where: { $0.sortField == field }) {
            table.sortDescriptors = [NSSortDescriptor(key: col.sortField!.rawValue, ascending: tab.sort.ascending)]
        } else {
            // Sortowanie bez kolumny (data utworzenia) — bez strzałki przy poprzedniej kolumnie.
            table.sortDescriptors = []
        }
        updatingSelection = false
        table.reloadData()
    }

    func syncCursor(_ tab: Tab) {
        guard let index = tab.cursorIndex, index < table.numberOfRows else { return }
        if table.selectedRow != index {
            updatingSelection = true
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            updatingSelection = false
        }
        table.scrollRowToVisible(index)
    }

    func refreshMarks(_ tab: Tab) {
        // Zmiana rozmiaru czcionki — nowa wysokość wierszy.
        if table.rowHeight != rowHeightForFont {
            table.rowHeight = rowHeightForFont
            table.reloadData()
            return
        }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        for row in visible.location..<(visible.location + visible.length) where row < items.count {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? MarkedRowView else { continue }
            configure(rowView, items[row])
        }
    }

    /// Tło wiersza: oznaczenie albo tło z reguły kolorów.
    private func configure(_ rowView: MarkedRowView, _ item: FileItem) {
        rowView.marked = isMarked(item)
        rowView.ruleBackground = item.isParentLink ? nil : workspace.colorRules.style(for: item)?.backgroundColor.map(Theme.color)
    }

    func focus() { window?.makeFirstResponder(table) }
    var isFocused: Bool { window?.firstResponder === table }

    @objc private func doubleClick() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        controller?.openItem(at: row)
    }

    fileprivate func isMarked(_ item: FileItem) -> Bool { tab?.selection.contains(item.path) ?? false }

    /// Tagi czytane w tle (getxattr na plikach w chmurze — OneDrive, iCloud — potrafi blokować),
    /// po odczycie odświeżany jest tylko ten wiersz.
    fileprivate func tags(for item: FileItem) -> [String] {
        if let t = tagCache[item.path] { return t }
        tagCache[item.path] = []
        let path = item.path
        TagLoader.shared.load(path) { [weak self] tags in
            guard let self, !tags.isEmpty else { return }
            self.tagCache[path] = tags
            if let row = self.rowByPath[path], row < self.items.count, let col = self.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "tags" }) {
                self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
            }
        }
        return []
    }
}

extension DetailsListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < items.count, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = items[row]
        let marked = isMarked(item)
        let style = item.isParentLink ? nil : workspace.colorRules.style(for: item)
        let cell = makeCell(column, tableView)
        let text: String
        var secondary = false
        switch column {
        case .name where tab?.isSearchResults == true:
            // Wyniki wyszukiwania: pełna ścieżka (elementy z różnych katalogów).
            text = (item.path.path as NSString).abbreviatingWithTildeInPath
            cell.imageView?.image = IconCache.shared.icon(for: item)
        case .name:
            text = item.isNavigable || item.isParentLink ? item.name : (item.fileExtension.isEmpty ? item.name : item.name.fileStem)
            cell.imageView?.image = IconCache.shared.icon(for: item)
        case .ext:
            text = item.isNavigable ? "" : item.fileExtension
        case .size:
            text = tab.map { Formatters.size(item, directorySize: $0.directorySizes[item.path]) } ?? ""
            secondary = true
        case .modified:
            text = item.isParentLink ? "" : item.modified.map { Formatters.date.string(from: $0) } ?? ""
            secondary = true
        case .attributes:
            text = item.isParentLink ? "" : Formatters.permissions(item)
            secondary = true
        case .tags:
            text = item.isParentLink ? "" : tags(for: item).joined(separator: ", ")
            secondary = true
        }
        cell.textField?.attributedStringValue = NSAttributedString(string: text, attributes: Theme.attributes(size: fontSize, style: style, marked: marked, secondary: secondary && !marked))
        cell.textField?.alignment = column == .size ? .right : .left
        return cell
    }

    private func makeCell(_ column: Column, _ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("cell-\(column.rawValue)")
        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        // Obcięta nazwa — pełna w podpowiedzi po najechaniu (jak w Finderze).
        field.allowsExpansionToolTips = true
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        if column == .name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ])
        } else {
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = (tableView.makeView(withIdentifier: MarkedRowView.id, owner: nil) as? MarkedRowView) ?? MarkedRowView()
        view.identifier = MarkedRowView.id
        if row < items.count { configure(view, items[row]) } else { view.marked = false; view.ruleBackground = nil }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, let tab, table.selectedRow >= 0, table.selectedRow < items.count else { return }
        tab.cursor = items[table.selectedRow].path
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !updatingSelection, let tab, let d = tableView.sortDescriptors.first, let key = d.key, let field = SortField(rawValue: key) else { return }
        tab.sort = SortSpec(field: field, ascending: d.ascending)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { nil }
}

/// Tło wiersza z oznaczonym plikiem albo z tłem reguły kolorów (`backgroundColor`).
final class MarkedRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("marked-row")
    var marked = false { didSet { if marked != oldValue { needsDisplay = true } } }
    var ruleBackground: NSColor? { didSet { if ruleBackground != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if marked {
            Theme.markedBackground.setFill()
            bounds.fill()
        } else if let ruleBackground {
            ruleBackground.setFill()
            bounds.fill()
        }
    }
}

/// Tabela przekazująca klawisze do panelu (skróty TC, szybkie wyszukiwanie).
final class FileTableView: NSTableView {
    weak var owner: DetailsListView?

    override func keyDown(with event: NSEvent) {
        if owner?.controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        owner?.controller?.activate()
        return super.becomeFirstResponder()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return owner?.controller?.contextMenu(for: row >= 0 ? row : nil)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.controller?.activate()
        // Cmd+klik oznacza plik (jak Ctrl+klik w TC), zamiast zmieniać kursor.
        if event.modifierFlags.contains(.command) {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0, let tab = owner?.controller?.tab, row < tab.visibleItems.count {
                tab.toggleSelection(tab.visibleItems[row].path)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

/// Odczyt tagów Findera poza głównym wątkiem (jedna kolejka, żeby zablokowany plik w chmurze
/// nie zajął wielu wątków).
final class TagLoader: @unchecked Sendable {
    static let shared = TagLoader()
    private let queue = DispatchQueue(label: "bifold.tags", qos: .utility)

    func load(_ path: VFSPath, completion: @escaping @MainActor ([String]) -> Void) {
        queue.async {
            let tags = (try? LocalFS().tagsSync(of: path)) ?? []
            Task { @MainActor in completion(tags) }
        }
    }
}
