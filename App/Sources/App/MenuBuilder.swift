import AppKit
import BifoldCore
import BifoldWorkspace

/// Menu główne budowane z rejestru komend (te same komendy co klawiatura, paleta i API agenta).
final class MenuBuilder: NSObject {
    private let workspace: Workspace

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

        // Menu Edycja dla pól tekstowych (kopiuj/wklej w linii poleceń, filtrze, oknach).
        let edit = NSMenu(title: L10n.tr("Edycja"))
        edit.addItem(withTitle: L10n.tr("Wytnij"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.tr("Kopiuj"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.tr("Wklej"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.tr("Zaznacz wszystko w polu"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
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

    @objc private func run(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        workspace.perform(CommandID(rawValue: raw))
    }
}
