import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftUI

/// Zmiana nazw wielu plików (Ctrl+M) z podglądem na żywo; wykonanie przez komendę z rejestru
/// (dziennik, cofanie).
struct MultiRenameView: View {
    let items: [FileItem]
    let workspace: Workspace
    var close: () -> Void
    @State private var rule = RenameRule()
    @State private var plan: [RenamePlanEntry] = []
    /// Reguła, dla której policzono pokazany podgląd — „Zmień nazwy” tylko, gdy to bieżąca reguła
    /// (Enter tuż po pisaniu wykonałby regułę, której podglądu jeszcze nie było).
    @State private var planRule: RenameRule?
    @State private var running = false
    @State private var error: String?
    @State private var planTask: Task<Void, Never>?
    /// Trwające obliczenie planu (poza wątkiem głównym) — kolejne startuje dopiero po jego zakończeniu.
    @State private var computeTask: Task<[RenamePlanEntry], Never>?
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                HStack {
                    TextField(L10n.tr("Maska nazwy"), text: $rule.nameMask)
                    TextField(L10n.tr("Rozszerzenie"), text: $rule.extensionMask).frame(width: 160)
                }
                HStack(spacing: 6) {
                    ForEach(["[N]", "[N1-3]", "[E]", "[C]", "[P]", "[Y]-[M]-[D]", "[h][m][s]", "[Exif:DateTimeOriginal:yyyy-MM-dd_HH-mm-ss]", "[Exif:Model]", "[Media:artist]", "[Media:title]"], id: \.self) { token in
                        Button(token) { rule.nameMask += token }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                HStack {
                    TextField(L10n.tr("Znajdź"), text: $rule.search)
                    TextField(L10n.tr("Zamień na"), text: $rule.replace)
                    Toggle(L10n.tr("regex"), isOn: $rule.regex)
                    Toggle(L10n.tr("Aa"), isOn: $rule.caseSensitive)
                }
                HStack {
                    Picker(L10n.tr("Nazwa"), selection: $rule.nameCase) { ForEach(CaseMode.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    Picker(L10n.tr("Rozszerzenie"), selection: $rule.extensionCase) { ForEach(CaseMode.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                }
                HStack {
                    Stepper(L10n.tr("Licznik od \(rule.counterStart)"), value: $rule.counterStart, in: 0...1_000_000)
                    Stepper(L10n.tr("krok \(rule.counterStep)"), value: $rule.counterStep, in: 1...1000)
                    Stepper(L10n.tr("cyfry \(rule.counterDigits)"), value: $rule.counterDigits, in: 1...10)
                }
            }
            Table(plan) {
                TableColumn(L10n.tr("Obecna nazwa")) { Text($0.source.name) }
                TableColumn(L10n.tr("Nowa nazwa")) { e in
                    Text(e.newName).foregroundStyle(e.problem != nil ? Color.red : (e.changes ? Color.primary : Color.secondary))
                }
                TableColumn(L10n.tr("Uwagi")) { Text($0.problem ?? "").foregroundStyle(.red) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text(L10n.tr("Zmian: \(plan.filter { $0.changes && $0.problem == nil }.count) z \(plan.count), problemy: \(plan.filter { $0.problem != nil }.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("Anuluj"), action: close).keyboardShortcut(.cancelAction)
                Button(L10n.tr("Zmień nazwy")) { run() }.keyboardShortcut(.defaultAction)
                    .disabled(running || planRule != rule || !plan.contains { $0.changes && $0.problem == nil })
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 600)
        .onAppear { refresh(debounce: false) }
        .onChange(of: rule) { refresh() }
    }

    /// Podgląd liczony w tle po krótkiej przerwie w pisaniu (~150 ms); nowsza reguła anuluje czekające
    /// obliczenie, a naraz liczy się najwyżej jeden plan (`MultiRename.plan` nie da się przerwać w trakcie).
    /// Spóźniony wynik starszej reguły (numer generacji) nie nadpisuje nowszego podglądu.
    private func refresh(debounce: Bool = true) {
        let items = items, rule = rule
        planTask?.cancel()
        generation += 1
        let current = generation
        planTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, current == generation else { return }
            if let running = computeTask { _ = await running.value }
            guard !Task.isCancelled, current == generation else { return }
            let compute = Task.detached(priority: .userInitiated) { MultiRename.plan(items, rule: rule) }
            computeTask = compute
            let p = await compute.value
            guard !Task.isCancelled, current == generation else { return }
            plan = p
            planRule = rule
        }
    }

    private func run() {
        guard !running, planRule == rule else { return }
        let args: [String: JSONValue] = [
            "paths": .array(items.map { .string($0.path.path) }),
            "nameMask": .string(rule.nameMask), "extensionMask": .string(rule.extensionMask),
            "search": .string(rule.search), "replace": .string(rule.replace), "regex": .bool(rule.regex),
            "caseSensitive": .bool(rule.caseSensitive), "nameCase": .string(rule.nameCase.rawValue),
            "extensionCase": .string(rule.extensionCase.rawValue), "counterStart": .int(Int64(rule.counterStart)),
            "counterStep": .int(Int64(rule.counterStep)), "counterDigits": .int(Int64(rule.counterDigits)),
        ]
        running = true
        Task {
            defer { running = false }
            do {
                try await workspace.invoke("file.multiRename", CommandArguments(args))
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

final class MultiRenameWindowController: NSWindowController {
    init(items: [FileItem], workspace: Workspace) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Zmiana nazw: \(Format.describe(items))")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MultiRenameView(items: items, workspace: workspace) { [weak window] in window?.close() })
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
