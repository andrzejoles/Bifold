import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftUI

/// Okno wyszukiwania (Alt+F7): kryteria, wyniki na żywo, „Do panelu”, „Przejdź do pliku”,
/// zapisane wyszukiwania.
@MainActor @Observable
final class SearchModel {
    let workspace: Workspace
    var criteria: SearchCriteria
    var rootsText: String
    var useDates = false
    var after = Date().addingTimeInterval(-30 * 86400)
    var before = Date()
    var minSizeText = ""
    var maxSizeText = ""
    var hits: [SearchHit] = []
    var running = false
    var status = ""
    var selection: VFSPath?
    var saveName = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: Workspace, directory: VFSPath, criteria: SearchCriteria?) {
        self.workspace = workspace
        let c = criteria ?? SearchCriteria(roots: [directory.isLocal ? directory : .local(NSHomeDirectory())])
        self.criteria = c
        rootsText = c.roots.map(\.path).joined(separator: "; ")
    }

    func start() {
        stop()
        var c = criteria
        c.roots = rootsText.split(separator: ";").map { resolvePath($0.trimmingCharacters(in: .whitespaces), relativeTo: nil) }
        c.modifiedAfter = useDates ? after : nil
        c.modifiedBefore = useDates ? before : nil
        c.minSize = minSizeText.isEmpty ? nil : parseSizeText(minSizeText)
        c.maxSize = maxSizeText.isEmpty ? nil : parseSizeText(maxSizeText)
        criteria = c
        hits = []
        running = true
        status = L10n.tr("Szukam…")
        let stream = SearchEngine.search(c, ripgrep: workspace.settings.toolPath("rg"))
        task = Task { [weak self] in
            var buffer: [SearchHit] = []
            var last = Date()
            for await event in stream {
                guard let self else { return }
                switch event {
                case .hit(let h):
                    buffer.append(h)
                    if Date().timeIntervalSince(last) > 0.2 { self.hits += buffer; buffer = []; last = Date() }
                case .progress(let n, let current):
                    self.status = L10n.tr("Katalogi: \(n) · \(current)")
                case .finished(let total, let truncated):
                    self.hits += buffer
                    buffer = []
                    self.status = L10n.tr("Znaleziono: \(total)") + (truncated ? " " + L10n.tr("(limit)") : "")
                case .failed(let m):
                    self.status = "⚠︎ " + m
                }
            }
            self?.hits += buffer
            self?.running = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    func feedToPanel() {
        let items = hits.map(\.item)
        let title = criteria.contentText.isEmpty ? (criteria.nameMask.isEmpty ? criteria.nameRegex : criteria.nameMask) : "„\(criteria.contentText)”"
        Task { try? await workspace.showResults(title: title.isEmpty ? L10n.tr("wyniki") : title, items: items) }
    }

    func goToSelected() {
        guard let p = selection, let parent = p.parent else { return }
        Task { try? await workspace.activeTab.navigate(to: parent, focus: p.name) }
    }

    func save() {
        guard !saveName.isEmpty else { return }
        var all = workspace.savedSearches.filter { $0.name != saveName }
        all.append(SavedSearch(name: saveName, criteria: criteria))
        workspace.savedSearches = all
        status = L10n.tr("Zapisano „\(saveName)”")
    }

    func load(_ s: SavedSearch) {
        criteria = s.criteria
        rootsText = s.criteria.roots.map(\.path).joined(separator: "; ")
        useDates = s.criteria.modifiedAfter != nil || s.criteria.modifiedBefore != nil
        minSizeText = s.criteria.minSize.map(String.init) ?? ""
        maxSizeText = s.criteria.maxSize.map(String.init) ?? ""
        saveName = s.name
    }

    private func parseSizeText(_ s: String) -> Int64? {
        let t = s.uppercased().replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        for (suffix, mult) in [("G", 1073741824.0), ("M", 1048576.0), ("K", 1024.0)] where t.hasSuffix(suffix) {
            return Double(t.dropLast()).map { Int64($0 * mult) }
        }
        return Int64(t)
    }
}

struct SearchView: View {
    @Bindable var model: SearchModel
    var close: () -> Void
    @FocusState private var maskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.tr("Szukaj w")).gridColumnAlignment(.trailing)
                    TextField("", text: $model.rootsText)
                }
                GridRow {
                    Text(L10n.tr("Nazwa"))
                    HStack {
                        TextField(L10n.tr("maska, np. *.txt;*.md|*.bak"), text: $model.criteria.nameMask)
                            .focused($maskFocused)
                        TextField(L10n.tr("albo regex na nazwie"), text: $model.criteria.nameRegex)
                    }
                }
                GridRow {
                    Text(L10n.tr("Treść"))
                    HStack {
                        TextField(L10n.tr("tekst w plikach (ripgrep)"), text: $model.criteria.contentText)
                        Toggle(L10n.tr("regex"), isOn: $model.criteria.contentIsRegex)
                        Picker("", selection: $model.criteria.encoding) {
                            ForEach(["auto", "utf-8", "windows-1250", "iso-8859-2", "utf-16le", "utf-16be", "windows-1252", "ibm852"], id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                GridRow {
                    Text(L10n.tr("Opcje"))
                    HStack(spacing: 16) {
                        Toggle(L10n.tr("Podkatalogi"), isOn: $model.criteria.recursive)
                        Toggle(L10n.tr("Ukryte"), isOn: $model.criteria.includeHidden)
                        Toggle(L10n.tr("Wielkość liter"), isOn: $model.criteria.caseSensitive)
                        Picker("", selection: $model.criteria.kind) {
                            Text(L10n.tr("pliki i katalogi")).tag(SearchCriteria.KindFilter.any)
                            Text(L10n.tr("tylko pliki")).tag(SearchCriteria.KindFilter.files)
                            Text(L10n.tr("tylko katalogi")).tag(SearchCriteria.KindFilter.directories)
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
                GridRow {
                    Text(L10n.tr("Data i rozmiar"))
                    HStack {
                        Toggle(L10n.tr("zmodyfikowane od"), isOn: $model.useDates)
                        DatePicker("", selection: $model.after, displayedComponents: .date).labelsHidden().disabled(!model.useDates)
                        Text(L10n.tr("do"))
                        DatePicker("", selection: $model.before, displayedComponents: .date).labelsHidden().disabled(!model.useDates)
                        Spacer(minLength: 20)
                        TextField(L10n.tr("min. rozmiar (10M)"), text: $model.minSizeText).frame(width: 130)
                        TextField(L10n.tr("maks. rozmiar"), text: $model.maxSizeText).frame(width: 120)
                    }
                }
            }
            HStack {
                Button(model.running ? L10n.tr("Zatrzymaj") : L10n.tr("Szukaj")) { model.running ? model.stop() : model.start() }
                    .keyboardShortcut(.defaultAction)
                Button(L10n.tr("Do panelu")) { model.feedToPanel(); close() }.disabled(model.hits.isEmpty)
                Button(L10n.tr("Przejdź do pliku")) { model.goToSelected(); close() }.disabled(model.selection == nil)
                Spacer()
                Menu(L10n.tr("Zapisane")) {
                    ForEach(model.workspace.savedSearches) { s in Button(s.name) { model.load(s) } }
                }
                .frame(width: 120)
                TextField(L10n.tr("nazwa"), text: $model.saveName).frame(width: 120)
                Button(L10n.tr("Zapisz")) { model.save() }.disabled(model.saveName.isEmpty)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            List(model.hits, selection: $model.selection) { hit in
                VStack(alignment: .leading, spacing: 1) {
                    Text((hit.item.path.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 12))
                    ForEach(hit.matches.prefix(2), id: \.self) { m in
                        Text("\(m.line): \(m.text)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(hit.item.path)
                .onTapGesture(count: 2) { model.selection = hit.item.path; model.goToSelected(); close() }
            }
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 560)
        .onExitCommand { close() }
        .onAppear { maskFocused = true }
    }
}

final class SearchWindowController: NSWindowController, NSWindowDelegate {
    private let model: SearchModel

    init(workspace: Workspace, directory: VFSPath, criteria: SearchCriteria?) {
        let model = SearchModel(workspace: workspace, directory: directory, criteria: criteria)
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Szukaj plików")
        window.setFrameAutosaveName("SearchWindow")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SearchView(model: model) { [weak window] in window?.close() })
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Zamknięte okno nie szuka dalej w tle.
    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}
