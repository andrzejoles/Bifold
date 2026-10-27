import AppKit
import BifoldCore
import BifoldWorkspace

/// Widok kolumnowy jak w Finderze (`NSBrowser`). Katalog karty = katalog ostatniej kolumny
/// z zaznaczeniem, kursor = zaznaczony element. Tylko dysk lokalny — karty archiwum, serwera,
/// telefonu i wyników wyszukiwania pokazują w tym trybie widok szczegółów (`PanelViewController`).
/// Poziomy drzewa są wczytywane poza wątkiem głównym (katalog ze 100 000 plików nie zamraża okna).
final class ColumnListView: NSView, FileListView {
    weak var controller: PanelViewController?
    private let workspace: Workspace
    private let browser = NSBrowser()
    private let root = BrowserNode(path: .root, name: "/", isDirectory: true)
    private var tab: Tab?
    private var programmatic = false
    /// Ścieżka, dla której ostatnio zwolniono poziomy spoza bieżącej ścieżki.
    private var prunedFor: VFSPath?
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
                // Monitor widzi klawisze całej aplikacji — tylko zdarzenia z tego okna, gdy jest kluczowe
                // i przeglądarka ma fokus (inaczej arkusze i okna z polami tekstowymi traciłyby litery i Enter).
                guard let self, let window = self.window, event.window === window, window.isKeyWindow, self.isFocused else { return false }
                // Strzałki obsługuje przeglądarka (przechodzenie między kolumnami).
                if [123, 124, 125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
                return self.controller?.handleKey(event) == true
            }
            return consumed ? nil : event
        }
    }

    func reload(_ tab: Tab) {
        let first = self.tab == nil
        self.tab = tab
        root.onLoaded = { [weak self] node in self?.loaded(node) }
        if first {
            programmatic = true
            browser.loadColumnZero()
            programmatic = false
        } else {
            root.invalidate()
        }
        syncCursor(tab)
        if prunedFor != tab.path {
            prunedFor = tab.path
            prune(tab)
        }
    }

    /// Zwalnia wczytane poziomy katalogów spoza bieżącej ścieżki (i spoza kolumn, które przeglądarka
    /// jeszcze pokazuje) — inaczej każdy odwiedzony katalog zostawałby w pamięci, a każde odświeżenie
    /// przechodziło całe drzewo.
    private func prune(_ tab: Tab) {
        var keep = Set<VFSPath>()
        func keepWithAncestors(_ path: VFSPath) {
            var current: VFSPath? = path
            while let p = current, keep.insert(p).inserted { current = p.parent }
        }
        keepWithAncestors(cursorTarget(tab))
        keepWithAncestors(tab.path)
        if browser.lastColumn >= 1 {
            for column in 1...browser.lastColumn {
                if let node = browser.parentForItems(inColumn: column) as? BrowserNode { keepWithAncestors(node.path) }
            }
        }
        root.prune(keeping: keep)
    }

    private func cursorTarget(_ tab: Tab) -> VFSPath {
        tab.cursorItem.flatMap { $0.isParentLink ? nil : $0.path } ?? tab.path
    }

    func syncCursor(_ tab: Tab) {
        let comps = cursorTarget(tab).components
        programmatic = true
        defer { programmatic = false }
        var node = root
        for (column, name) in comps.enumerated() {
            // `reloadColumn` ustawia przeładowaną kolumnę jako ostatnią (zachowując w niej zaznaczenie) —
            // kolumny dalej trzeba dodać, zanim zaznaczy się w nich wiersz.
            guard column <= browser.lastColumn else { break }
            // Poziom jeszcze się wczytuje — dokończy `loaded(_:)`.
            guard let children = node.loadedChildren(showHidden: tab.showHidden) else { return }
            guard let row = children.firstIndex(where: { $0.name == name }) else { break }
            if browser.selectedRow(inColumn: column) != row {
                browser.selectRow(row, inColumn: column)
            }
            node = children[row]
            if column + 1 < comps.count, node.isDirectory, browser.lastColumn == column { browser.addColumn() }
        }
        browser.scrollColumnToVisible(min(browser.lastColumn, max(0, comps.count - 1)))
    }

    /// Oznaczenia i reguły kolorów — ponowne ustawienie komórek widocznych kolumn (w bardzo długiej
    /// kolumnie tylko okolicy zaznaczonego wiersza).
    func refreshMarks(_ tab: Tab) {
        self.tab = tab
        guard browser.lastColumn >= 0 else { return }
        programmatic = true
        defer { programmatic = false }
        let first = max(0, browser.firstVisibleColumn), last = min(browser.lastVisibleColumn, browser.lastColumn)
        guard first <= last else { return }
        for column in first...last {
            guard let parent = column == 0 ? root : browser.parentForItems(inColumn: column) as? BrowserNode else { continue }
            let children = parent.children(showHidden: tab.showHidden)
            let count = children.count
            guard count > 0 else { continue }
            var rows = 0..<count
            if count > 2000 {
                let selected = max(0, browser.selectedRow(inColumn: column))
                rows = max(0, selected - 300)..<min(count, selected + 300)
            }
            for row in rows {
                if let cell = browser.loadedCell(atRow: row, column: column) as? NSCell { configure(cell, children[row]) }
            }
            browser.setNeedsDisplay(browser.frame(ofColumn: column))
        }
    }

    /// Wczytany (albo zmieniony) poziom: przeładowanie jego kolumny i ponowne ustawienie kursora.
    private func loaded(_ node: BrowserNode) {
        guard let tab else { return }
        var column: Int?
        if node === root {
            column = 0
        } else if browser.lastColumn >= 1 {
            column = (1...browser.lastColumn).first { (browser.parentForItems(inColumn: $0) as? BrowserNode) === node }
        }
        if let column {
            programmatic = true
            browser.reloadColumn(column)
            programmatic = false
        }
        syncCursor(tab)
    }

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
            // Przez `Workspace.open` (jak inne nawigacje) — błąd wczytania katalogu jest pokazywany.
            guard let panel = controller?.panel else { return }
            Task { await workspace.openReportingError(parent, in: panel, focus: node.name) }
        } else {
            tab.cursor = node.path
        }
    }

    /// Podwójne kliknięcie pliku — komenda „Otwórz” (jak Enter). Plik w innej kolumnie niż bieżący
    /// katalog: najpierw nawigacja do jego katalogu (asynchroniczna), potem otwarcie.
    @objc private func doubleClicked() {
        guard let tab, let node = selectedNode(), !node.isDirectory, let parent = node.path.parent else { return }
        controller?.activate()
        if parent == tab.path {
            tab.cursor = node.path
            workspace.perform("panel.open")
        } else if let panel = controller?.panel {
            Task {
                // „panel.open” działa na aktywnej karcie — w czasie wczytywania mogła się zmienić
                // (Tab, kliknięcie w drugi panel); wtedy otwarty zostałby element drugiego panelu.
                guard let opened = await workspace.openReportingError(parent, in: panel, focus: node.name),
                      workspace.activeTab === opened, opened.cursor == node.path else { return }
                workspace.perform("panel.open")
            }
        }
    }

    private func selectedNode() -> BrowserNode? {
        let column = browser.selectedColumn
        guard column >= 0 else { return nil }
        let row = browser.selectedRow(inColumn: column)
        guard row >= 0, let parent = column == 0 ? root : browser.parentForItems(inColumn: column) as? BrowserNode else { return nil }
        let children = parent.children(showHidden: tab?.showHidden ?? false)
        return row < children.count ? children[row] : nil
    }

    private var marked: Set<VFSPath> { tab?.selection ?? [] }
}

extension ColumnListView: NSBrowserDelegate {
    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? BrowserNode ?? root).children(showHidden: tab?.showHidden ?? false).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        // Liczba dzieci mogła się zmienić od pytania o nią (wczytanie w tle) — węzeł zastępczy do
        // przeładowania kolumny zamiast wyjścia poza zakres.
        let children = (item as? BrowserNode ?? root).children(showHidden: tab?.showHidden ?? false)
        return children.indices.contains(index) ? children[index] : BrowserNode.placeholder
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        !((item as? BrowserNode)?.isDirectory ?? true)
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? BrowserNode)?.name
    }

    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSCell,
              let parent = column == 0 ? root : browser.parentForItems(inColumn: column) as? BrowserNode else { return }
        let children = parent.children(showHidden: tab?.showHidden ?? false)
        guard row < children.count else { return }
        configure(cell, children[row])
    }

    /// Oznaczenie i reguła kolorów jak w pozostałych widokach (kolor, pogrubienie, przekreślenie).
    /// Przeglądarka oparta na elementach podaje w macOS 27 `NSTextFieldCell` (nie `NSBrowserCell`) —
    /// ikona tylko, gdy komórka ją obsługuje; wcześniej przez to pomijane były też kolory reguł.
    fileprivate func configure(_ cell: NSCell, _ node: BrowserNode) {
        if let cell = cell as? NSBrowserCell {
            let image = IconCache.shared.icon(for: node.item)
            image.size = NSSize(width: 16, height: 16)
            cell.image = image
        }
        let style = workspace.colorRules.style(for: node.item)
        let isMarked = marked.contains(node.path)
        if style != nil || isMarked {
            cell.attributedStringValue = NSAttributedString(
                string: node.name, attributes: Theme.attributes(size: NSFont.systemFontSize, style: style, marked: isMarked, lineBreak: .byTruncatingMiddle))
        } else {
            cell.stringValue = node.name
        }
    }
}

/// Węzeł przeglądarki kolumnowej z dziećmi wczytywanymi leniwie poza wątkiem głównym.
/// Odświeżenie zachowuje węzły (i ich wczytane poziomy) o tych samych ścieżkach — kolumny nie migają.
final class BrowserNode: NSObject {
    /// Pusty liść podawany przeglądarce w miejsce wiersza, którego już nie ma.
    static let placeholder = BrowserNode(path: VFSPath(provider: ProviderID("placeholder"), path: "/"), name: "", isDirectory: false)

    let path: VFSPath
    let name: String
    let isDirectory: Bool
    private(set) var item: FileItem
    /// Wywoływane po zmianie dzieci węzła (ustawiane na korzeniu, przekazywane dzieciom).
    var onLoaded: ((BrowserNode) -> Void)?
    private var cached: [BrowserNode]?
    private var cachedHidden = false
    private var stale = false
    private var loadingHidden: Bool?

    init(path: VFSPath, name: String, isDirectory: Bool, item: FileItem? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.item = item ?? FileItem(path: path, name: name, kind: isDirectory ? .directory : .file)
    }

    /// Oznacza wczytane poziomy jako nieaktualne — zostaną wczytane ponownie przy następnym użyciu,
    /// a do tego czasu przeglądarka pokazuje poprzednią zawartość.
    /// Schodzi tylko do wczytanych poziomów (po `prune` — bieżąca ścieżka i pokazywane kolumny).
    func invalidate() {
        stale = true
        guard let cached else { return }
        for child in cached where child.cached != nil { child.invalidate() }
    }

    /// Zwalnia wczytane poziomy dzieci, których ścieżek nie ma w `keep` (`keep` zawiera przodków).
    func prune(keeping keep: Set<VFSPath>) {
        guard let cached else { return }
        for child in cached where child.cached != nil || child.loadingHidden != nil {
            if keep.contains(child.path) { child.prune(keeping: keep) } else { child.release() }
        }
    }

    /// Zapomina wczytane dzieci; trwające wczytanie zostanie pominięte (`finish` sprawdza `loadingHidden`).
    private func release() {
        cached = nil
        loadingHidden = nil
        stale = false
    }

    /// Dzieci, jeśli już wczytane (także nieaktualne albo z innym ustawieniem ukrytych plików — wtedy
    /// w tle wczytywane są nowe, a do ich nadejścia przeglądarka dostaje dotychczasową listę, zgodną
    /// z liczbą wierszy, którą już zna); `nil`, gdy poziom wczytuje się pierwszy raz.
    func loadedChildren(showHidden: Bool) -> [BrowserNode]? {
        guard isDirectory else { return [] }
        guard let cached else {
            startLoading(showHidden: showHidden)
            return nil
        }
        if cachedHidden != showHidden || stale {
            startLoading(showHidden: showHidden)
        } else if loadingHidden != nil, loadingHidden != showHidden {
            // Powrót do wczytanego wariantu — spóźniony wynik drugiego nie może go zastąpić.
            loadingHidden = nil
        }
        return cached
    }

    /// Dzieci dla przeglądarki (pusta lista, dopóki poziom się wczytuje).
    func children(showHidden: Bool) -> [BrowserNode] {
        loadedChildren(showHidden: showHidden) ?? []
    }

    private func startLoading(showHidden: Bool) {
        guard loadingHidden != showHidden else { return }
        loadingHidden = showHidden
        stale = false
        let path = path
        Task.detached(priority: .userInitiated) {
            let items = Self.list(path, showHidden: showHidden)
            await MainActor.run { self.finish(items, showHidden: showHidden) }
        }
    }

    private func finish(_ items: [FileItem], showHidden: Bool) {
        guard loadingHidden == showHidden else { return }
        loadingHidden = nil
        let previous = Dictionary((cached ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let unchanged = cachedHidden == showHidden && cached?.map(\.item) == items
        cached = items.map { item in
            if let node = previous[item.path], node.isDirectory == item.isNavigable {
                node.item = item
                return node
            }
            let node = BrowserNode(path: item.path, name: item.name, isDirectory: item.isNavigable, item: item)
            node.onLoaded = onLoaded
            return node
        }
        cachedHidden = showHidden
        if !unchanged { onLoaded?(self) }
    }

    nonisolated private static func list(_ path: VFSPath, showHidden: Bool) -> [FileItem] {
        guard let listed = try? LocalFS().listSync(path) else { return [] }
        return ListingProcessor.process(listed, in: .root, options: .init(showHidden: showHidden)).filter { !$0.isParentLink }
    }
}
