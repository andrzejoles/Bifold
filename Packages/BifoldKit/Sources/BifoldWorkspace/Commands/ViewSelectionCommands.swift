import BifoldCore
import Foundation

@MainActor
private func viewModeCommand(_ mode: ViewMode, _ n: Int) -> Command {
    Command(CommandDescriptor(
        id: CommandID(rawValue: "view.\(mode.rawValue)"), title: mode.displayName, category: .view, tc: ["ctrl+\(n)"],
        agent: .full, effect: .uiState, summary: L10n.tr("Przełącza widok aktywnej karty: \(mode.displayName).")
    )) { ctx in
        ctx.tab.viewMode = mode
        return .ok
    }
}

@MainActor
private func sortCommand(_ field: SortField, tc: String, cmd: String) -> Command {
    Command(CommandDescriptor(
        id: CommandID(rawValue: "view.sortBy.\(field.rawValue)"), title: L10n.tr("Sortuj: \(field.displayName)"), category: .view, tc: [tc], cmd: [cmd],
        agent: .full, effect: .uiState, summary: L10n.tr("Sortuje według pola \(field.displayName); ponowne wywołanie odwraca kolejność.")
    )) { ctx in
        let tab = ctx.tab
        tab.sort = tab.sort.field == field ? SortSpec(field: field, ascending: !tab.sort.ascending) : SortSpec(field: field, ascending: field == .name || field == .ext)
        return .ok
    }
}

@MainActor
var viewCommands: [Command] { [
    viewModeCommand(.details, 1), viewModeCommand(.brief, 2), viewModeCommand(.thumbnails, 3), viewModeCommand(.columns, 4),

    Command(CommandDescriptor(
        id: "view.setMode", title: L10n.tr("Ustaw widok"), category: .view,
        parameters: [CommandParameter("mode", .string, required: true, L10n.tr("Rodzaj widoku"), allowed: ViewMode.allCases.map(\.rawValue)), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Ustawia widok karty: details, brief, thumbnails albo columns."), inMenu: false)
    ) { ctx in
        guard let raw = ctx.arguments.string("mode"), let mode = ViewMode(rawValue: raw) else {
            throw CommandError.invalidArgument("mode", ViewMode.allCases.map(\.rawValue).joined(separator: " | "))
        }
        try ctx.tab(forSide: "side").viewMode = mode
        return .ok
    },

    sortCommand(.name, tc: "ctrl+f3", cmd: "cmd+ctrl+1"),
    sortCommand(.ext, tc: "ctrl+f4", cmd: "cmd+ctrl+2"),
    sortCommand(.modified, tc: "ctrl+f5", cmd: "cmd+ctrl+3"),
    sortCommand(.size, tc: "ctrl+f6", cmd: "cmd+ctrl+4"),
    sortCommand(.created, tc: "ctrl+f7", cmd: "cmd+ctrl+5"),

    Command(CommandDescriptor(
        id: "view.sortBy", title: L10n.tr("Sortuj"), category: .view,
        parameters: [
            CommandParameter("field", .string, required: true, L10n.tr("Pole sortowania"), allowed: SortField.allCases.map(\.rawValue)),
            CommandParameter("ascending", .boolean, L10n.tr("Rosnąco (domyślnie tak)")), sideParam,
        ],
        agent: .full, effect: .uiState, summary: L10n.tr("Ustawia sortowanie karty."), inMenu: false)
    ) { ctx in
        guard let raw = ctx.arguments.string("field"), let field = SortField(rawValue: raw) else {
            throw CommandError.invalidArgument("field", SortField.allCases.map(\.rawValue).joined(separator: " | "))
        }
        try ctx.tab(forSide: "side").sort = SortSpec(field: field, ascending: ctx.arguments.bool("ascending") ?? true)
        return .ok
    },

    Command(CommandDescriptor(
        id: "view.toggleTree", title: L10n.tr("Drzewo katalogów"), category: .view, tc: ["ctrl+shift+t"], cmd: ["cmd+alt+t"],
        agent: .read, effect: .uiState, summary: L10n.tr("Pokazuje lub ukrywa drzewo katalogów obok listy plików."))
    ) { ctx in
        ctx.workspace.activePanel.showsTree.toggle()
        return .ok
    },

    Command(CommandDescriptor(
        id: "view.previewPanel", title: L10n.tr("Panel podglądu"), category: .view, tc: ["ctrl+q"], cmd: ["cmd+alt+p", "ctrl+q"],
        agent: .read, effect: .uiState, summary: L10n.tr("Drugi panel pokazuje podgląd elementu pod kursorem (jak Ctrl+Q w TC)."))
    ) { ctx in
        ctx.workspace.quickViewActive.toggle()
        return .ok
    },

    Command(CommandDescriptor(
        id: "view.quickLook", title: L10n.tr("Quick Look"), category: .view, tc: ["cmd+y"], cmd: ["cmd+y"],
        agent: .read, effect: .uiState, summary: L10n.tr("Otwiera Quick Look dla zaznaczonych elementów."))
    ) { ctx in
        try ctx.requireUI().toggleQuickLook(try ctx.targets())
        return .ok
    },

    Command(CommandDescriptor(
        id: "view.toggleHidden", title: L10n.tr("Pokaż pliki ukryte"), category: .view, tc: ["ctrl+h", "cmd+shift+."], cmd: ["cmd+shift+."],
        agent: .full, effect: .settings, summary: L10n.tr("Pokazuje lub ukrywa pliki ukryte."))
    ) { ctx in
        ctx.workspace.settings.showHiddenFiles.toggle()
        return .ok
    },
] }

@MainActor
var selectionCommands: [Command] { [
    Command(CommandDescriptor(
        id: "selection.toggle", title: L10n.tr("Zaznacz / odznacz"), category: .selection, tc: ["space"],
        agent: .full, effect: .uiState,
        summary: L10n.tr("Przełącza zaznaczenie elementu pod kursorem i przesuwa kursor w dół; dla katalogu liczy jego rozmiar."), inMenu: false)
    ) { ctx in
        let tab = ctx.tab
        guard let item = tab.cursorItem else { return .ok }
        if !item.isParentLink {
            tab.toggleSelection(item.path)
            if item.isDirectory && tab.selection.contains(item.path) { tab.calculateSize(of: item) }
        }
        if let i = tab.cursorIndex { tab.moveCursor(to: i + 1) }
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.toggleUp", title: L10n.tr("Zaznacz i w górę"), category: .selection, tc: ["shift+up"],
        agent: .full, effect: .uiState, summary: L10n.tr("Przełącza zaznaczenie elementu i przesuwa kursor w górę."), inMenu: false)
    ) { ctx in
        let tab = ctx.tab
        if let item = tab.cursorItem, !item.isParentLink { tab.toggleSelection(item.path) }
        if let i = tab.cursorIndex { tab.moveCursor(to: i - 1) }
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.toggleDown", title: L10n.tr("Zaznacz i w dół"), category: .selection, tc: ["shift+down"],
        agent: .full, effect: .uiState, summary: L10n.tr("Przełącza zaznaczenie elementu i przesuwa kursor w dół."), inMenu: false)
    ) { ctx in
        let tab = ctx.tab
        if let item = tab.cursorItem, !item.isParentLink { tab.toggleSelection(item.path) }
        if let i = tab.cursorIndex { tab.moveCursor(to: i + 1) }
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.byMask", title: L10n.tr("Zaznacz według maski…"), category: .selection, tc: ["cmd+="], cmd: ["cmd+="],
        parameters: [
            CommandParameter("mask", .string, required: true, L10n.tr("Maska, np. *.jpg;*.png|tmp*")),
            CommandParameter("includeDirectories", .boolean, L10n.tr("Także katalogi")), sideParam,
        ],
        agent: .full, effect: .uiState, summary: L10n.tr("Dodaje do zaznaczenia elementy pasujące do maski."))
    ) { ctx in
        let mask = try await maskArgument(ctx, title: L10n.tr("Zaznacz według maski"))
        let n = try ctx.tab(forSide: "side").select(mask: mask, selected: true, includeDirectories: ctx.arguments.bool("includeDirectories") ?? false)
        return CommandResult(message: L10n.tr("Zaznaczono: \(n)"), value: .int(Int64(n)))
    },

    Command(CommandDescriptor(
        id: "selection.deselectByMask", title: L10n.tr("Odznacz według maski…"), category: .selection, tc: ["cmd+-"], cmd: ["cmd+-"],
        parameters: [CommandParameter("mask", .string, required: true, L10n.tr("Maska")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Usuwa z zaznaczenia elementy pasujące do maski."))
    ) { ctx in
        let mask = try await maskArgument(ctx, title: L10n.tr("Odznacz według maski"))
        let n = try ctx.tab(forSide: "side").select(mask: mask, selected: false, includeDirectories: true)
        return CommandResult(value: .int(Int64(n)))
    },

    Command(CommandDescriptor(
        id: "selection.invert", title: L10n.tr("Odwróć zaznaczenie"), category: .selection, tc: ["cmd+*"], cmd: ["cmd+*"],
        parameters: [CommandParameter("includeDirectories", .boolean, L10n.tr("Także katalogi")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Odwraca zaznaczenie plików w panelu."))
    ) { ctx in
        try ctx.tab(forSide: "side").invertSelection(includeDirectories: ctx.arguments.bool("includeDirectories") ?? false)
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.all", title: L10n.tr("Zaznacz wszystko"), category: .selection, tc: ["cmd+a"], cmd: ["cmd+a"],
        parameters: [sideParam], agent: .full, effect: .uiState, summary: L10n.tr("Zaznacza wszystkie elementy panelu."))
    ) { ctx in
        try ctx.tab(forSide: "side").selectAll()
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.none", title: L10n.tr("Odznacz wszystko"), category: .selection, tc: ["cmd+shift+a"], cmd: ["cmd+shift+a"],
        parameters: [sideParam], agent: .full, effect: .uiState, summary: L10n.tr("Czyści zaznaczenie."))
    ) { ctx in
        try ctx.tab(forSide: "side").clearSelection()
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.sameExtension", title: L10n.tr("Zaznacz pliki z tym samym rozszerzeniem"), category: .selection, tc: ["alt+="], cmd: ["cmd+alt+shift+="],
        agent: .full, effect: .uiState, summary: L10n.tr("Zaznacza pliki o rozszerzeniu takim jak element pod kursorem."))
    ) { ctx in
        guard let item = ctx.tab.cursorItem, !item.isNavigable else { return .ok }
        let ext = item.fileExtension
        ctx.tab.select(mask: ext.isEmpty ? "*|*.*" : "*.\(ext)", selected: true)
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.set", title: L10n.tr("Ustaw zaznaczenie"), category: .selection,
        parameters: [CommandParameter("names", .paths, required: true, L10n.tr("Nazwy elementów w bieżącym katalogu")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Zastępuje zaznaczenie podanymi elementami bieżącego katalogu."), inMenu: false)
    ) { ctx in
        let tab = try ctx.tab(forSide: "side")
        let names = ctx.arguments.strings("names") ?? []
        tab.setSelection(Set(names.map { resolvePath($0, relativeTo: tab.path) }))
        return CommandResult(value: .int(Int64(tab.selection.count)))
    },

    Command(CommandDescriptor(
        id: "selection.save", title: L10n.tr("Zapamiętaj zaznaczenie"), category: .selection,
        agent: .full, effect: .uiState, summary: L10n.tr("Zapamiętuje nazwy zaznaczonych elementów."))
    ) { ctx in
        SelectionMemory.shared.names = ctx.tab.selectedItems.map(\.name)
        return CommandResult(message: Format.items(SelectionMemory.shared.names.count))
    },

    Command(CommandDescriptor(
        id: "selection.restore", title: L10n.tr("Przywróć zaznaczenie"), category: .selection,
        agent: .full, effect: .uiState, summary: L10n.tr("Zaznacza elementy o zapamiętanych nazwach w bieżącym katalogu."))
    ) { ctx in
        let tab = ctx.tab
        tab.setSelection(tab.selection.union(SelectionMemory.shared.names.map { tab.path.appending($0) }))
        return .ok
    },

    Command(CommandDescriptor(
        id: "selection.saveToFile", title: L10n.tr("Zapisz zaznaczenie do pliku…"), category: .selection,
        parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa zapisanego zaznaczenia"))],
        agent: .full, effect: .settings, summary: L10n.tr("Zapisuje listę zaznaczonych nazw w katalogu aplikacji."))
    ) { ctx in
        let name = try await ctx.text("name", title: L10n.tr("Nazwa zaznaczenia"), default: ctx.tab.path.name)
        try validateFileName(name)
        let dir = ctx.workspace.paths.selections
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = ctx.tab.selectedItems.map(\.name).joined(separator: "\n")
        try Data(text.utf8).write(to: dir.appending(path: name + ".txt"), options: .atomic)
        return CommandResult(message: dir.appending(path: name + ".txt").path)
    },

    Command(CommandDescriptor(
        id: "selection.loadFromFile", title: L10n.tr("Wczytaj zaznaczenie z pliku…"), category: .selection,
        parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa zapisanego zaznaczenia"))],
        agent: .full, effect: .uiState, summary: L10n.tr("Zaznacza elementy z zapisanej listy nazw."))
    ) { ctx in
        let name = try await ctx.text("name", title: L10n.tr("Nazwa zaznaczenia"))
        try validateFileName(name)
        let url = ctx.workspace.paths.selections.appending(path: name + ".txt")
        let names = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let tab = ctx.tab
        tab.setSelection(Set(names.map { tab.path.appending($0) }))
        return CommandResult(value: .int(Int64(tab.selection.count)))
    },

    Command(CommandDescriptor(
        id: "selection.calculateSizes", title: L10n.tr("Oblicz rozmiary katalogów"), category: .selection, tc: ["alt+shift+enter"], cmd: ["cmd+alt+enter"],
        parameters: [pathsParam], agent: .read, effect: .none,
        summary: L10n.tr("Liczy rozmiary zaznaczonych katalogów (bez zaznaczenia — wszystkich w panelu)."))
    ) { ctx in
        let tab = ctx.tab
        if ctx.isAgent || ctx.arguments["paths"] != nil {
            var out: [String: JSONValue] = [:]
            for item in try ctx.targets() {
                let size = try await DirectorySizer.size(of: item.path)
                if item.isDirectory { tab.setDirectorySize(size, for: item.path) }
                out[item.path.path] = ["bytes": .int(size.bytes), "files": .int(Int64(size.files)), "directories": .int(Int64(size.directories))]
            }
            return CommandResult(value: .object(out))
        }
        let dirs = tab.selection.isEmpty ? tab.visibleItems.filter { $0.isDirectory && !$0.isParentLink } : tab.selectedItems.filter(\.isDirectory)
        dirs.forEach(tab.calculateSize)
        return .ok
    },
] }

@MainActor
private func maskArgument(_ ctx: CommandContext, title: String) async throws -> String {
    if let m = ctx.arguments.string("mask") { return m }
    if ctx.isAgent { throw CommandError.missingArgument("mask") }
    guard let m = try await ctx.requireUI().promptMask(title: title, defaultMask: SelectionMemory.shared.lastMask) else {
        throw CommandError.cancelledByUser
    }
    SelectionMemory.shared.lastMask = m
    return m
}

/// Zapamiętane zaznaczenie i ostatnia maska (w pamięci, jak w TC).
@MainActor
final class SelectionMemory {
    static let shared = SelectionMemory()
    var names: [String] = []
    var lastMask = "*.*"
}
