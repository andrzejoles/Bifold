import BifoldCore
import Foundation

let conflictParam = CommandParameter("conflict", .string, L10n.tr("Co zrobić, gdy element docelowy istnieje (domyślnie skip)"), allowed: ["skip", "overwrite", "rename", "overwriteOlder"])

extension CommandContext {
    /// Katalog drugiego panelu jako domyślny cel — tylko lokalny. Archiwum, wyniki wyszukiwania albo
    /// telefon w drugim panelu: wewnętrzna ścieżka (`/docs`) nie jest katalogiem na dysku.
    func localOtherDirectory() throws -> VFSPath {
        guard otherTab.path.isLocal else { throw CommandError.notAvailable(L10n.tr("Katalog docelowy musi być lokalny")) }
        return otherTab.path
    }

    /// Katalog lokalny, względem którego liczone są względne ścieżki docelowe (bieżący albo drugi panel).
    var localBaseDirectory: VFSPath? {
        tab.path.isLocal ? tab.path : (otherTab.path.isLocal ? otherTab.path : nil)
    }

    /// Cel kopiowania/przenoszenia: argument `destination` albo okno F5/F6 (domyślnie drugi panel).
    func transferRequest(_ kind: TransferKind, items: [FileItem], createMissing: Bool = true) async throws -> (TransferRequest, ConflictResolution?, Int64) {
        let base = localBaseDirectory
        let destinationText: String
        var policy = try conflictPolicy()
        var speedLimit = arguments.int("speedLimit") ?? 0
        if let d = arguments.string("destination") {
            destinationText = d
        } else if isAgent {
            destinationText = try localOtherDirectory().path
        } else {
            let other = try localOtherDirectory()
            let ui = try requireUI()
            let suggested = items.count == 1 && other == base ? items[0].name : other.path + "/"
            guard let result = await ui.promptTransfer(kind: kind, items: items, defaultDestination: suggested) else {
                throw CommandError.cancelledByUser
            }
            destinationText = result.destination
            policy = result.conflictPolicy ?? policy
            speedLimit = result.speedLimit
        }
        let trimmed = destinationText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CommandError.missingArgument("destination") }
        let target = resolvePath(trimmed, relativeTo: base)
        guard target.isLocal else { throw CommandError.notAvailable(L10n.tr("Katalog docelowy musi być lokalny")) }
        let fs = LocalFS()
        let isExistingDirectory = (try? fs.itemSync(at: target))?.isNavigable ?? false
        if isExistingDirectory || trimmed.hasSuffix("/") || items.count > 1 {
            if !isExistingDirectory && createMissing {
                // Jak w TC: brakujący katalog docelowy jest tworzony.
                try FileManager.default.createDirectory(atPath: target.path, withIntermediateDirectories: true)
            }
            return (TransferRequest(kind: kind, sources: items.map(\.path), destinationDirectory: target), policy, speedLimit)
        }
        // Jeden element i ścieżka do nieistniejącego elementu = kopiowanie/przenoszenie z nową nazwą.
        guard let parent = target.parent else { throw CommandError.invalidArgument("destination", trimmed) }
        if createMissing, !((try? fs.itemSync(at: parent))?.isNavigable ?? false) {
            try FileManager.default.createDirectory(atPath: parent.path, withIntermediateDirectories: true)
        }
        return (TransferRequest(kind: kind, sources: items.map(\.path), destinationDirectory: parent, newName: target.name), policy, speedLimit)
    }
}

@MainActor
private func transferCommand(_ kind: TransferKind) -> Command {
    let isCopy = kind == .copy
    return Command(
        CommandDescriptor(
            id: isCopy ? "file.copy" : "file.move",
            title: isCopy ? L10n.tr("Kopiuj…") : L10n.tr("Przenieś…"),
            category: .file, tc: [isCopy ? "f5" : "f6"], cmd: [isCopy ? "cmd+5" : "cmd+6"],
            parameters: [
                pathsParam,
                CommandParameter("destination", .path, L10n.tr("Katalog docelowy albo nowa ścieżka (jeden element); domyślnie katalog drugiego panelu")),
                conflictParam,
                CommandParameter("speedLimit", .integer, L10n.tr("Limit prędkości w bajtach na sekundę (0 = bez limitu)")),
                CommandParameter("wait", .boolean, L10n.tr("Czekaj na zakończenie zadania")),
            ],
            agent: .approval, effect: .modifiesFiles,
            summary: isCopy
                ? L10n.tr("Kopiuje elementy w tle (z zachowaniem atrybutów, ACL i dat). Nadpisywane pliki trafiają do Kosza.")
                : L10n.tr("Przenosi elementy w tle. Nadpisywane pliki trafiają do Kosza.")),
        preview: { @MainActor ctx in
            let items = try ctx.targets(allowNonLocal: true)
            let destArg = ctx.arguments.string("destination").map { ctx.workspace.parsePath($0, relativeTo: ctx.otherTab.path) } ?? ctx.otherTab.path
            if RemoteFS.alias(of: ctx.tab.path) != nil || RemoteFS.alias(of: destArg) != nil {
                return EffectPreview(
                    summary: (isCopy ? L10n.tr("Kopiowanie") : L10n.tr("Przeniesienie")) + " \(Format.describe(items)) \(ctx.tab.path.displayPath) → \(destArg.displayPath)",
                    operations: items.map { PlannedOperation(kind: kind.rawValue, source: $0.path, destination: destArg.appending($0.name), isDirectory: $0.isDirectory, bytes: max(0, $0.size)) },
                    fileCount: items.count, totalBytes: items.reduce(0) { $0 + max(0, $1.size) })
            }
            if ctx.tab.isInArchive || ctx.tab.path.isDevice {
                let dest = try ctx.arguments.path("destination", relativeTo: ctx.localBaseDirectory) ?? ctx.localOtherDirectory()
                let summary = ctx.tab.path.isDevice ? L10n.tr("Kopiowanie z urządzenia \(Format.describe(items)) → \(dest.path)")
                    : L10n.tr("Kopiowanie z archiwum \(Format.describe(items)) → \(dest.path)")
                return EffectPreview(summary: summary,
                                     operations: items.map { PlannedOperation(kind: "extract", source: $0.path, destination: dest, isDirectory: $0.isDirectory, bytes: max(0, $0.size)) },
                                     fileCount: items.count, totalBytes: items.reduce(0) { $0 + max(0, $1.size) })
            }
            let (request, policy, _) = try await ctx.transferRequest(kind, items: items, createMissing: false)
            let destinationExists = await LocalFS().exists(request.destinationDirectory)
            let plan = destinationExists
                ? try await runBlocking(qos: .userInitiated) { try TransferEngine.plan(request) }
                : try await runBlocking(qos: .userInitiated) { try TransferEngine.plan(request, assumingEmptyDestination: true) }
            return EffectPreview(
                summary: (isCopy ? L10n.tr("Kopiowanie") : L10n.tr("Przeniesienie")) + " \(Format.describe(items)) → \(request.destinationDirectory.path)"
                    + (policy.map { " (\(L10n.tr("konflikty")): \($0.rawValue))" } ?? ""),
                operations: plan.operations, fileCount: plan.fileCount, totalBytes: plan.totalBytes,
                conflicts: plan.conflicts.map(\.path))
        }
    ) { ctx in
        let items = try ctx.targets(allowNonLocal: true)
        if let (spec, title, delegate) = try await ctx.scpTransfer(kind, items: items) {
            let job = ctx.workspace.jobs.enqueue(spec, title: title, invoker: ctx.invoker, delegate: delegate)
            ctx.tab.clearSelection()
            if ctx.arguments.bool("wait") == true {
                let state = await ctx.workspace.jobs.wait(for: job)
                return CommandResult(message: "\(state)", value: ["job": .string(job.id.uuidString), "state": .string("\(state)"), "errors": .array(job.errors.map { .string($0) })])
            }
            return CommandResult(message: title, value: ["job": .string(job.id.uuidString)])
        }
        if let (transfer, destination) = try await ctx.remoteTransfer(kind, items: items) {
            let rc = try ctx.workspace.remotes.runningRclone()
            let title = (isCopy ? L10n.tr("Kopiowanie") : L10n.tr("Przenoszenie")) + " \(Format.describe(items)) → \(destination.displayPath)"
            let job = ctx.workspace.jobs.enqueue(.rclone(transfer, rc), title: title, invoker: ctx.invoker, speedLimit: ctx.arguments.int("speedLimit") ?? 0)
            ctx.tab.clearSelection()
            if ctx.arguments.bool("wait") == true {
                let state = await ctx.workspace.jobs.wait(for: job)
                return CommandResult(message: "\(state)", value: ["job": .string(job.id.uuidString), "state": .string("\(state)"), "errors": .array(job.errors.map { .string($0) })])
            }
            return CommandResult(message: title, value: ["job": .string(job.id.uuidString)])
        }
        if let archive = try? ctx.workspace.providers.provider(for: ctx.tab.path) as? any ExtractingProvider {
            guard isCopy else { throw CommandError.notAvailable(L10n.tr("Archiwum i urządzenie są tylko do odczytu — użyj kopiowania (F5)")) }
            let (request, policy, _) = try await ctx.transferRequest(kind, items: items)
            let delegate: any TransferDelegate = ctx.isAgent || ctx.ui == nil ? PolicyTransferDelegate(conflict: policy ?? .skip)
                : (policy.map { PolicyTransferDelegate(conflict: $0) } ?? ctx.ui!.transferDelegate())
            let job = ctx.workspace.jobs.enqueue(
                .extract(source: archive, sources: items.map(\.path), destination: request.destinationDirectory),
                title: L10n.tr("Kopiowanie z \(archive.displayName)"), invoker: ctx.invoker, delegate: delegate)
            ctx.tab.clearSelection()
            if ctx.arguments.bool("wait") == true { _ = await ctx.workspace.jobs.wait(for: job) }
            return CommandResult(message: job.title, value: ["job": .string(job.id.uuidString), "state": .string("\(job.state)")])
        }
        let (request, policy, speedLimit) = try await ctx.transferRequest(kind, items: items)
        let delegate: any TransferDelegate
        if ctx.isAgent || ctx.ui == nil {
            delegate = PolicyTransferDelegate(conflict: policy ?? .skip)
        } else if let policy {
            delegate = PolicyTransferDelegate(conflict: policy)
        } else {
            delegate = try ctx.requireUI().transferDelegate()
        }
        let title = (isCopy ? L10n.tr("Kopiowanie") : L10n.tr("Przenoszenie")) + " \(Format.describe(items))"
        let job = ctx.workspace.jobs.enqueue(.transfer(request), title: title, invoker: ctx.invoker, delegate: delegate, speedLimit: speedLimit)
        if ctx.arguments["paths"] == nil { ctx.tab.clearSelection() }
        if ctx.arguments.bool("wait") == true {
            let state = await ctx.workspace.jobs.wait(for: job)
            return CommandResult(message: "\(state)", value: ["job": .string(job.id.uuidString), "state": .string("\(state)"), "errors": .array(job.errors.map { .string($0) })])
        }
        return CommandResult(message: title, value: ["job": .string(job.id.uuidString)])
    }
}

@MainActor
var fileCommands: [Command] { [
    Command(CommandDescriptor(
        id: "file.view", title: L10n.tr("Podgląd"), category: .file, tc: ["f3"], cmd: ["alt+space", "cmd+3"],
        agent: .read, effect: .uiState, summary: L10n.tr("Otwiera podgląd pliku (tekst w wybranym kodowaniu, hex, obrazy)."))
    ) { ctx in
        guard let item = ctx.tab.cursorItem, !item.isParentLink else { return .ok }
        if item.isDirectory {
            if item.path.isLocal { ctx.tab.calculateSize(of: item) }
        } else {
            try ctx.requireUI().showViewer(try await ctx.workspace.materialize(item))
        }
        return .ok
    },

    Command(CommandDescriptor(
        id: "file.edit", title: L10n.tr("Edytuj"), category: .file, tc: ["f4"], cmd: ["cmd+4", "cmd+e"],
        agent: .none, effect: .external, summary: L10n.tr("Otwiera plik w edytorze (domyślnie Nextpad++)."))
    ) { ctx in
        var files: [URL] = []
        for item in try ctx.targets(allowNonLocal: true) where !item.isNavigable {
            if let url = try await ctx.workspace.materialize(item).path.url { files.append(url) }
        }
        guard !files.isEmpty else { throw CommandError.nothingSelected }
        try ctx.requireUI().openInEditor(files)
        return .ok
    },

    Command(
        CommandDescriptor(
            id: "file.newFile", title: L10n.tr("Nowy plik…"), category: .file, tc: ["shift+f4"], cmd: ["cmd+alt+n"],
            parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa nowego pliku (w bieżącym katalogu)")),
                         CommandParameter("openInEditor", .boolean, L10n.tr("Otwórz w edytorze (domyślnie tak)"))],
            agent: .approval, effect: .modifiesFiles,
            summary: L10n.tr("Tworzy pusty plik o podanej nazwie i otwiera go w domyślnym edytorze.")),
        preview: { @MainActor ctx in
            let name = try await ctx.text("name", title: L10n.tr("Nowy plik"))
            let path = resolvePath(name, relativeTo: ctx.tab.path)
            return EffectPreview(summary: L10n.tr("Nowy pusty plik \(path.path)"), operations: [PlannedOperation(kind: "createFile", source: nil, destination: path)], fileCount: 1)
        }
    ) { ctx in
        if let fs = try await ctx.remoteFS(ctx.tab.path) {
            let name = try await ctx.text("name", title: L10n.tr("Nowy plik"), message: L10n.tr("Nazwa pliku:"), default: "nowy.txt", selectStem: true)
            let path = ctx.tab.path.appending(name)
            try await fs.createFile(path, contents: Data())
            try await ctx.tab.navigate(to: ctx.tab.path, focus: path.name, recordHistory: false)
            return CommandResult(message: path.displayPath)
        }
        _ = try ctx.requireLocalDirectory()
        let name = try await ctx.text("name", title: L10n.tr("Nowy plik"), message: L10n.tr("Nazwa pliku:"), default: "nowy.txt", selectStem: true)
        let path = resolvePath(name, relativeTo: ctx.tab.path)
        try validateFileName(path.name)
        try await ctx.workspace.fileOps.createFile(path, invoker: ctx.invoker)
        if path.parent == ctx.tab.path { try await ctx.tab.navigate(to: ctx.tab.path, focus: path.name, recordHistory: false) }
        if ctx.arguments.bool("openInEditor") ?? true, let url = path.url { ctx.ui?.openInEditor([url]) }
        return CommandResult(message: path.path)
    },

    transferCommand(.copy),
    transferCommand(.move),

    Command(
        CommandDescriptor(
            id: "file.rename", title: L10n.tr("Zmień nazwę…"), category: .file, tc: ["shift+f6"], cmd: ["cmd+shift+r"],
            parameters: [CommandParameter("path", .path, L10n.tr("Element (domyślnie pod kursorem)")), CommandParameter("newName", .string, required: true, L10n.tr("Nowa nazwa"))],
            agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Zmienia nazwę elementu.")),
        preview: { @MainActor ctx in
            let source = try renameSource(ctx)
            let newName = try await ctx.text("newName", title: L10n.tr("Zmień nazwę"), default: source.name)
            guard let parent = source.parent else { throw CommandError.invalidArgument("path", source.displayPath) }
            let target = parent.appending(newName)
            // Także na serwerze: inaczej okno zgody pokazywałoby „bez konfliktu” dla istniejącego celu.
            let provider = try? ctx.workspace.providers.provider(for: target)
            let exists = await (provider?.exists(target) ?? false) && target.path.lowercased() != source.path.lowercased()
            return EffectPreview(summary: "\(source.name) → \(newName)", operations: [PlannedOperation(kind: "rename", source: source, destination: target, conflict: exists)], fileCount: 1, conflicts: exists ? [target.path] : [])
        }
    ) { ctx in
        let source = try renameSource(ctx)
        let newName = try await ctx.text("newName", title: L10n.tr("Zmień nazwę"), message: L10n.tr("Nowa nazwa:"), default: source.name, selectStem: true)
        guard newName != source.name else { return .ok }
        if let fs = try await ctx.remoteFS(source) {
            let target = try await fs.rename(source, to: newName)
            try await ctx.tab.navigate(to: ctx.tab.path, focus: target.name, recordHistory: false)
            return CommandResult(message: target.displayPath)
        }
        let target = try await ctx.workspace.fileOps.rename(source, to: newName, invoker: ctx.invoker)
        if target.parent == ctx.tab.path { try await ctx.tab.navigate(to: ctx.tab.path, focus: target.name, recordHistory: false) }
        return CommandResult(message: target.path)
    },

    Command(
        CommandDescriptor(
            id: "file.mkdir", title: L10n.tr("Nowy katalog…"), category: .file, tc: ["f7"], cmd: ["cmd+7", "cmd+shift+n"],
            parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa katalogu; a/b/c tworzy zagnieżdżone"))],
            agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Tworzy katalog (także zagnieżdżony) w bieżącym katalogu.")),
        preview: { @MainActor ctx in
            let name = try await ctx.text("name", title: L10n.tr("Nowy katalog"))
            let path = resolvePath(name, relativeTo: ctx.tab.path)
            return EffectPreview(summary: L10n.tr("Nowy katalog \(path.path)"), operations: [PlannedOperation(kind: "mkdir", source: nil, destination: path, isDirectory: true)])
        }
    ) { ctx in
        if let fs = try await ctx.remoteFS(ctx.tab.path) {
            let name = try await ctx.text("name", title: L10n.tr("Nowy katalog"), message: L10n.tr("Nazwa katalogu:"))
            let path = ctx.tab.path.appending(name)
            try await fs.createDirectory(path)
            try await ctx.tab.navigate(to: ctx.tab.path, focus: path.name, recordHistory: false)
            return CommandResult(message: path.displayPath)
        }
        _ = try ctx.requireLocalDirectory()
        let name = try await ctx.text("name", title: L10n.tr("Nowy katalog"), message: L10n.tr("Nazwa katalogu:"))
        let path = resolvePath(name, relativeTo: ctx.tab.path)
        // Tworzenie kolejnych brakujących poziomów, każdy zapisany w dzienniku.
        var missing: [VFSPath] = []
        var p: VFSPath? = path
        while let c = p, !(await LocalFS().exists(c)) {
            missing.insert(c, at: 0)
            p = c.parent
        }
        guard !missing.isEmpty else { throw VFSError.alreadyExists(path) }
        for dir in missing { try await ctx.workspace.fileOps.makeDirectory(dir, invoker: ctx.invoker) }
        let first = missing[0]
        if first.parent == ctx.tab.path { try await ctx.tab.navigate(to: ctx.tab.path, focus: first.name, recordHistory: false) }
        return CommandResult(message: path.path)
    },

    Command(
        CommandDescriptor(
            id: "file.trash", title: L10n.tr("Przenieś do Kosza"), category: .file, tc: ["f8", "delete"], cmd: ["cmd+backspace", "cmd+8"],
            parameters: [pathsParam], agent: .approval, effect: .modifiesFiles,
            summary: L10n.tr("Przenosi elementy do Kosza (da się cofnąć).")),
        preview: { @MainActor ctx in
            let items = try ctx.targets(allowNonLocal: true)
            let remote = RemoteFS.alias(of: items.first?.path ?? .root) != nil
            return EffectPreview(
                summary: remote ? L10n.tr("TRWAŁE usunięcie z serwera: \(Format.describe(items))") : L10n.tr("Do Kosza: \(Format.describe(items))"),
                operations: items.map { PlannedOperation(kind: "trash", source: $0.path, destination: nil, isDirectory: $0.isDirectory, bytes: max(0, $0.size)) },
                fileCount: items.count, totalBytes: items.reduce(0) { $0 + max(0, $1.size) })
        }
    ) { ctx in
        let candidates = try ctx.targets(allowNonLocal: true)
        if let first = candidates.first, let fs = try await ctx.remoteFS(first.path) {
            // Serwery nie mają Kosza — trwałe usunięcie, zawsze potwierdzane przez użytkownika.
            if !ctx.isAgent {
                guard try await ctx.requireUI().confirm(
                    title: L10n.tr("Usunąć z serwera?"), message: L10n.tr("\(Format.describe(candidates)) zostanie usunięte z \(fs.connection.alias) bez możliwości cofnięcia."),
                    confirmTitle: L10n.tr("Usuń"), destructive: true)
                else { throw CommandError.cancelledByUser }
            }
            for item in candidates { try await fs.deletePermanently(item.path) }
            await ctx.tab.reload()
            return CommandResult(message: L10n.tr("Usunięto z serwera: \(candidates.count)"))
        }
        let items = try ctx.targets()
        if !ctx.isAgent, ctx.workspace.settings.confirmTrash, let ui = ctx.ui {
            guard await ui.confirm(title: L10n.tr("Przenieść do Kosza?"), message: Format.describe(items), confirmTitle: L10n.tr("Do Kosza"), destructive: false) else {
                throw CommandError.cancelledByUser
            }
        }
        let job = ctx.workspace.jobs.enqueue(.trash(items.map(\.path)), title: L10n.tr("Do Kosza: \(Format.describe(items))"), invoker: ctx.invoker)
        if ctx.arguments["paths"] == nil { ctx.tab.clearSelection() }
        _ = await ctx.workspace.jobs.wait(for: job)
        return CommandResult(message: job.errors.first, value: ["job": .string(job.id.uuidString)])
    },

    Command(CommandDescriptor(
        id: "file.deletePermanently", title: L10n.tr("Usuń trwale…"), category: .file, tc: ["shift+f8", "shift+delete"], cmd: ["cmd+alt+backspace"],
        parameters: [pathsParam], agent: .none, effect: .modifiesFiles,
        summary: L10n.tr("Usuwa elementy bez Kosza — nieodwracalnie, zawsze z potwierdzeniem."))
    ) { ctx in
        let items = try ctx.targets()
        guard try await ctx.requireUI().confirm(
            title: L10n.tr("Usunąć trwale?"), message: L10n.tr("\(Format.describe(items)) zostanie usunięte bez możliwości cofnięcia."),
            confirmTitle: L10n.tr("Usuń trwale"), destructive: true)
        else { throw CommandError.cancelledByUser }
        ctx.tab.clearSelection()
        ctx.workspace.jobs.enqueue(.deletePermanently(items.map(\.path)), title: L10n.tr("Usuwanie: \(Format.describe(items))"), invoker: ctx.invoker)
        return .ok
    },

    Command(
        CommandDescriptor(
            id: "file.attributes", title: L10n.tr("Atrybuty i uprawnienia…"), category: .file, tc: ["ctrl+alt+a"], cmd: ["cmd+i"],
            parameters: [
                pathsParam,
                CommandParameter("permissions", .string, L10n.tr("Prawa ósemkowo, np. 644")),
                CommandParameter("owner", .integer, L10n.tr("UID właściciela")), CommandParameter("group", .integer, L10n.tr("GID grupy")),
                CommandParameter("modified", .string, L10n.tr("Data modyfikacji ISO 8601")), CommandParameter("created", .string, L10n.tr("Data utworzenia ISO 8601")),
                CommandParameter("hidden", .boolean, L10n.tr("Flaga „ukryty”")), CommandParameter("locked", .boolean, L10n.tr("Flaga „zablokowany”")),
            ],
            agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Zmienia prawa, właściciela, daty i flagi elementów.")),
        preview: { @MainActor ctx in
            let items = try ctx.targets()
            let change = try attributeChange(from: ctx.arguments)
            return EffectPreview(summary: L10n.tr("Atrybuty: \(Format.describe(items)) — \(describe(change))"),
                                 operations: items.map { PlannedOperation(kind: "setAttributes", source: $0.path, destination: nil) }, fileCount: items.count)
        }
    ) { ctx in
        let items = try ctx.targets()
        let change: AttributeChange
        if ctx.isAgent || ctx.arguments.values.keys.contains(where: { $0 != "paths" }) {
            change = try attributeChange(from: ctx.arguments)
        } else {
            guard let c = try await ctx.requireUI().promptAttributes(items: items) else { throw CommandError.cancelledByUser }
            change = c
        }
        try await ctx.workspace.fileOps.setAttributes(items.map(\.path), change, invoker: ctx.invoker)
        await ctx.tab.reload()
        return .ok
    },

    Command(
        CommandDescriptor(
            id: "file.tags", title: L10n.tr("Tagi Findera…"), category: .file, tc: ["ctrl+alt+g"], cmd: ["cmd+alt+g"],
            parameters: [pathsParam, CommandParameter("tags", .paths, required: true, L10n.tr("Nowa lista tagów (zastępuje dotychczasowe)"))],
            agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Ustawia tagi Findera dla elementów.")),
        preview: { @MainActor ctx in
            let items = try ctx.targets()
            let tags = ctx.arguments.strings("tags") ?? []
            return EffectPreview(summary: L10n.tr("Tagi \(Format.describe(items)): \(tags.joined(separator: ", "))"),
                                 operations: items.map { PlannedOperation(kind: "setTags", source: $0.path, destination: nil) }, fileCount: items.count)
        }
    ) { ctx in
        let items = try ctx.targets()
        let tags: [String]
        if let t = ctx.arguments.strings("tags") {
            tags = t
        } else if ctx.isAgent {
            throw CommandError.missingArgument("tags")
        } else {
            let first = items[0].path
            let current = (try? await runBlocking(qos: .userInitiated) { try LocalFS().tagsSync(of: first) }) ?? []
            guard let t = try await ctx.requireUI().promptTags(items: items, current: current) else { throw CommandError.cancelledByUser }
            tags = t
        }
        try await ctx.workspace.fileOps.setTags(items.map(\.path), tags: tags, invoker: ctx.invoker)
        return .ok
    },
] }

@MainActor
private func renameSource(_ ctx: CommandContext) throws -> VFSPath {
    if let raw = ctx.arguments.string("path") {
        // Katalog główny (także `alias:/`) nie ma nazwy do zmiany.
        let path = ctx.workspace.parsePath(raw, relativeTo: ctx.tab.path)
        guard !path.isRoot else { throw CommandError.invalidArgument("path", raw) }
        return path
    }
    guard let item = ctx.tab.cursorItem, !item.isParentLink else { throw CommandError.nothingSelected }
    return item.path
}

func attributeChange(from args: CommandArguments) throws -> AttributeChange {
    var change = AttributeChange()
    if let p = args.string("permissions") {
        guard let v = UInt16(p, radix: 8), v <= 0o7777 else { throw CommandError.invalidArgument("permissions", L10n.tr("liczba ósemkowa, np. 644")) }
        change.permissions = v
    }
    // UID/GID spoza zakresu UInt32 (np. -1 od agenta) — błąd zamiast awarii.
    for key in ["owner", "group"] {
        guard let raw = args.int(key) else { continue }
        guard let id = UInt32(exactly: raw) else { throw CommandError.invalidArgument(key, "0…\(UInt32.max)") }
        if key == "owner" { change.owner = id } else { change.group = id }
    }
    let iso = ISO8601DateFormatter()
    if let m = args.string("modified") {
        guard let d = iso.date(from: m) else { throw CommandError.invalidArgument("modified", "ISO 8601") }
        change.modified = d
    }
    if let c = args.string("created") {
        guard let d = iso.date(from: c) else { throw CommandError.invalidArgument("created", "ISO 8601") }
        change.created = d
    }
    change.hidden = args.bool("hidden")
    change.locked = args.bool("locked")
    return change
}

func describe(_ change: AttributeChange) -> String {
    var parts: [String] = []
    if let p = change.permissions { parts.append(String(p, radix: 8)) }
    if let o = change.owner { parts.append("uid \(o)") }
    if let g = change.group { parts.append("gid \(g)") }
    if let m = change.modified { parts.append(L10n.tr("zmod. \(m.formatted())")) }
    if let c = change.created { parts.append(L10n.tr("utw. \(c.formatted())")) }
    if let h = change.hidden { parts.append(h ? L10n.tr("ukryty") : L10n.tr("widoczny")) }
    if let l = change.locked { parts.append(l ? L10n.tr("zablokowany") : L10n.tr("odblokowany")) }
    return parts.joined(separator: ", ")
}
