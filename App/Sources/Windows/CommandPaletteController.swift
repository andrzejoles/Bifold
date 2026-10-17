import AppKit
import BifoldCore
import BifoldWorkspace

/// Paleta komend (Cmd+Shift+P): wyszukiwanie po nazwie, id i opisie; Enter uruchamia.
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let workspace: Workspace
    private var panel: NSPanel?
    private let search = NSSearchField()
    private let table = NSTableView()
    private var results: [Command] = []

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
    }

    func show(relativeTo parent: NSWindow?) {
        if panel == nil { build() }
        guard let panel else { return }
        search.stringValue = ""
        filter()
        if let parent {
            let f = parent.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 80))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    private func build() {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.delegate = self
        search.placeholderString = L10n.tr("Wpisz nazwę komendy…")
        search.delegate = self
        search.font = .systemFont(ofSize: 15)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [search, scroll])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        p.contentView?.addSubview(stack)
        if let content = p.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        panel = p
    }

    private func filter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let all = workspace.registry.commands
        if q.isEmpty {
            results = all
        } else {
            let words = q.split(separator: " ").map(String.init)
            results = all.filter { c in
                let hay = "\(c.descriptor.title) \(c.id.rawValue) \(c.descriptor.summary) \(c.descriptor.category.displayName)"
                return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            panel?.orderOut(nil); return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let id = results[row].id
        panel?.orderOut(nil)
        workspace.perform(id)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = results[row]
        let title = NSTextField(labelWithString: c.descriptor.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let subtitle = NSTextField(labelWithString: "\(c.descriptor.category.displayName) · \(c.id.rawValue) · \(L10n.tr("agent")): \(c.descriptor.agentAccess.displayName)")
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        let shortcut = NSTextField(labelWithString: workspace.keymap.chords(for: c.id).map(\.displayString).joined(separator: "  "))
        shortcut.textColor = .secondaryLabelColor
        shortcut.font = .systemFont(ofSize: 12)
        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let row = NSStackView(views: [texts, NSView(), shortcut])
        row.toolTip = c.descriptor.summary
        return row
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.orderOut(nil)
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
