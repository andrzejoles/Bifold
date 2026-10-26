import BifoldCore
import Foundation

/// Zapisane zadanie synchronizacji (uruchamiane jednym kliknięciem).
public struct SyncJob: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Postać `displayPath` (lokalna ścieżka albo `alias:/ścieżka`).
    public var source: String
    public var destination: String
    public var mode: SyncMode
    /// Ścieżki względne pominięte w synchronizacji.
    public var exclude: [String]

    public init(name: String, source: String, destination: String, mode: SyncMode, exclude: [String] = []) {
        self.name = name
        self.source = source
        self.destination = destination
        self.mode = mode
        self.exclude = exclude
    }

    // Starsze pliki sync-jobs.json nie mają `exclude`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(String.self, forKey: .source)
        destination = try c.decode(String.self, forKey: .destination)
        mode = try c.decode(SyncMode.self, forKey: .mode)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }

    /// Argumenty `sync.preview` / `sync.run` odpowiadające zadaniu.
    var arguments: CommandArguments {
        CommandArguments(["source": .string(source), "destination": .string(destination), "mode": .string(mode.rawValue),
                          "exclude": .array(exclude.map { .string($0) })])
    }
}

extension Workspace {
    var syncJobsURL: URL { paths.root.appending(path: "sync-jobs.json") }

    public var syncJobs: [SyncJob] {
        get { JSONStore.load([SyncJob].self, from: syncJobsURL) ?? [] }
        set { try? JSONStore.save(newValue, to: syncJobsURL) }
    }

    /// Nazwa systemu plików rclone dla ścieżki (lokalna ścieżka albo `alias:podkatalog`).
    public func rcloneFs(_ path: VFSPath) async throws -> String {
        if let alias = RemoteFS.alias(of: path) {
            let fs = try await remotes.rcloneProvider(alias)
            return fs.fs + fs.remotePath(path)
        }
        guard path.isLocal else { throw CommandError.notAvailable(L10n.tr("Synchronizacja działa dla katalogów lokalnych i serwerów")) }
        return path.path
    }

    public func syncPlan(source: VFSPath, destination: VFSPath, mode: SyncMode, byContent: Bool = false) async throws -> SyncPlan {
        let rc = try remotes.runningRclone()
        return try await SyncPlanner.plan(
            rclone: rc, sourceFs: try await rcloneFs(source), destinationFs: try await rcloneFs(destination), mode: mode,
            localSource: source.isLocal ? source : nil, localDestination: destination.isLocal ? destination : nil, byContent: byContent)
    }
}

let syncParams: [CommandParameter] = [
    CommandParameter("source", .path, L10n.tr("Katalog źródłowy (domyślnie aktywny panel; serwer: alias:/ścieżka)")),
    CommandParameter("destination", .path, L10n.tr("Katalog docelowy (domyślnie drugi panel)")),
    CommandParameter("mode", .string, L10n.tr("mirror (lustro z usuwaniem), update (bez usuwania), twoWay (nowszy wygrywa)"), allowed: SyncMode.allCases.map(\.rawValue)),
    CommandParameter("exclude", .paths, L10n.tr("Ścieżki względne pominięte w synchronizacji")),
    CommandParameter("byContent", .boolean, L10n.tr("Porównuj sumy kontrolne zamiast rozmiaru i daty (wolniej)")),
]

extension CommandContext {
    func syncEndpoints() throws -> (VFSPath, VFSPath, SyncMode) {
        let source = arguments.string("source").map { workspace.parsePath($0, relativeTo: tab.path) } ?? tab.path
        let destination = arguments.string("destination").map { workspace.parsePath($0, relativeTo: tab.path) } ?? otherTab.path
        guard let raw = arguments.string("mode") ?? Optional("update"), let mode = SyncMode(rawValue: raw) else {
            throw CommandError.invalidArgument("mode", SyncMode.allCases.map(\.rawValue).joined(separator: " | "))
        }
        guard source != destination else { throw CommandError.notAvailable(L10n.tr("Źródło i cel są tym samym katalogiem")) }
        return (source, destination, mode)
    }

    func filteredPlan() async throws -> SyncPlan {
        let (s, d, m) = try syncEndpoints()
        var plan = try await workspace.syncPlan(source: s, destination: d, mode: m, byContent: arguments.bool("byContent") ?? false)
        let excluded = Set(arguments.strings("exclude") ?? [])
        for i in plan.actions.indices where excluded.contains(plan.actions[i].path) { plan.actions[i].enabled = false }
        return plan
    }
}

extension SyncPlan {
    public func json() -> JSONValue {
        [
            "mode": .string(mode.rawValue), "identical": .int(Int64(identical)),
            "actions": .array(actions.filter(\.enabled).map { ["action": .string($0.kind.rawValue), "path": .string($0.path), "reason": .string($0.reason)] }),
        ]
    }

    public var preview: EffectPreview {
        let work = actions.filter(\.enabled)
        let deletes = work.filter { $0.kind == .deleteFromDestination }.count
        return EffectPreview(
            summary: L10n.tr("Synchronizacja (\(mode.displayName)): \(work.count) operacji, w tym usunięć: \(deletes); identycznych: \(identical)"),
            operations: work.map { a in
                PlannedOperation(
                    kind: a.kind.rawValue,
                    source: VFSPath(provider: ProviderID("sync"), path: "/" + a.path),
                    destination: nil, conflict: a.kind == .deleteFromDestination)
            },
            fileCount: work.count,
            conflicts: work.filter { $0.kind == .deleteFromDestination }.map { L10n.tr("usunięcie: \($0.path)") })
    }
}

@MainActor
var syncCommands: [Command] { [
    Command(CommandDescriptor(
        id: "file.compare", title: L10n.tr("Porównaj pliki"), category: .file, tc: ["ctrl+shift+f2"], cmd: ["cmd+alt+shift+f2"],
        parameters: [CommandParameter("left", .path, L10n.tr("Plik lewy (domyślnie kursor aktywnego panelu)")),
                     CommandParameter("right", .path, L10n.tr("Plik prawy (domyślnie kursor drugiego panelu)"))],
        agent: .read, effect: .none, summary: L10n.tr("Porównuje zawartość dwóch plików: tekst (różnice wierszy) albo binarnie."))
    ) { ctx in
        let selected = ctx.tab.selectedItems.filter { $0.kind == .file }
        var left = ctx.arguments.path("left", relativeTo: ctx.tab.path)
        var right = ctx.arguments.path("right", relativeTo: ctx.otherTab.path)
        if left == nil, right == nil, selected.count == 2 {
            left = selected[0].path
            right = selected[1].path
        }
        left = left ?? ctx.tab.cursorItem?.path
        right = right ?? ctx.otherTab.cursorItem?.path
        guard let left, let right, let a = try? LocalFS().itemSync(at: left), let b = try? LocalFS().itemSync(at: right),
              a.kind == .file, b.kind == .file else {
            throw CommandError.notAvailable(L10n.tr("Ustaw kursory na plikach w obu panelach (albo zaznacz dwa pliki)"))
        }
        if !ctx.isAgent {
            try ctx.requireUI().showCompare(left: a, right: b)
            return .ok
        }
        let limit = ctx.workspace.settings.agent.maxReadBytes
        let da = try LocalFS().readSync(left, range: 0..<limit), db = try LocalFS().readSync(right, range: 0..<limit)
        if TextDecoding.looksBinary(da) || TextDecoding.looksBinary(db) || a.size > limit || b.size > limit {
            let r = try await runBlocking(qos: .userInitiated) { try FileCompare.binary(left, right) }
            return CommandResult(value: ["binary": true, "identical": .bool(r.identical), "sizeLeft": .int(r.sizeA), "sizeRight": .int(r.sizeB),
                                         "firstDifference": r.firstDifference.map { .int($0) } ?? .null, "differingBytes": .int(r.differingBytes)])
        }
        let r = FileCompare.text(TextDecoding.decode(da, as: TextDecoding.detect(da)), TextDecoding.decode(db, as: TextDecoding.detect(db)))
        return CommandResult(value: [
            "untrusted": true, "identical": .bool(r.identical), "removed": .int(Int64(r.removed)), "added": .int(Int64(r.added)),
            "diff": .string(FileCompare.unified(r, leftName: a.name, rightName: b.name)),
        ])
    },

    Command(CommandDescriptor(
        id: "dirs.compare", title: L10n.tr("Porównaj katalogi"), category: .selection, tc: ["shift+f2"], cmd: ["cmd+alt+shift+d"],
        parameters: [CommandParameter("byContent", .boolean, L10n.tr("Porównuj zawartość (wolniej) zamiast daty i rozmiaru"))],
        agent: .read, effect: .uiState,
        summary: L10n.tr("Zaznacza w obu panelach pliki unikalne i nowsze (lub różne) — jak w Total Commanderze."))
    ) { ctx in
        let left = ctx.workspace.left.activeTab, right = ctx.workspace.right.activeTab
        let byContent = ctx.arguments.bool("byContent") ?? false
        let l = left.items, r = right.items
        let result = byContent ? try await runBlocking(qos: .userInitiated) { DirectoryCompare.compare(left: l, right: r, byContent: true) }
            : DirectoryCompare.compare(left: l, right: r)
        left.setSelection(Set(result.markLeft.map { left.path.appending($0) }))
        right.setSelection(Set(result.markRight.map { right.path.appending($0) }))
        func arr(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }
        return CommandResult(
            message: L10n.tr("Różnice: \(result.markLeft.count) po lewej, \(result.markRight.count) po prawej; identycznych: \(result.identical)"),
            value: ["onlyLeft": arr(result.onlyLeft), "onlyRight": arr(result.onlyRight), "newerLeft": arr(result.newerLeft),
                    "newerRight": arr(result.newerRight), "different": arr(result.different), "identical": .int(Int64(result.identical))])
    },

    Command(CommandDescriptor(
        id: "sync.preview", title: L10n.tr("Podgląd synchronizacji"), category: .tools,
        parameters: syncParams, agent: .read, effect: .none,
        summary: L10n.tr("Lista operacji synchronizacji „na sucho” (nic nie zmienia)."), inMenu: false)
    ) { ctx in
        let plan = try await ctx.filteredPlan()
        return CommandResult(message: plan.preview.summary, value: plan.json())
    },

    Command(
        CommandDescriptor(
            id: "sync.run", title: L10n.tr("Synchronizuj katalogi…"), category: .tools, tc: ["ctrl+alt+s"], cmd: ["cmd+alt+shift+y"],
            parameters: syncParams, agent: .approval, effect: .modifiesFiles,
            summary: L10n.tr("Synchronizacja jedno- lub dwukierunkowa (także z serwerem), zawsze z podglądem; lokalne nadpisywane i usuwane pliki idą do Kosza.")),
        preview: { @MainActor ctx in
            try await ctx.filteredPlan().preview
        }
    ) { ctx in
        if !ctx.isAgent && ctx.arguments.isEmpty {
            try ctx.requireUI().showSync(source: ctx.tab.path, destination: ctx.otherTab.path, job: nil)
            return .ok
        }
        let plan = try await ctx.filteredPlan()
        let rc = try ctx.workspace.remotes.runningRclone()
        let job = ctx.workspace.jobs.enqueue(.sync(plan, rc), title: L10n.tr("Synchronizacja (\(plan.actions.filter(\.enabled).count))"), invoker: ctx.invoker)
        let state = await ctx.workspace.jobs.wait(for: job)
        await ctx.workspace.left.activeTab.reload()
        await ctx.workspace.right.activeTab.reload()
        return CommandResult(message: "\(state)", value: ["state": .string("\(state)"), "errors": .array(job.errors.map { .string($0) })])
    },

    Command(CommandDescriptor(
        id: "sync.save", title: L10n.tr("Zapisz zadanie synchronizacji"), category: .tools,
        parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa zadania"))] + syncParams.dropLast(),
        agent: .approval, effect: .settings, summary: L10n.tr("Zapisuje zadanie synchronizacji (źródło, cel, tryb)."), inMenu: false)
    ) { ctx in
        let name = try await ctx.text("name", title: L10n.tr("Nazwa zadania synchronizacji"))
        let (s, d, m) = try ctx.syncEndpoints()
        var jobs = ctx.workspace.syncJobs.filter { $0.name != name }
        jobs.append(SyncJob(name: name, source: s.displayPath, destination: d.displayPath, mode: m, exclude: ctx.arguments.strings("exclude") ?? []))
        ctx.workspace.syncJobs = jobs
        return CommandResult(message: name)
    },

    Command(CommandDescriptor(
        id: "sync.listSaved", title: L10n.tr("Zapisane zadania synchronizacji"), category: .tools,
        agent: .read, effect: .none, summary: L10n.tr("Lista zapisanych zadań synchronizacji."), inMenu: false)
    ) { ctx in
        CommandResult(value: .array(ctx.workspace.syncJobs.map { ["name": .string($0.name), "source": .string($0.source), "destination": .string($0.destination), "mode": .string($0.mode.rawValue)] }))
    },

    Command(
        CommandDescriptor(
            id: "sync.runSaved", title: L10n.tr("Uruchom zadanie synchronizacji…"), category: .tools,
            parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa zadania"))],
            agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Uruchamia zapisane zadanie synchronizacji (z podglądem).")),
        preview: { @MainActor ctx in
            let job = try savedSyncJob(ctx)
            return try await CommandContext(workspace: ctx.workspace, invoker: ctx.invoker, arguments: job.arguments).filteredPlan().preview
        }
    ) { ctx in
        let job = try savedSyncJob(ctx)
        if !ctx.isAgent {
            try ctx.requireUI().showSync(source: ctx.workspace.parsePath(job.source, relativeTo: .root),
                                         destination: ctx.workspace.parsePath(job.destination, relativeTo: .root), job: job)
            return .ok
        }
        // Kontekst wewnętrzny nie przechodzi przez bramkę agenta — końce zadania sprawdziła już bramka
        // przy wywołaniu sync.runSaved (zasoby i zasada najmniejszego poziomu).
        let plan = try await CommandContext(workspace: ctx.workspace, invoker: ctx.invoker, arguments: job.arguments).filteredPlan()
        let rc = try ctx.workspace.remotes.runningRclone()
        let queued = ctx.workspace.jobs.enqueue(.sync(plan, rc), title: L10n.tr("Synchronizacja „\(job.name)”"), invoker: ctx.invoker)
        let state = await ctx.workspace.jobs.wait(for: queued)
        return CommandResult(message: "\(state)", value: ["state": .string("\(state)")])
    },
] }

@MainActor
private func savedSyncJob(_ ctx: CommandContext) throws -> SyncJob {
    let jobs = ctx.workspace.syncJobs
    let name = ctx.arguments.string("name") ?? jobs.first?.name
    guard let name, let job = jobs.first(where: { $0.name == name }) else { throw CommandError.invalidArgument("name", name ?? "") }
    return job
}
