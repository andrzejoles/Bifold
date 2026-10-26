import AppKit
import BifoldCore
import BifoldWorkspace

/// Wybór dysku karty jak w Total Commanderze: woluminy (dysk wewnętrzny, USB, udziały sieciowe),
/// telefon i zapisane połączenia. Pozycje wywołują komendy z rejestru (`panel.navigate`,
/// `device.open`, `remote.open`), więc karta-terminal, inny serwer albo telefon dostają nową kartę.
@MainActor
enum DriveMenu {
    /// Nazwa i ikona dysku karty (przycisk przed ścieżką).
    static func label(for tab: Tab, workspace: Workspace) -> (title: String, image: NSImage?) {
        if let spec = tab.terminal { return (spec.alias, symbol("terminal")) }
        if let alias = RemoteFS.alias(of: tab.path) {
            let cloud = workspace.remotes.connection(alias)?.kind.usesOAuth ?? false
            return (alias, symbol(cloud ? "cloud" : "server.rack"))
        }
        if tab.path.isDevice {
            let name = tab.customTitle.map { String($0.drop { !$0.isLetter && !$0.isNumber }) }
            return (name ?? L10n.tr("Telefon"), symbol("iphone"))
        }
        if tab.isSearchResults { return (L10n.tr("Wyniki wyszukiwania"), symbol("magnifyingglass")) }
        if let v = volume(of: tab, workspace: workspace) { return (v.name, icon(v)) }
        return ("/", symbol("internaldrive"))
    }

    /// Wolumin lokalny karty (dla archiwum — wolumin pliku archiwum).
    static func volume(of tab: Tab, workspace: Workspace) -> VolumeInfo? {
        guard tab.terminal == nil else { return nil }
        let path = tab.hostLocation ?? tab.path
        return workspace.volumes.filter { path.isDescendant(of: $0.path) }.max { $0.path.components.count < $1.path.components.count }
    }

    static func menu(for side: PanelSide, workspace: Workspace) -> NSMenu {
        workspace.refreshVolumes()
        let tab = workspace.panel(side).activeTab
        let side = JSONValue.string(side.rawValue)
        let currentVolume = volume(of: tab, workspace: workspace)?.path
        let menu = NSMenu()
        menu.autoenablesItems = false

        for v in workspace.volumes {
            let free = v.totalCapacity > 0 ? "   " + L10n.tr("\(Format.bytes(v.availableCapacity)) wolne") : ""
            let item = add(menu, v.name + free, icon(v), "panel.navigate", ["path": .string(v.path.path), "side": side])
            item.state = v.path == currentVolume ? .on : .off
        }
        add(menu, L10n.tr("Katalog domowy"), symbol("house"), "panel.navigate", ["path": .string(NSHomeDirectory()), "side": side])
        menu.addItem(.separator())
        add(menu, L10n.tr("Telefon (USB)…"), symbol("iphone"), "device.open", ["side": side])

        let remotes = workspace.remotes!
        if !remotes.connections.isEmpty {
            menu.addItem(.sectionHeader(title: L10n.tr("Połączenia")))
            for c in remotes.connections {
                let item = add(menu, c.alias, symbol(c.kind.usesOAuth ? "cloud" : "server.rack"), "remote.open", ["alias": .string(c.alias), "side": side])
                item.subtitle = c.kind.displayName + (remotes.connected.contains(c.alias) ? L10n.tr(" · połączono") : "")
                item.state = RemoteFS.alias(of: tab.path) == c.alias && tab.terminal == nil ? .on : .off
            }
        }
        add(menu, L10n.tr("Menedżer połączeń…"), symbol("network"), "remote.connections", [:])

        let ejectable = workspace.volumes.filter { $0.isEjectable || $0.isRemovable || $0.isNetwork }
        if !ejectable.isEmpty {
            menu.addItem(.separator())
            let sub = NSMenu()
            for v in ejectable { add(sub, v.name, icon(v), "volume.eject", ["path": .string(v.path.path)]) }
            let eject = NSMenuItem(title: L10n.tr("Wysuń"), action: nil, keyEquivalent: "")
            eject.image = symbol("eject")
            eject.submenu = sub
            menu.addItem(eject)
        }
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ image: NSImage?, _ command: CommandID, _ arguments: [String: JSONValue]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(DriveMenuTarget.run(_:)), keyEquivalent: "")
        item.image = image
        item.target = DriveMenuTarget.shared
        item.representedObject = DriveMenuTarget.Action(command: command, arguments: CommandArguments(arguments))
        menu.addItem(item)
        return item
    }

    private static func icon(_ v: VolumeInfo) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: v.path.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

final class DriveMenuTarget: NSObject {
    final class Action {
        let command: CommandID
        let arguments: CommandArguments
        init(command: CommandID, arguments: CommandArguments) {
            self.command = command
            self.arguments = arguments
        }
    }

    static let shared = DriveMenuTarget()
    weak var workspace: Workspace?

    @objc func run(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? Action else { return }
        workspace?.perform(action.command, action.arguments)
    }
}
