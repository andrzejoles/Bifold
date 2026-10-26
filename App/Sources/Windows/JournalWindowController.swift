import AppKit
import BifoldCore
import BifoldWorkspace

/// Dziennik operacji na plikach: lista partii (od najnowszej) z możliwością cofnięcia wybranej.
final class JournalWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let table = NSTableView()
    private let details = NSTextView()
    private var batches: [JournalBatch] = []

    init(workspace: Workspace) {
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Dziennik operacji")
        window.setFrameAutosaveName("JournalWindow")
        super.init(window: window)
        build()
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
        batches = workspace.journal.batches.reversed()
        table.reloadData()
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
        default: text = b.undone ? L10n.tr("cofnięta") : (b.isUndoable ? "" : L10n.tr("nieodwracalna"))
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { details.string = ""; return }
        let b = batches[table.selectedRow]
        details.string = b.entries.map { entry in
            switch entry.action {
            case let .created(p, dir): "+ \(dir ? "📁" : "📄") \(p.path)"
            case let .copied(f, t): "⧉ \(f.path) → \(t.path)"
            case let .moved(f, t): "→ \(f.path) → \(t.path)"
            case let .trashed(o, t): "🗑 \(o.path)  (\(t.path))"
            case let .removedEmptyDirectory(p): "− 📁 \(p.path)"
            case let .attributesChanged(p, _, _): "⚙︎ \(p.path)"
            case let .tagsChanged(p, b, a): "🏷 \(p.path): \(b) → \(a)"
            case let .deletedPermanently(p): "✕ \(p.path)"
            }
        }.joined(separator: "\n")
    }

    @objc private func undoSelected() {
        guard table.selectedRow >= 0 else { return }
        let batch = batches[table.selectedRow]
        let plan = UndoPlanner.plan(for: [batch])
        Task {
            var force = false
            if !plan.conflicts.isEmpty, let ui = workspace.ui {
                let answer = await ui.confirmUndo(plan, title: batch.title)
                guard answer.proceed else { return }
                force = answer.force
            }
            let result = await workspace.fileOps.execute(plan, force: force)
            workspace.setStatus(L10n.tr("Cofnięto: \(result.performed), pominięto: \(result.skipped.count), błędy: \(result.errors.count)"))
            // Jak komenda „Cofnij operację” — panele pokazują stan po cofnięciu.
            await workspace.left.activeTab.reload()
            await workspace.right.activeTab.reload()
            reload()
        }
    }
}
