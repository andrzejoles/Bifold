import BifoldCore
import Foundation

extension Workspace {
    public func connectedDevices() async -> [DeviceInfo] {
        let dir = expandTilde(settings.toolsDirectory)
        return await (try? runBlocking(qos: .userInitiated) { DeviceDetector.iPhones(toolsDirectory: dir) + DeviceDetector.androids(toolsDirectory: dir) }) ?? []
    }

    /// Dostawca dla urządzenia (iPhone: media albo Documents aplikacji `appContainer`).
    public func deviceProvider(_ device: DeviceInfo, appContainer: String? = nil) throws -> any ExtractingProvider {
        let dir = expandTilde(settings.toolsDirectory)
        switch device.kind {
        case .iPhone:
            guard let afc = settings.toolPath("afcclient") else { throw CommandError.notAvailable(L10n.tr("iPhone wymaga libimobiledevice (brew install libimobiledevice)")) }
            return AFCDeviceFS(device: device, afcclient: afc, appContainer: appContainer)
        case .android:
            guard settings.toolPath("mtp-files") != nil else { throw CommandError.notAvailable(L10n.tr("Android wymaga libmtp (brew install libmtp)")) }
            return MTPDeviceFS(device: device, toolsDirectory: dir)
        }
    }
}

@MainActor
var deviceCommands: [Command] { [
    Command(CommandDescriptor(
        id: "device.list", title: L10n.tr("Podłączone urządzenia"), category: .network,
        agent: .read, effect: .none, summary: L10n.tr("Telefony z Androidem (MTP) i iPhone’y (AFC) podłączone kablem."), inMenu: false)
    ) { ctx in
        let devices = await ctx.workspace.connectedDevices()
        return CommandResult(value: .array(devices.map { ["id": .string($0.id), "kind": .string($0.kind.rawValue), "name": .string($0.name)] }))
    },

    Command(CommandDescriptor(
        id: "device.open", title: L10n.tr("Otwórz urządzenie (telefon)…"), category: .network, tc: ["ctrl+alt+p"],
        parameters: [CommandParameter("id", .string, L10n.tr("Identyfikator urządzenia (domyślnie pierwsze)")),
                     CommandParameter("app", .string, L10n.tr("iPhone: bundle id aplikacji z udostępnianiem plików (Documents)")), sideParam],
        agent: .read, effect: .uiState,
        summary: L10n.tr("Otwiera telefon w panelu (tylko odczyt). iPhone: tylko zdjęcia/nagrania (DCIM) i katalogi aplikacji z udostępnianiem plików."))
    ) { ctx in
        let devices = await ctx.workspace.connectedDevices()
        guard !devices.isEmpty else { throw CommandError.notAvailable(L10n.tr("Nie wykryto telefonu. Podłącz go kablem, odblokuj i zaakceptuj „Ufaj temu komputerowi” (iPhone) albo wybierz tryb „Przesyłanie plików” (Android).")) }
        let device = ctx.arguments.string("id").flatMap { id in devices.first { $0.id == id } } ?? devices[0]
        let provider = try ctx.workspace.deviceProvider(device, appContainer: ctx.arguments.string("app"))
        ctx.workspace.providers.register(provider)
        let tab = try ctx.tab(forSide: "side")
        try await tab.navigate(to: VFSPath(provider: provider.id, path: "/"))
        tab.customTitle = (device.kind == .iPhone ? "📱 " : "🤖 ") + device.name
        if device.kind == .iPhone, !ctx.isAgent { ctx.ui?.showMessage(AFCDeviceFS.limitation) }
        return CommandResult(message: device.kind == .iPhone ? AFCDeviceFS.limitation : device.name)
    },
] }
