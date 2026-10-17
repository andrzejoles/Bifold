import BifoldCore
import Foundation

@MainActor
var clipboardCommands: [Command] { [
    Command(CommandDescriptor(
        id: "clipboard.copyPaths", title: L10n.tr("Kopiuj ścieżki"), category: .clipboard, tc: ["cmd+alt+c"], cmd: ["cmd+alt+c"],
        parameters: [pathsParam], agent: .full, effect: .uiState, summary: L10n.tr("Kopiuje pełne ścieżki elementów do schowka (jedna w wierszu)."))
    ) { ctx in
        let paths = try ctx.targets().map(\.path.path)
        try ctx.requireUI().copyToPasteboard(paths)
        return CommandResult(message: Format.items(paths.count))
    },

    Command(CommandDescriptor(
        id: "clipboard.copyNames", title: L10n.tr("Kopiuj nazwy"), category: .clipboard, tc: ["ctrl+alt+c"], cmd: ["ctrl+alt+c"],
        parameters: [pathsParam], agent: .full, effect: .uiState, summary: L10n.tr("Kopiuje nazwy elementów do schowka (jedna w wierszu)."))
    ) { ctx in
        let names = try ctx.targets().map(\.name)
        try ctx.requireUI().copyToPasteboard(names)
        return CommandResult(message: Format.items(names.count))
    },

    Command(CommandDescriptor(
        id: "clipboard.copyDirectory", title: L10n.tr("Kopiuj ścieżkę katalogu"), category: .clipboard, tc: ["ctrl+alt+shift+c"],
        agent: .full, effect: .uiState, summary: L10n.tr("Kopiuje ścieżkę bieżącego katalogu do schowka."))
    ) { ctx in
        try ctx.requireUI().copyToPasteboard([ctx.tab.path.path])
        return .ok
    },
] }

@MainActor
var editCommands: [Command] { [
    Command(
        CommandDescriptor(
            id: "edit.undo", title: L10n.tr("Cofnij operację"), category: .edit, tc: ["cmd+z"],
            agent: .approval, effect: .modifiesFiles,
            summary: L10n.tr("Cofa ostatnią operację na plikach (przeniesienie, zmianę nazwy, Kosz, utworzenie, kopię, atrybuty, tagi). Agent cofa tylko własne operacje.")),
        preview: { @MainActor ctx in
            guard let plan = undoPlan(ctx) else { return EffectPreview(summary: L10n.tr("Nie ma czego cofać")) }
            return EffectPreview(summary: L10n.tr("Cofnięcie: \(undoTitle(ctx) ?? "")"), operations: plan.steps.map(\.preview),
                                 fileCount: plan.steps.count, conflicts: plan.conflicts.map(\.message))
        }
    ) { ctx in
        guard let plan = undoPlan(ctx), !plan.isEmpty else { return CommandResult(message: L10n.tr("Nie ma czego cofać")) }
        var force = false
        if !ctx.isAgent, !plan.conflicts.isEmpty {
            let answer = try await ctx.requireUI().confirmUndo(plan, title: undoTitle(ctx) ?? "")
            guard answer.proceed else { throw CommandError.cancelledByUser }
            force = answer.force
        }
        let result = await ctx.workspace.fileOps.execute(plan, force: force)
        await ctx.workspace.left.activeTab.reload()
        await ctx.workspace.right.activeTab.reload()
        let message = L10n.tr("Cofnięto: \(result.performed), pominięto: \(result.skipped.count), błędy: \(result.errors.count)")
        return CommandResult(message: message, value: ["performed": .int(Int64(result.performed)), "skipped": .array(result.skipped.map { .string($0.message) })])
    },

    Command(CommandDescriptor(
        id: "edit.journal", title: L10n.tr("Dziennik operacji"), category: .edit, tc: ["cmd+alt+j"],
        agent: .none, effect: .uiState, summary: L10n.tr("Pokazuje dziennik operacji na plikach."))
    ) { ctx in
        try ctx.requireUI().showJournal()
        return .ok
    },
] }

@MainActor
private func undoPlan(_ ctx: CommandContext) -> UndoPlan? {
    if let session = ctx.invoker.agentSessionID {
        return ctx.workspace.fileOps.undoPlanForLast { $0.invoker.agentSessionID == session }
    }
    return ctx.workspace.fileOps.undoPlanForLast()
}

@MainActor
private func undoTitle(_ ctx: CommandContext) -> String? {
    let session = ctx.invoker.agentSessionID
    return ctx.workspace.journal.lastUndoable { session == nil || $0.invoker.agentSessionID == session }?.title
}

@MainActor
private func jobArgument(_ ctx: CommandContext) -> [Job] {
    if let raw = ctx.arguments.string("job"), let id = UUID(uuidString: raw), let job = ctx.workspace.jobs.job(id) { return [job] }
    return ctx.workspace.jobs.activeJobs
}

private let jobParam = CommandParameter("job", .string, L10n.tr("Identyfikator zadania (domyślnie wszystkie aktywne)"))

@MainActor
var queueCommands: [Command] { [
    Command(CommandDescriptor(
        id: "queue.pause", title: L10n.tr("Wstrzymaj operacje"), category: .queue, parameters: [jobParam],
        agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Wstrzymuje zadania w tle."))
    ) { ctx in
        jobArgument(ctx).forEach(ctx.workspace.jobs.pause)
        return .ok
    },

    Command(CommandDescriptor(
        id: "queue.resume", title: L10n.tr("Wznów operacje"), category: .queue, parameters: [jobParam],
        agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Wznawia wstrzymane zadania."))
    ) { ctx in
        jobArgument(ctx).forEach(ctx.workspace.jobs.resume)
        return .ok
    },

    Command(CommandDescriptor(
        id: "queue.cancel", title: L10n.tr("Anuluj operacje"), category: .queue, parameters: [jobParam],
        agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Anuluje zadania w tle (bez pozostawiania częściowych plików)."))
    ) { ctx in
        jobArgument(ctx).forEach(ctx.workspace.jobs.cancel)
        return .ok
    },

    Command(CommandDescriptor(
        id: "queue.setSpeedLimit", title: L10n.tr("Limit prędkości…"), category: .queue,
        parameters: [jobParam, CommandParameter("bytesPerSecond", .integer, required: true, L10n.tr("Bajty na sekundę (0 = bez limitu)"))],
        agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Ogranicza prędkość zadań w tle."))
    ) { ctx in
        let limit: Int64
        if let v = ctx.arguments.int("bytesPerSecond") {
            limit = v
        } else {
            let text = try await ctx.text("bytesPerSecond", title: L10n.tr("Limit prędkości"), message: L10n.tr("MB/s (0 = bez limitu):"), default: "0")
            guard let mb = Double(text.replacingOccurrences(of: ",", with: ".")) else { throw CommandError.invalidArgument("bytesPerSecond", text) }
            limit = Int64(mb * 1024 * 1024)
        }
        for job in jobArgument(ctx) { ctx.workspace.jobs.setSpeedLimit(job, limit) }
        return .ok
    },

    Command(CommandDescriptor(
        id: "queue.list", title: L10n.tr("Lista zadań"), category: .queue,
        agent: .read, effect: .none, summary: L10n.tr("Zwraca zadania w kolejce z postępem."), inMenu: false)
    ) { ctx in
        let jobs: [JSONValue] = ctx.workspace.jobs.jobs.map { job in
            ["id": .string(job.id.uuidString), "title": .string(job.title), "state": .string("\(job.state)"),
             "bytesDone": .int(job.progress.bytesDone), "bytesTotal": .int(job.progress.bytesTotal),
             "filesDone": .int(Int64(job.progress.filesDone)), "filesTotal": .int(Int64(job.progress.filesTotal))]
        }
        return CommandResult(value: .array(jobs))
    },

    Command(CommandDescriptor(
        id: "queue.clearFinished", title: L10n.tr("Usuń zakończone z listy"), category: .queue,
        agent: .full, effect: .uiState, summary: L10n.tr("Czyści listę zakończonych zadań."))
    ) { ctx in
        ctx.workspace.jobs.removeFinished()
        return .ok
    },

    Command(CommandDescriptor(
        id: "colors.get", title: L10n.tr("Reguły kolorów (JSON)"), category: .view,
        agent: .full, effect: .none, summary: L10n.tr("Zwraca reguły kolorowania plików w formacie JSON."), inMenu: false)
    ) { ctx in
        CommandResult(value: try JSONValue.encode(ctx.workspace.colorRules))
    },

    Command(CommandDescriptor(
        id: "colors.set", title: L10n.tr("Ustaw reguły kolorów"), category: .view,
        parameters: [CommandParameter("rules", .object, required: true, L10n.tr("Obiekt {\"rules\":[…]} jak w colors.get"))],
        agent: .full, effect: .settings, summary: L10n.tr("Zastępuje reguły kolorowania plików (warunki: wiek, rozmiar, rozszerzenie, atrybuty, maska, regex)."), inMenu: false)
    ) { ctx in
        guard let raw = ctx.arguments["rules"] else { throw CommandError.missingArgument("rules") }
        let rules: ColorRuleSet
        do {
            rules = try raw.decode(ColorRuleSet.self)
        } catch {
            throw CommandError.invalidArgument("rules", error.localizedDescription)
        }
        ctx.workspace.colorRules = rules
        return CommandResult(message: Format.items(rules.rules.count))
    },
] }

@MainActor
var toolCommands: [Command] { [
    Command(CommandDescriptor(
        id: "tools.commandPalette", title: L10n.tr("Paleta komend…"), category: .tools, tc: ["cmd+shift+p"],
        agent: .none, effect: .uiState, summary: L10n.tr("Wyszukiwanie i uruchamianie dowolnej komendy."))
    ) { ctx in
        try ctx.requireUI().showCommandPalette()
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.terminal", title: L10n.tr("Terminal"), category: .tools, tc: ["ctrl+`"], cmd: ["ctrl+`"],
        agent: .none, effect: .external, summary: L10n.tr("Pokazuje lub ukrywa wbudowany terminal w bieżącym katalogu."))
    ) { ctx in
        try ctx.requireUI().toggleTerminal(directory: ctx.tab.path)
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.commandLine", title: L10n.tr("Linia poleceń"), category: .tools, tc: ["cmd+l"], cmd: ["cmd+l"],
        agent: .none, effect: .external, summary: L10n.tr("Przenosi fokus do linii poleceń pod panelami."))
    ) { ctx in
        try ctx.requireUI().focusCommandLine()
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.runCommand", title: L10n.tr("Uruchom polecenie"), category: .tools,
        parameters: [CommandParameter("command", .string, required: true, L10n.tr("Polecenie powłoki"))],
        agent: .none, effect: .external, summary: L10n.tr("Uruchamia polecenie w powłoce użytkownika w bieżącym katalogu (wynik w terminalu)."), inMenu: false)
    ) { ctx in
        let command = try await ctx.text("command", title: L10n.tr("Polecenie"))
        try ctx.requireUI().runInTerminal(command: command, directory: ctx.tab.path)
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.volumes", title: L10n.tr("Dyski i woluminy…"), category: .tools, tc: ["alt+f1"], cmd: ["cmd+d"],
        agent: .read, effect: .uiState, summary: L10n.tr("Lista woluminów z wolnym miejscem."))
    ) { ctx in
        ctx.workspace.refreshVolumes()
        if ctx.isAgent {
            return CommandResult(value: try JSONValue.encode(ctx.workspace.volumes.map {
                ["name": $0.name, "path": $0.path.path, "total": String($0.totalCapacity), "available": String($0.availableCapacity), "ejectable": String($0.isEjectable)]
            }))
        }
        try ctx.requireUI().showVolumes()
        return .ok
    },

    Command(CommandDescriptor(
        id: "volume.eject", title: L10n.tr("Wysuń wolumin"), category: .tools, tc: ["cmd+alt+e"],
        parameters: [CommandParameter("path", .path, L10n.tr("Wolumin (domyślnie wolumin bieżącego katalogu)"))],
        agent: .none, effect: .external, summary: L10n.tr("Odmontowuje i wysuwa wolumin."))
    ) { ctx in
        guard let volume = ctx.arguments.path("path") ?? ctx.tab.volume?.path, volume != .root else {
            throw CommandError.notAvailable(L10n.tr("Tego woluminu nie można wysunąć"))
        }
        let info = try Volumes.info(for: volume)
        guard info.isEjectable || info.isRemovable || info.isNetwork else { throw CommandError.notAvailable(L10n.tr("Tego woluminu nie można wysunąć")) }
        for tab in ctx.workspace.left.tabs + ctx.workspace.right.tabs where tab.path.isDescendant(of: info.path) {
            try? await tab.navigate(to: .local(NSHomeDirectory()))
        }
        try await Volumes.eject(info.path)
        ctx.workspace.refreshVolumes()
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.share", title: L10n.tr("Udostępnij…"), category: .tools, tc: ["cmd+alt+s"],
        agent: .none, effect: .external, summary: L10n.tr("Menu Udostępnij macOS dla zaznaczonych elementów."))
    ) { ctx in
        try ctx.requireUI().share(try ctx.targets().compactMap(\.path.url))
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.openWith", title: L10n.tr("Otwórz za pomocą…"), category: .tools, tc: ["cmd+alt+o"],
        agent: .none, effect: .external, summary: L10n.tr("Wybór aplikacji do otwarcia elementów."))
    ) { ctx in
        try ctx.requireUI().openWith(try ctx.targets().compactMap(\.path.url))
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.revealInFinder", title: L10n.tr("Pokaż w Finderze"), category: .tools, tc: ["cmd+alt+r"],
        agent: .none, effect: .external, summary: L10n.tr("Pokazuje element w oknie Findera."))
    ) { ctx in
        let urls = try ctx.targets().compactMap(\.path.url)
        try ctx.requireUI().openWithDefaultApp(urls.map { $0.deletingLastPathComponent() })
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.settings", title: L10n.tr("Ustawienia…"), category: .tools, tc: ["cmd+,"],
        agent: .none, effect: .settings, summary: L10n.tr("Okno ustawień."))
    ) { ctx in
        try ctx.requireUI().showSettings()
        return .ok
    },

    Command(CommandDescriptor(
        id: "tools.switchShortcutProfile", title: L10n.tr("Przełącz profil skrótów (F-klawisze / Cmd)"), category: .tools,
        agent: .none, effect: .settings, summary: L10n.tr("Przełącza między profilem Total Commandera a profilem z Cmd."))
    ) { ctx in
        ctx.workspace.settings.shortcutProfile = ctx.workspace.settings.shortcutProfile == .totalCommander ? .command : .totalCommander
        return CommandResult(message: ctx.workspace.settings.shortcutProfile.displayName)
    },
] }
