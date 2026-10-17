import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftUI

// MARK: - Porównanie plików

struct CompareView: View {
    let left: FileItem
    let right: FileItem
    @State private var text: FileCompare.TextResult?
    @State private var binary: FileCompare.BinaryResult?
    @State private var onlyChanges = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(left.path.displayPath).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Text(right.path.displayPath).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let binary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(binary.identical ? L10n.tr("Pliki są identyczne") : L10n.tr("Pliki różnią się")).font(.headline)
                    Text(L10n.tr("Rozmiary: \(Format.bytes(binary.sizeA)) / \(Format.bytes(binary.sizeB))"))
                    if let first = binary.firstDifference {
                        Text(L10n.tr("Pierwsza różnica: bajt \(first) (0x\(String(first, radix: 16, uppercase: true))), różnych bajtów: \(binary.differingBytes)"))
                    }
                }
                Spacer()
            } else if let text {
                HStack {
                    Text(text.identical ? L10n.tr("Pliki są identyczne") : L10n.tr("Usunięte wiersze: \(text.removed), dodane: \(text.added)")).font(.headline)
                    Spacer()
                    Toggle(L10n.tr("Tylko zmiany"), isOn: $onlyChanges)
                }
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible(text).enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 0) {
                                cell(line.left, line.kind == .added ? "" : line.text, line.kind == .removed ? Color.red.opacity(0.18) : .clear)
                                cell(line.right, line.kind == .removed ? "" : line.text, line.kind == .added ? Color.green.opacity(0.18) : .clear)
                            }
                        }
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(minWidth: 900, minHeight: 560)
        .task { await load() }
    }

    private func visible(_ r: FileCompare.TextResult) -> [FileCompare.Line] {
        onlyChanges ? r.lines.filter { $0.kind != .same } : r.lines
    }

    private func cell(_ number: Int?, _ text: String, _ background: Color) -> some View {
        HStack(spacing: 6) {
            Text(number.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            Text(text.isEmpty ? " " : text).frame(minWidth: 400, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(background)
    }

    private func load() async {
        let a = left.path, b = right.path
        do {
            let (da, db) = try await runBlocking(qos: .userInitiated) {
                (try LocalFS().readSync(a, range: 0..<8_388_608), try LocalFS().readSync(b, range: 0..<8_388_608))
            }
            if TextDecoding.looksBinary(da) || TextDecoding.looksBinary(db) || left.size > 8_388_608 || right.size > 8_388_608 {
                binary = try await runBlocking(qos: .userInitiated) { try FileCompare.binary(a, b) }
            } else {
                let ta = TextDecoding.decode(da, as: TextDecoding.detect(da)), tb = TextDecoding.decode(db, as: TextDecoding.detect(db))
                text = await Task.detached { FileCompare.text(ta, tb) }.value
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Synchronizacja

@MainActor @Observable
final class SyncModel {
    let workspace: Workspace
    var source: String
    var destination: String
    var mode: SyncMode
    var plan: SyncPlan?
    var status = ""
    var busy = false
    var jobName = ""
    var byContent = false

    init(workspace: Workspace, source: VFSPath, destination: VFSPath, job: SyncJob?) {
        self.workspace = workspace
        self.source = job?.source ?? source.displayPath
        self.destination = job?.destination ?? destination.displayPath
        mode = job?.mode ?? .update
        jobName = job?.name ?? ""
    }

    func compare() {
        busy = true
        status = L10n.tr("Porównywanie…")
        let s = workspace.parsePath(source, relativeTo: .root), d = workspace.parsePath(destination, relativeTo: .root)
        Task {
            defer { busy = false }
            do {
                plan = try await workspace.syncPlan(source: s, destination: d, mode: mode, byContent: byContent)
                status = plan.map { $0.preview.summary } ?? ""
            } catch {
                status = "✕ " + error.localizedDescription
            }
        }
    }

    func run(close: @escaping () -> Void) {
        guard let plan else { return }
        do {
            let rc = try workspace.remotes.runningRclone()
            workspace.jobs.enqueue(.sync(plan, rc), title: L10n.tr("Synchronizacja (\(plan.actions.filter(\.enabled).count))"))
            close()
        } catch {
            status = "✕ " + error.localizedDescription
        }
    }

    func save() {
        guard !jobName.isEmpty else { return }
        var jobs = workspace.syncJobs.filter { $0.name != jobName }
        jobs.append(SyncJob(name: jobName, source: source, destination: destination, mode: mode))
        workspace.syncJobs = jobs
        status = L10n.tr("Zapisano zadanie „\(jobName)”")
    }

    func load(_ job: SyncJob) {
        source = job.source
        destination = job.destination
        mode = job.mode
        jobName = job.name
        plan = nil
    }
}

struct SyncView: View {
    @Bindable var model: SyncModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.tr("Źródło")).gridColumnAlignment(.trailing)
                    TextField("", text: $model.source)
                }
                GridRow {
                    Text(L10n.tr("Cel"))
                    TextField("", text: $model.destination)
                }
                GridRow {
                    Text(L10n.tr("Tryb"))
                    Picker("", selection: $model.mode) {
                        ForEach(SyncMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                }
                GridRow {
                    Text("")
                    Toggle(L10n.tr("Porównuj sumy kontrolne (czyta całe pliki) zamiast rozmiaru i daty"), isOn: $model.byContent)
                }
            }
            HStack {
                Button(L10n.tr("Porównaj (na sucho)")) { model.compare() }.disabled(model.busy).keyboardShortcut(.defaultAction)
                Button(L10n.tr("Synchronizuj")) { model.run(close: close) }.disabled(model.plan == nil || model.busy)
                Spacer()
                Menu(L10n.tr("Zadania")) {
                    ForEach(model.workspace.syncJobs) { j in Button(j.name) { model.load(j) } }
                }
                .frame(width: 110)
                TextField(L10n.tr("nazwa zadania"), text: $model.jobName).frame(width: 140)
                Button(L10n.tr("Zapisz zadanie")) { model.save() }.disabled(model.jobName.isEmpty)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if let plan = Binding($model.plan) {
                Table(plan.actions) {
                    TableColumn("") { $a in Toggle("", isOn: $a.enabled).labelsHidden() }.width(24)
                    TableColumn(L10n.tr("Operacja")) { $a in
                        Text(Self.label(a.kind)).foregroundStyle(a.kind == .deleteFromDestination ? Color.red : .primary)
                    }
                    .width(130)
                    TableColumn(L10n.tr("Ścieżka")) { $a in Text(a.path) }
                    TableColumn(L10n.tr("Powód")) { $a in Text(a.reason).foregroundStyle(.secondary) }.width(140)
                }
            } else {
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 520)
    }

    static func label(_ k: SyncAction.Kind) -> String {
        switch k {
        case .copyToDestination: L10n.tr("→ kopiuj do celu")
        case .copyToSource: L10n.tr("← kopiuj do źródła")
        case .deleteFromDestination: L10n.tr("✕ usuń z celu")
        }
    }
}

final class HostingWindowController: NSWindowController {
    init<V: View>(title: String, size: NSSize, autosave: String, @ViewBuilder content: (@escaping () -> Void) -> V) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.setFrameAutosaveName(autosave)
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: content { [weak window] in window?.close() })
        if window.frame.origin == .zero { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
