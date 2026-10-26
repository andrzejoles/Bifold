import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftUI
import UniformTypeIdentifiers

/// Implementacja `UIServices` dla AppKit: okna dialogowe jako arkusze okna głównego.
final class AppUIServices: UIServices {
    let workspace: Workspace
    weak var mainWindow: MainWindowController?
    private var viewers: [ViewerWindowController] = []
    /// Okna pomocnicze (wyszukiwanie, zmiana nazw) — trzymane do zamknięcia.
    private var windows: [NSWindowController] = []

    private func keep(_ controller: NSWindowController) {
        windows.removeAll { !($0.window?.isVisible ?? false) && !($0.window?.isMiniaturized ?? false) }
        windows.append(controller)
    }
    private lazy var quickLook = QuickLookController()
    private lazy var palette = CommandPaletteController(workspace: workspace)
    private var settingsWindow: NSWindowController?
    private var journalWindow: JournalWindowController?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    private var window: NSWindow? { mainWindow?.window }

    /// Pokazuje alert jako arkusz (albo modalnie, gdy arkusz jest już otwarty).
    func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window, window.attachedSheet == nil else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Okna dialogowe

    func promptText(title: String, message: String?, defaultValue: String, selectStem: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("OK"))
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            field.becomeFirstResponder()
            if let editor = field.currentEditor() {
                let stemLength = selectStem && !defaultValue.hasPrefix(".") ? (defaultValue.fileStem as NSString).length : (defaultValue as NSString).length
                editor.selectedRange = NSRange(location: 0, length: stemLength)
            }
        }
        let response = await present(alert)
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let ok = alert.addButton(withTitle: confirmTitle)
        ok.hasDestructiveAction = destructive
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        return await present(alert) == .alertFirstButtonReturn
    }

    func promptTransfer(kind: TransferKind, items: [FileItem], defaultDestination: String) async -> TransferDialogResult? {
        let alert = NSAlert()
        alert.messageText = kind == .copy ? L10n.tr("Kopiuj \(Format.describe(items)) do:") : L10n.tr("Przenieś \(Format.describe(items)) do:")
        alert.informativeText = L10n.tr("Ścieżka zakończona „/” to katalog (zostanie utworzony, jeśli nie istnieje). Dla jednego elementu inna nazwa = kopia pod nową nazwą.")
        let field = NSTextField(string: defaultDestination)
        field.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let conflict = NSPopUpButton()
        let policies: [(String, ConflictResolution?)] = [
            (L10n.tr("Pytaj"), nil), (L10n.tr("Pomiń istniejące"), .skip), (L10n.tr("Nadpisz (stare do Kosza)"), .overwrite),
            (L10n.tr("Nadpisz starsze"), .overwriteOlder), (L10n.tr("Zmień nazwę kopii"), .rename),
        ]
        conflict.addItems(withTitles: policies.map(\.0))
        let limit = NSPopUpButton()
        let limits: [Int64] = [0, 1, 5, 10, 25, 50, 100]
        limit.addItems(withTitles: limits.map { $0 == 0 ? L10n.tr("Bez limitu") : L10n.tr("\(Int($0)) MB/s") })
        let options = NSStackView(views: [NSTextField(labelWithString: L10n.tr("Gdy istnieje:")), conflict, NSTextField(labelWithString: L10n.tr("Prędkość:")), limit])
        options.spacing = 6
        let stack = NSStackView(views: [field, options])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 58)
        alert.accessoryView = stack
        alert.addButton(withTitle: kind == .copy ? L10n.tr("Kopiuj") : L10n.tr("Przenieś"))
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        return TransferDialogResult(
            destination: field.stringValue,
            conflictPolicy: policies[conflict.indexOfSelectedItem].1,
            speedLimit: limits[limit.indexOfSelectedItem] * 1024 * 1024)
    }

    func promptAttributes(items: [FileItem]) async -> AttributeChange? {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            var controller: NSWindowController?
            let view = AttributesEditor(items: items) { change in
                if let sheet = controller?.window { window.endSheet(sheet) }
                // Zerwanie cyklu: kontroler → okno → widok → to domknięcie → kontroler.
                controller = nil
                continuation.resume(returning: change)
            }
            let hosting = NSHostingController(rootView: view)
            let sheet = NSWindow(contentViewController: hosting)
            controller = NSWindowController(window: sheet)
            window.beginSheet(sheet)
        }
    }

    func promptTags(items: [FileItem], current: [String]) async -> [String]? {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Tagi Findera: \(Format.describe(items))")
        alert.informativeText = L10n.tr("Wpisz tagi oddzielone przecinkami (np. Czerwony, Projekt). Pusta lista usuwa tagi.")
        let field = NSTokenField(string: current.joined(separator: ","))
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Zapisz"))
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        let tokens = (field.objectValue as? [String]) ?? field.stringValue.split(separator: ",").map(String.init)
        return tokens.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func promptMask(title: String, defaultMask: String) async -> String? {
        await promptText(title: title, message: L10n.tr("Maska: *.jpg;*.png — kilka wzorców przez „;”, wykluczenia po „|”, katalogi z „/” na końcu."), defaultValue: defaultMask, selectStem: false)
    }

    func confirmUndo(_ plan: UndoPlan, title: String) async -> (proceed: Bool, force: Bool) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Cofnięcie „\(title)” — wykryto konflikty")
        let list = plan.conflicts.prefix(12).map { "• " + $0.message }.joined(separator: "\n")
        alert.informativeText = list + (plan.conflicts.count > 12 ? "\n…" : "") + "\n\n" + L10n.tr("Kroki bez konfliktów zostaną wykonane. „Wymuś” cofa też elementy zmienione od czasu operacji.")
        alert.addButton(withTitle: L10n.tr("Cofnij pozostałe"))
        alert.addButton(withTitle: L10n.tr("Wymuś"))
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        switch await present(alert) {
        case .alertFirstButtonReturn: return (true, false)
        case .alertSecondButtonReturn: return (true, true)
        default: return (false, false)
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Nie udało się")
        alert.informativeText = message
        Task { _ = await present(alert) }
    }

    func showMessage(_ message: String) {
        workspace.setStatus(message)
    }

    // MARK: Programy zewnętrzne

    func openInEditor(_ urls: [URL]) {
        let settings = workspace.settings
        let editorURL: URL? = FileManager.default.fileExists(atPath: settings.editorPath)
            ? URL(filePath: settings.editorPath)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.editorBundleID)
        guard let editorURL else {
            showError(L10n.tr("Nie znaleziono edytora (\(settings.editorPath)). Zmień go w Ustawieniach → Ogólne."))
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.showError(error.localizedDescription) } }
        }
    }

    func openWithDefaultApp(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    func openWith(_ urls: [URL]) {
        guard let first = urls.first, let view = mainWindow?.activePanel.view else { return }
        let menu = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
        for app in apps.prefix(30) {
            let name = FileManager.default.displayName(atPath: app.path)
            let item = NSMenuItem(title: app == defaultApp ? L10n.tr("\(name) (domyślna)") : name, action: #selector(OpenWithTarget.open(_:)), keyEquivalent: "")
            let image = NSWorkspace.shared.icon(forFile: app.path)
            image.size = NSSize(width: 16, height: 16)
            item.image = image
            item.representedObject = OpenWithTarget.Payload(app: app, files: urls)
            item.target = OpenWithTarget.shared
            menu.addItem(item)
        }
        let point = NSPoint(x: view.bounds.midX - 100, y: view.bounds.midY)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    func share(_ urls: [URL]) {
        guard !urls.isEmpty, let view = mainWindow?.activePanel.view else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    func copyToPasteboard(_ strings: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(strings.joined(separator: "\n"), forType: .string)
        workspace.setStatus(L10n.tr("Skopiowano do schowka: \(Format.items(strings.count))"))
    }

    // MARK: Okna i panele

    func showViewer(_ item: FileItem) {
        let viewer = ViewerWindowController(item: item)
        viewers.append(viewer)
        viewer.onClose = { [weak self, weak viewer] in self?.viewers.removeAll { $0 === viewer } }
        viewer.showWindow(nil)
    }

    func toggleQuickLook(_ items: [FileItem]) {
        quickLook.toggle(urls: items.compactMap(\.path.url))
    }

    func runInTerminal(command: String?, directory: VFSPath) {
        mainWindow?.run(command: command, directory: directory)
    }

    func toggleTerminal(directory: VFSPath) {
        mainWindow?.toggleTerminal(directory: directory)
    }

    func focusCommandLine() {
        mainWindow?.commandLine.focus()
    }

    func focusQuickFilter() {
        mainWindow?.activePanel.showFilter()
    }

    func showCommandPalette() {
        palette.show(relativeTo: window)
    }

    func showVolumes() {
        mainWindow?.activePanel.showDriveMenu()
    }

    func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(workspace: workspace))
            let w = NSWindow(contentViewController: hosting)
            w.title = L10n.tr("Ustawienia")
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 560))
            settingsWindow = NSWindowController(window: w)
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.center()
    }

    func showJournal() {
        if journalWindow == nil { journalWindow = JournalWindowController(workspace: workspace) }
        journalWindow?.showWindow(nil)
    }

    func transferDelegate() -> any TransferDelegate {
        AppTransferDelegate(services: self)
    }

    func showSearch(directory: VFSPath, criteria: SearchCriteria?) {
        let controller = SearchWindowController(workspace: workspace, directory: directory, criteria: criteria)
        keep(controller)
        controller.showWindow(nil)
    }

    func showMultiRename(items: [FileItem]) {
        let controller = MultiRenameWindowController(items: items, workspace: workspace)
        keep(controller)
        controller.showWindow(nil)
    }

    func promptPassword(title: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L10n.tr("Hasło nie jest nigdzie zapisywane i nie trafia do agentów.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("OK"))
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    private var connectionsWindow: ConnectionsWindowController?

    func showCompare(left: FileItem, right: FileItem) {
        let c = HostingWindowController(title: L10n.tr("Porównanie: \(left.name) ↔ \(right.name)"), size: NSSize(width: 1000, height: 640), autosave: "CompareWindow") { _ in
            CompareView(left: left, right: right)
        }
        keep(c)
        c.showWindow(nil)
    }

    func showSync(source: VFSPath, destination: VFSPath, job: SyncJob?) {
        let model = SyncModel(workspace: workspace, source: source, destination: destination, job: job)
        let c = HostingWindowController(title: L10n.tr("Synchronizacja katalogów"), size: NSSize(width: 900, height: 600), autosave: "SyncWindow") { close in
            SyncView(model: model, close: close)
        }
        keep(c)
        c.showWindow(nil)
    }

    func showConnections() {
        if connectionsWindow == nil {
            connectionsWindow = ConnectionsWindowController(workspace: workspace) { [weak self] command in
                guard let self else { return }
                self.runInTerminal(command: command, directory: .local(NSHomeDirectory()))
            }
        }
        connectionsWindow?.showWindow(nil)
    }

    func showReport(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = AgentUIController.textAccessory(text)
        alert.addButton(withTitle: L10n.tr("OK"))
        Task { _ = await present(alert) }
    }
}

/// Pytania kolejki operacji (konflikty, błędy) jako okna dialogowe.
nonisolated struct AppTransferDelegate: TransferDelegate {
    let services: AppUIServices

    func resolveConflict(_ conflict: FileConflict) async -> ConflictDecision {
        await services.askConflict(conflict)
    }

    func resolveError(path: VFSPath, error: VFSError) async -> ErrorDecision {
        await services.askError(path: path, error: error)
    }
}

extension AppUIServices {
    func askConflict(_ c: FileConflict) async -> ConflictDecision {
        let alert = NSAlert()
        alert.messageText = L10n.tr("„\(c.destination.name)” już istnieje")
        func describe(_ i: FileItem) -> String {
            "\(i.isNavigable ? L10n.tr("katalog") : Format.bytes(i.size)), \(i.modified.map { Formatters.date.string(from: $0) } ?? "—")"
        }
        alert.informativeText = L10n.tr("Nowy: \(describe(c.source))\nIstniejący: \(describe(c.destination))\n\nNadpisany plik trafi do Kosza.")
        alert.addButton(withTitle: L10n.tr("Nadpisz"))
        alert.addButton(withTitle: L10n.tr("Pomiń"))
        alert.addButton(withTitle: L10n.tr("Zmień nazwę"))
        alert.addButton(withTitle: L10n.tr("Nadpisz starsze"))
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.tr("Dla wszystkich")
        let response = alert.runModal()
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return ConflictDecision(.overwrite, applyToAll: all)
        case .alertSecondButtonReturn: return ConflictDecision(.skip, applyToAll: all)
        case .alertThirdButtonReturn: return ConflictDecision(.rename, applyToAll: all)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            return ConflictDecision(.overwriteOlder, applyToAll: all)
        default: return ConflictDecision(.cancel)
        }
    }

    func askError(path: VFSPath, error: VFSError) async -> ErrorDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Błąd: \(path.name)")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.tr("Pomiń"))
        alert.addButton(withTitle: L10n.tr("Pomiń wszystkie"))
        alert.addButton(withTitle: L10n.tr("Ponów"))
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .skip
        case .alertSecondButtonReturn: return .skipAll
        case .alertThirdButtonReturn: return .retry
        default: return .cancel
        }
    }
}

final class OpenWithTarget: NSObject {
    static let shared = OpenWithTarget()

    final class Payload: NSObject {
        let app: URL
        let files: [URL]
        init(app: URL, files: [URL]) {
            self.app = app
            self.files = files
        }
    }

    @objc func open(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload else { return }
        NSWorkspace.shared.open(p.files, withApplicationAt: p.app, configuration: NSWorkspace.OpenConfiguration())
    }
}
