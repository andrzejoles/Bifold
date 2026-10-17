import BifoldCore
import Foundation

extension CommandRegistry {
    /// Wszystkie komendy Etapu 1, w kolejności menu.
    @MainActor public static func standard() -> CommandRegistry {
        CommandRegistry(navigationCommands + tabCommands + viewCommands + selectionCommands + fileCommands + searchCommands + clipboardCommands + editCommands + queueCommands + toolCommands)
    }
}

let pathParam = CommandParameter("path", .path, required: true, L10n.tr("Ścieżka katalogu (absolutna, z ~ albo względna wobec bieżącego)"))
let sideParam = CommandParameter("side", .string, L10n.tr("Panel: left lub right (domyślnie aktywny)"), allowed: ["left", "right"])
let pathsParam = CommandParameter("paths", .paths, L10n.tr("Ścieżki elementów (domyślnie zaznaczenie lub element pod kursorem)"))

extension CommandContext {
    /// Karta wskazana argumentem `side` albo aktywna.
    func tab(forSide key: String = "side") throws -> Tab {
        guard let raw = arguments.string(key) else { return tab }
        guard let side = PanelSide(rawValue: raw) else { throw CommandError.invalidArgument(key, "left | right") }
        return workspace.panel(side).activeTab
    }
}

@MainActor
var navigationCommands: [Command] { [
    Command(CommandDescriptor(
        id: "panel.switch", title: L10n.tr("Przełącz panel"), category: .panel, tc: ["tab"],
        parameters: [sideParam], agent: .read, effect: .uiState,
        summary: L10n.tr("Ustawia fokus na drugim (albo wskazanym) panelu."))
    ) { ctx in
        if let raw = ctx.arguments.string("side"), let side = PanelSide(rawValue: raw) {
            ctx.workspace.activeSide = side
        } else {
            ctx.workspace.switchPanel()
        }
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.open", title: L10n.tr("Otwórz"), category: .panel, tc: ["enter"], cmd: ["enter", "cmd+down"],
        agent: .none, effect: .external,
        summary: L10n.tr("Wchodzi do katalogu pod kursorem albo otwiera plik w domyślnej aplikacji."))
    ) { ctx in
        guard let item = ctx.tab.cursorItem else { return .ok }
        if item.isParentLink {
            try await ctx.tab.goUp()
        } else if ctx.tab.isSearchResults, item.isNavigable {
            try await ctx.tab.navigate(to: item.path)
            ctx.tab.customTitle = nil
        } else if item.isNavigable && !(isPackage(item)) {
            try await ctx.tab.navigate(to: item.path)
        } else if let url = item.path.url {
            try ctx.requireUI().openWithDefaultApp([url])
        }
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.navigate", title: L10n.tr("Przejdź do katalogu…"), category: .panel, tc: ["cmd+shift+g"],
        parameters: [pathParam, sideParam], agent: .full, effect: .uiState,
        summary: L10n.tr("Otwiera katalog w aktywnym (lub wskazanym) panelu. Ścieżka do pliku otwiera jego katalog i ustawia na nim kursor."))
    ) { ctx in
        let tab = try ctx.tab(forSide: "side")
        let raw = try await ctx.text("path", title: L10n.tr("Przejdź do katalogu"), default: tab.path.path)
        let target = resolvePath(raw.trimmingCharacters(in: .whitespaces), relativeTo: tab.path)
        let item = try LocalFS().itemSync(at: target)
        if item.isNavigable {
            try await tab.navigate(to: target)
        } else if let parent = target.parent {
            try await tab.navigate(to: parent, focus: target.name)
        }
        return CommandResult(message: tab.path.description)
    },

    Command(CommandDescriptor(
        id: "panel.up", title: L10n.tr("Katalog nadrzędny"), category: .panel, tc: ["backspace", "ctrl+pageup"], cmd: ["backspace", "cmd+up"],
        parameters: [sideParam], agent: .full, effect: .uiState, summary: L10n.tr("Przechodzi do katalogu nadrzędnego."))
    ) { ctx in
        try await ctx.tab(forSide: "side").goUp()
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.root", title: L10n.tr("Katalog główny"), category: .panel, tc: ["ctrl+\\"], cmd: ["cmd+\\"],
        agent: .full, effect: .uiState, summary: L10n.tr("Przechodzi do katalogu głównego woluminu."))
    ) { ctx in
        let root = ctx.tab.volume?.path ?? .root
        try await ctx.tab.navigate(to: ctx.tab.path == root ? .root : root)
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.home", title: L10n.tr("Katalog domowy"), category: .panel, tc: ["cmd+shift+h"],
        agent: .full, effect: .uiState, summary: L10n.tr("Przechodzi do katalogu domowego."))
    ) { ctx in
        try await ctx.tab.navigate(to: .local(NSHomeDirectory()))
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.back", title: L10n.tr("Wstecz"), category: .panel, tc: ["alt+left"], cmd: ["cmd+["],
        agent: .full, effect: .uiState, summary: L10n.tr("Poprzedni katalog w historii karty."))
    ) { ctx in
        try await ctx.tab.goBack()
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.forward", title: L10n.tr("Dalej"), category: .panel, tc: ["alt+right"], cmd: ["cmd+]"],
        agent: .full, effect: .uiState, summary: L10n.tr("Następny katalog w historii karty."))
    ) { ctx in
        try await ctx.tab.goForward()
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.refresh", title: L10n.tr("Odśwież"), category: .panel, tc: ["ctrl+r"], cmd: ["cmd+r"],
        agent: .full, effect: .uiState, summary: L10n.tr("Ponownie wczytuje zawartość katalogu."))
    ) { ctx in
        await ctx.tab.reload()
        ctx.workspace.refreshVolumes()
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.otherToSame", title: L10n.tr("Ten sam katalog w drugim panelu"), category: .panel, tc: ["ctrl+="], cmd: ["cmd+alt+="],
        agent: .full, effect: .uiState, summary: L10n.tr("Otwiera w drugim panelu katalog aktywnego panelu."))
    ) { ctx in
        try await ctx.otherTab.navigate(to: ctx.tab.path)
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.openInOther", title: L10n.tr("Otwórz w drugim panelu"), category: .panel, tc: ["ctrl+shift+right"], cmd: ["cmd+alt+right"],
        agent: .full, effect: .uiState, summary: L10n.tr("Otwiera katalog spod kursora w drugim panelu."))
    ) { ctx in
        guard let item = ctx.tab.cursorItem else { return .ok }
        if item.isNavigable {
            try await ctx.otherTab.navigate(to: item.path)
        } else if let parent = item.path.parent {
            try await ctx.otherTab.navigate(to: parent, focus: item.name)
        }
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.swap", title: L10n.tr("Zamień panele"), category: .panel, tc: ["ctrl+u"], cmd: ["cmd+u"],
        agent: .full, effect: .uiState, summary: L10n.tr("Zamienia katalogi aktywnych kart obu paneli."))
    ) { ctx in
        let a = ctx.workspace.left.activeTab, b = ctx.workspace.right.activeTab
        let pa = a.path, pb = b.path
        try await a.navigate(to: pb)
        try await b.navigate(to: pa)
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.quickFilter", title: L10n.tr("Filtr panelu"), category: .panel, tc: ["ctrl+s"], cmd: ["cmd+f", "ctrl+s"],
        parameters: [CommandParameter("text", .string, L10n.tr("Fragment nazwy albo maska (np. *.jpg); pusty tekst wyłącza filtr")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Pokazuje w panelu tylko elementy pasujące do filtra."))
    ) { ctx in
        if let text = ctx.arguments.string("text") {
            try ctx.tab(forSide: "side").quickFilter = text
        } else {
            try ctx.requireUI().focusQuickFilter()
        }
        return .ok
    },

    Command(CommandDescriptor(
        id: "panel.quickSearch", title: L10n.tr("Szybkie wyszukiwanie"), category: .panel,
        parameters: [CommandParameter("text", .string, required: true, L10n.tr("Początek nazwy"))],
        agent: .full, effect: .uiState, summary: L10n.tr("Ustawia kursor na pierwszym elemencie, którego nazwa zaczyna się od podanego tekstu."), inMenu: false)
    ) { ctx in
        let found = ctx.tab.quickSearch(try await ctx.text("text", title: L10n.tr("Szukaj")))
        return CommandResult(value: .bool(found))
    },

    Command(CommandDescriptor(
        id: "panel.setCursor", title: L10n.tr("Ustaw kursor"), category: .panel,
        parameters: [CommandParameter("name", .string, L10n.tr("Nazwa elementu w bieżącym katalogu")), CommandParameter("index", .integer, L10n.tr("Numer wiersza (od 0)")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Ustawia kursor na elemencie o podanej nazwie lub numerze."), inMenu: false)
    ) { ctx in
        let tab = try ctx.tab(forSide: "side")
        if let name = ctx.arguments.string("name") {
            let p = tab.path.appending(name)
            guard tab.index(of: p) != nil else { throw CommandError.invalidArgument("name", L10n.tr("brak w katalogu")) }
            tab.cursor = p
        } else if let i = ctx.arguments.int("index") {
            tab.moveCursor(to: Int(i))
        }
        return .ok
    },
] }

@MainActor
var tabCommands: [Command] { [
    Command(CommandDescriptor(
        id: "tab.new", title: L10n.tr("Nowa karta"), category: .tabs, tc: ["ctrl+t"], cmd: ["cmd+t"],
        parameters: [CommandParameter("path", .path, L10n.tr("Katalog nowej karty (domyślnie bieżący)")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Otwiera nową kartę w panelu."))
    ) { ctx in
        let panel = ctx.arguments.string("side").flatMap(PanelSide.init(rawValue:)).map(ctx.workspace.panel) ?? ctx.workspace.activePanel
        let path = ctx.arguments.path("path", relativeTo: ctx.tab.path)
        if let cursor = ctx.tab.cursorItem, path == nil, cursor.isNavigable, !cursor.isParentLink, !ctx.isAgent {
            // Jak w TC: Ctrl+T na katalogu otwiera ten katalog w nowej karcie.
            let tab = panel.newTab(at: cursor.path)
            try await tab.navigate(to: cursor.path)
        } else {
            let tab = panel.newTab(at: path)
            try await tab.navigate(to: path ?? tab.path)
        }
        return CommandResult(value: .int(Int64(panel.activeTabIndex)))
    },

    Command(CommandDescriptor(
        id: "tab.close", title: L10n.tr("Zamknij kartę"), category: .tabs, tc: ["ctrl+w"], cmd: ["cmd+w"],
        parameters: [CommandParameter("index", .integer, L10n.tr("Numer karty (od 0); domyślnie aktywna")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Zamyka kartę (ostatnia karta panelu zostaje)."))
    ) { ctx in
        let panel = ctx.arguments.string("side").flatMap(PanelSide.init(rawValue:)).map(ctx.workspace.panel) ?? ctx.workspace.activePanel
        panel.closeTab(at: ctx.arguments.int("index").map(Int.init))
        return .ok
    },

    Command(CommandDescriptor(
        id: "tab.next", title: L10n.tr("Następna karta"), category: .tabs, tc: ["ctrl+tab"], cmd: ["ctrl+tab", "cmd+shift+]"],
        agent: .full, effect: .uiState, summary: L10n.tr("Przełącza na następną kartę."))
    ) { ctx in
        ctx.workspace.activePanel.nextTab()
        return .ok
    },

    Command(CommandDescriptor(
        id: "tab.previous", title: L10n.tr("Poprzednia karta"), category: .tabs, tc: ["ctrl+shift+tab"], cmd: ["ctrl+shift+tab", "cmd+shift+["],
        agent: .full, effect: .uiState, summary: L10n.tr("Przełącza na poprzednią kartę."))
    ) { ctx in
        ctx.workspace.activePanel.previousTab()
        return .ok
    },

    Command(CommandDescriptor(
        id: "tab.select", title: L10n.tr("Wybierz kartę"), category: .tabs,
        parameters: [CommandParameter("index", .integer, required: true, L10n.tr("Numer karty (od 0)")), sideParam],
        agent: .full, effect: .uiState, summary: L10n.tr("Przełącza na kartę o podanym numerze."), inMenu: false)
    ) { ctx in
        let panel = ctx.arguments.string("side").flatMap(PanelSide.init(rawValue:)).map(ctx.workspace.panel) ?? ctx.workspace.activePanel
        guard let i = ctx.arguments.int("index"), panel.tabs.indices.contains(Int(i)) else { throw CommandError.invalidArgument("index", L10n.tr("brak karty")) }
        panel.selectTab(Int(i))
        return .ok
    },
] }

/// Pakiety (np. `.app`) otwieramy jak pliki; do wnętrza wchodzi się przez „Przejdź do katalogu”.
func isPackage(_ item: FileItem) -> Bool {
    guard item.kind == .directory, let url = item.path.url else { return false }
    return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
}
