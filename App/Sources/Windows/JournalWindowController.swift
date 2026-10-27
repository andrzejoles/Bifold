import AppKit
import BifoldCore
import BifoldWorkspace

/// Dziennik operacji na plikach: lista partii (od najnowszej) z możliwością cofnięcia wybranej.
/// Lista jest migawką dziennika — odświeżana, gdy okno staje się kluczowe (Cmd+Z w oknie głównym)
/// i gdy zmienia się stan zadań w kolejce („w toku” → zakończona).
final class JournalWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let table = NSTableView()
    private let details = NSTextView()
    private var batches: [JournalBatch] = []
    private var undoButton: NSButton!
    /// Cofanie z tego okna trwa — przycisk wyłączony do końca (dwa kliknięcia cofałyby partię dwa razy).
    private var undoing = false
    private let observations = ObservationBag()

    init(workspace: Workspace) {
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Dziennik operacji")
        window.setFrameAutosaveName("JournalWindow")
        super.init(window: window)
        window.delegate = self
        build()
        observations.add { [weak self] in
            guard let self else { return }
            // Zakończenie, anulowanie albo nowe zadanie zmienia stan partii w dzienniku.
            _ = self.workspace.jobs.jobs.map(\.state)
            if self.window?.isVisible == true { self.reload() }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        for (id, title, width) in [("date", L10n.tr("Czas"), 140.0), ("title", L10n.tr("Operacja"), 360.0), ("who", L10n.tr("Kto"), 160.0), ("count", L10n.tr("Wpisy"), 60.0), ("state", L10n.tr("Stan"), 90.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let detailScroll = NSScrollView()
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailScroll.documentView = details
        detailScroll.hasVerticalScroller = true
        details.autoresizingMask = [.width]
        let undo = NSButton(title: L10n.tr("Cofnij zaznaczoną operację"), target: self, action: #selector(undoSelected))
        undo.isEnabled = false
        undoButton = undo
        let refresh = NSButton(title: L10n.tr("Odśwież"), target: self, action: #selector(refreshClicked))
        let buttons = NSStackView(views: [undo, refresh, NSView()])
        let split = NSSplitView()
        split.isVertical = false
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detailScroll)
        let stack = NSStackView(views: [split, buttons])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    private func reload() {
        // Zaznaczenie idzie za partią (nowa partia na górze przesuwa wiersze).
        let selected = table.selectedRow >= 0 && table.selectedRow < batches.count ? batches[table.selectedRow].id : nil
        batches = workspace.journal.batches.reversed()
        table.reloadData()
        if let selected, let row = batches.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updateSelection()
    }

    /// Stan partii: trwające zadanie, cofnięta (cała albo wszystkie odwracalne wpisy), częściowo cofnięta,
    /// nieodwracalna; pusty, gdy można ją cofnąć w całości.
    private func stateText(_ b: JournalBatch) -> String {
        if b.undone { return L10n.tr("cofnięta") }
        if !b.finished { return L10n.tr("w toku") }
        if b.entries.contains(where: \.undone) { return b.isUndoable ? L10n.tr("częściowo cofnięta") : L10n.tr("cofnięta") }
        return b.isUndoable ? "" : L10n.tr("nieodwracalna")
    }

    @objc private func refreshClicked() { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { batches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let b = batches[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = Formatters.date.string(from: b.date)
        case "title": text = b.title
        case "who":
            switch b.invoker {
            case .user: text = L10n.tr("użytkownik")
            case let .agent(session, name): text = "\(name) (\(session.prefix(6)))"
            }
        case "count": text = "\(b.entries.count)"
        default: text = stateText(b)
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    /// Szczegóły zaznaczonej partii (cofnięte wpisy oznaczone) i dostępność „Cofnij”.
    private func updateSelection() {
        guard table.selectedRow >= 0, table.selectedRow < batches.count else {
            details.string = ""
            undoButton.isEnabled = false
            return
        }
        let b = batches[table.selectedRow]
        undoButton.isEnabled = b.isUndoable && !undoing
        let undoneMark = "  " + L10n.tr("(cofnięto)")
        details.string = b.entries.map { entry in
            let line = switch entry.action {
            case let .created(p, dir): "+ \(dir ? "📁" : "📄") \(p.path)"
            case let .copied(f, t): "⧉ \(f.path) → \(t.path)"
            case let .moved(f, t): "→ \(f.path) → \(t.path)"
            case let .trashed(o, t): "🗑 \(o.path)  (\(t.path))"
            case let .removedEmptyDirectory(p): "− 📁 \(p.path)"
            case let .attributesChanged(p, _, _): "⚙︎ \(p.path)"
            case let .tagsChanged(p, b, a): "🏷 \(p.path): \(b) → \(a)"
            case let .deletedPermanently(p): "✕ \(p.path)"
            }
            return entry.undone ? line + undoneMark : line
        }.joined(separator: "\n")
    }

    @objc private func undoSelected() {
        guard !undoing, table.selectedRow >= 0, table.selectedRow < batches.count else { return }
        // Partia świeżo z dziennika, nie z migawki listy (mogła zostać cofnięta Cmd+Z w oknie głównym).
        let id = batches[table.selectedRow].id
        guard workspace.journal.batch(id)?.isUndoable == true else {
            reload()
            return
        }
        undoing = true
        undoButton.isEnabled = false
        Task {
            defer {
                undoing = false
                reload()
            }
            // Przez komendę „Cofnij operację” z identyfikatorem partii — plan, pytanie o konflikty i odświeżenie
            // paneli jak przy Cmd+Z (komenda sama sprawdza, czy partia jest nadal cofalna).
            do {
                let result = try await workspace.invoke("edit.undo", CommandArguments(["batch": .string(id.uuidString)]))
                if let message = result.message { workspace.setStatus(message) }
            } catch CommandError.cancelledByUser {
            } catch VFSError.cancelled {
            } catch {
                workspace.ui?.showError(error.localizedDescription)
            }
        }
    }
}
