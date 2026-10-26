import AppKit
import BifoldCore
import BifoldWorkspace
import QuickLookUI
import SwiftTerm

/// Menu główne budowane z rejestru komend (te same komendy co klawiatura, paleta i API agenta).
///
/// Komendy panelu działają tylko wtedy, gdy kluczowe jest okno główne. Gdy pisze się w polu tekstowym
/// albo terminalu, skróty komend kolidujące z edycją są wyłączone (klawisz trafia do pola), a skróty
/// standardowe (⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, w innych oknach także ⌘W i ⌘F) wykonują zwykłą czynność AppKitu
/// zamiast komendy — ⌘Z w polu cofa pisanie, nie operację na plikach.
final class MenuBuilder: NSObject, NSMenuItemValidation {
    private let workspace: Workspace
    /// Okno główne (panele) — tylko w nim działają komendy panelu.
    weak var mainWindow: NSWindow?

    /// Skróty standardowe i ich czynności AppKitu.
    private struct Standard {
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let action: Selector
        /// Czynność okna (nie pola tekstowego) — przekazywana tylko w oknach innych niż główne.
        let windowAction: Bool
        var tag = 0
    }

    private static let standards: [Standard] = [
        Standard(key: "z", modifiers: .command, action: Selector(("undo:")), windowAction: false),
        Standard(key: "z", modifiers: [.command, .shift], action: Selector(("redo:")), windowAction: false),
        Standard(key: "x", modifiers: .command, action: #selector(NSText.cut(_:)), windowAction: false),
        Standard(key: "c", modifiers: .command, action: #selector(NSText.copy(_:)), windowAction: false),
        Standard(key: "v", modifiers: .command, action: #selector(NSText.paste(_:)), windowAction: false),
        Standard(key: "a", modifiers: .command, action: #selector(NSText.selectAll(_:)), windowAction: false),
        Standard(key: "w", modifiers: .command, action: #selector(NSWindow.performClose(_:)), windowAction: true),
        Standard(key: "f", modifiers: .command, action: #selector(NSTextView.performFindPanelAction(_:)), windowAction: true,
                 tag: NSTextFinder.Action.showFindInterface.rawValue),
    ]

    /// Kategorie komend działających na panelach (wyłączone poza oknem głównym).
    private static let panelCategories: Set<CommandCategory> = [.panel, .tabs, .view, .selection, .file, .clipboard, .edit]

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item(for: "app.about"))
        appMenu.addItem(item(for: "app.checkForUpdates"))
        appMenu.addItem(.separator())
        appMenu.addItem(item(for: "tools.settings"))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: L10n.tr("Usługi"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("Ukryj \(Brand.appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.tr("Ukryj pozostałe"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("Zakończ \(Brand.appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(Brand.appName, appMenu))

        // Menu Edycja dla pól tekstowych (cofnij, kopiuj, wklej, znajdź w linii poleceń, filtrze, oknach).
        // Skrót standardowy tylko wtedy, gdy nie ma go komenda (wtedy przekazuje go `run`).
        let edit = NSMenu(title: L10n.tr("Edycja"))
        edit.addItem(standardItem(L10n.tr("Cofnij"), Self.standards[0]))
        edit.addItem(standardItem(L10n.tr("Ponów"), Self.standards[1]))
        edit.addItem(.separator())
        edit.addItem(standardItem(L10n.tr("Wytnij"), Self.standards[2]))
        edit.addItem(standardItem(L10n.tr("Kopiuj"), Self.standards[3]))
        edit.addItem(standardItem(L10n.tr("Wklej"), Self.standards[4]))
        edit.addItem(standardItem(L10n.tr("Zaznacz wszystko w polu"), Self.standards[5]))
        edit.addItem(standardItem(L10n.tr("Znajdź…"), Self.standards[7]))
        edit.addItem(.separator())
        for c in workspace.registry.commands where c.descriptor.category == .edit && c.descriptor.inMenu {
            edit.addItem(item(for: c.id))
        }

        let categories: [(CommandCategory, String)] = [
            (.file, L10n.tr("Plik")), (.panel, L10n.tr("Panel")), (.tabs, L10n.tr("Karty")), (.view, L10n.tr("Widok")),
            (.selection, L10n.tr("Zaznaczanie")), (.clipboard, L10n.tr("Schowek")), (.queue, L10n.tr("Kolejka")), (.tools, L10n.tr("Narzędzia")), (.network, L10n.tr("Sieć")), (.agent, L10n.tr("Agent")),
        ]
        for (category, title) in categories {
            let menu = NSMenu(title: title)
            for c in workspace.registry.commands where c.descriptor.category == category && c.descriptor.inMenu && c.id != "tools.settings" {
                menu.addItem(item(for: c.id))
            }
            main.addItem(submenu(title, menu))
            if category == .file { main.addItem(submenu(edit.title, edit)) }
        }

        let window = NSMenu(title: L10n.tr("Okno"))
        // Zamyka okna pomocnicze (podgląd, ustawienia, szukaj); okna głównego nie — zamknięcie go kończy
        // aplikację, a ⌘W w profilu TC nie jest „Zamknij kartę”.
        let close = standardItem(L10n.tr("Zamknij okno"), Self.standards[6])
        close.action = #selector(closeWindow(_:))
        close.target = self
        window.addItem(close)
        window.addItem(withTitle: L10n.tr("Minimalizuj"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L10n.tr("Powiększ"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: L10n.tr("Pełny ekran"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        main.addItem(submenu(window.title, window))
        return main
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func item(for id: CommandID) -> NSMenuItem {
        guard let command = workspace.registry.command(id) else { return NSMenuItem() }
        let item = NSMenuItem(title: command.descriptor.title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id.rawValue
        item.toolTip = command.descriptor.summary
        if let chord = workspace.keymap.chords(for: id).first(where: { $0.menuKeyEquivalent != nil }), let (key, mods) = chord.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        return item
    }

    /// Pozycja czynności standardowej (adresat: pierwszy obiekt w łańcuchu odpowiedzi).
    private func standardItem(_ title: String, _ standard: Standard) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: standard.action, keyEquivalent: "")
        item.tag = standard.tag
        let chord = KeyChord(key: standard.key, modifiers: Self.modifiers(standard.modifiers))
        if workspace.keymap.command(for: chord) == nil {
            item.keyEquivalent = standard.key
            item.keyEquivalentModifierMask = standard.modifiers
        }
        return item
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var mods: KeyModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        return mods
    }

    @objc private func run(_ sender: NSMenuItem) {
        if let standard = forwardedStandard(for: sender) {
            let proxy = NSMenuItem()
            proxy.tag = standard.tag
            NSApp.sendAction(standard.action, to: nil, from: proxy)
            return
        }
        guard let raw = sender.representedObject as? String else { return }
        workspace.perform(CommandID(rawValue: raw))
    }

    @objc private func closeWindow(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    // MARK: Dostępność pozycji

    private var keyWindow: NSWindow? { NSApp.keyWindow }

    /// Fokus w polu tekstowym albo terminalu (klawisze należą do tekstu, nie do listy plików).
    private var editingText: Bool {
        let responder = keyWindow?.firstResponder
        return responder is NSText || responder is TerminalView
    }

    /// Okno główne kluczowe (Quick Look nad nim się liczy — ⌘Y ma go zamknąć).
    private var mainIsKey: Bool { keyWindow != nil && (keyWindow === mainWindow || keyWindow is QLPreviewPanel) }

    /// Skrót standardowy, który w obecnym kontekście ma wykonać czynność AppKitu zamiast komendy
    /// (tylko przy naciśnięciu klawiszy — kliknięta pozycja menu wykonuje komendę).
    private func forwardedStandard(for item: NSMenuItem) -> Standard? {
        guard NSApp.currentEvent?.type == .keyDown, !item.keyEquivalent.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
        guard let standard = Self.standards.first(where: { $0.key == item.keyEquivalent && $0.modifiers == mask }) else { return nil }
        if standard.windowAction { return mainIsKey ? nil : standard }
        return editingText || !mainIsKey ? standard : nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeWindow(_:)) {
            return keyWindow != nil && !mainIsKey
        }
        guard item.action == #selector(run(_:)), let raw = item.representedObject as? String,
              let command = workspace.registry.command(CommandID(rawValue: raw)) else { return true }
        if let standard = forwardedStandard(for: item) {
            return NSApp.target(forAction: standard.action, to: nil, from: item) != nil
        }
        guard Self.panelCategories.contains(command.descriptor.category) else { return true }
        // Komendy panelu nie działają w innych oknach (podgląd, ustawienia, arkusze dialogów).
        guard mainIsKey else { return false }
        guard editingText, !item.keyEquivalent.isEmpty else { return true }
        // W polu tekstowym: skróty z Ctrl (edycja w stylu Emacsa: ⌃H, ⌃T, ⌃W…) i Cmd+strzałki/⌫ należą
        // do pola; F-klawisze i pozostałe skróty z Cmd działają dalej.
        let mask = item.keyEquivalentModifierMask
        let scalar = item.keyEquivalent.unicodeScalars.first.map { Int($0.value) } ?? 0
        let isFunctionKey = (NSF1FunctionKey...NSF35FunctionKey).contains(scalar)
        if isFunctionKey { return true }
        let textKeys: Set<Int> = [NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSLeftArrowFunctionKey, NSRightArrowFunctionKey,
                                  NSHomeFunctionKey, NSEndFunctionKey, NSPageUpFunctionKey, NSPageDownFunctionKey,
                                  NSDeleteFunctionKey, 8, 127, 9, 13, 32]
        if mask.contains(.control) && !mask.contains(.command) { return false }
        if textKeys.contains(scalar) { return false }
        return true
    }
}
