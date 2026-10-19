import BifoldCore
import Foundation

extension Workspace {
    public func connectedDevices() async -> [DeviceInfo] {
        let dir = expandTilde(settings.toolsDirectory)
        let helper = DeviceDetector.mtpHelperPath
        return await (try? runBlocking(qos: .userInitiated) { DeviceDetector.iPhones(toolsDirectory: dir) + DeviceDetector.androids(helper: helper) }) ?? []
    }

    /// Zamyka telefon: sesję MTP (telefon wolny dla innych programów), dostawcę i karty z nim.
    public func closeDevice(_ provider: ProviderID) async {
        if let mtp = try? providers.provider(for: provider) as? MTPDeviceFS {
            _ = try? await runBlocking(qos: .userInitiated) { mtp.close() }
        }
        providers.unregister(provider)
        for tab in left.tabs + right.tabs where tab.path.provider == provider {
            try? await tab.navigate(to: homePath)
            tab.customTitle = nil
        }
    }

    /// Dostawca dla urządzenia (iPhone: media albo Documents aplikacji `appContainer`).
    public func deviceProvider(_ device: DeviceInfo, appContainer: String? = nil) async throws -> any ExtractingProvider {
        switch device.kind {
        case .iPhone:
            guard let afc = settings.toolPath("afcclient") else { throw CommandError.notAvailable(L10n.tr("iPhone wymaga libimobiledevice (brew install libimobiledevice)")) }
            return AFCDeviceFS(device: device, afcclient: afc, appContainer: appContainer)
        case .android:
            // Telefon obsługuje jedną sesję MTP naraz — otwarta sesja jest używana ponownie.
            if let open = try? providers.provider(for: ProviderID("device:mtp-\(device.id)")) as? MTPDeviceFS { return open }
            guard let helper = DeviceDetector.mtpHelperPath else {
                throw CommandError.notAvailable(L10n.tr("Android wymaga libmtp (brew install libmtp)"))
            }
            return try await runBlocking(qos: .userInitiated) { try MTPDeviceFS(device: device, helperPath: helper) }
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
        let provider = try await ctx.workspace.deviceProvider(device, appContainer: ctx.arguments.string("app"))
        ctx.workspace.providers.register(provider)
        let tab = try ctx.tab(forSide: "side")
        let target = VFSPath(provider: provider.id, path: "/")
        do {
            try await tab.navigate(to: target)
        } catch let error as MTPDeviceFS.MTPError {
            // Bez „Zezwól” na telefonie: karta na telefonie z komunikatem — Ctrl+R po zgodzie ponawia próbę.
            await tab.showUnavailable(target, error: error.localizedDescription)
            if !ctx.isAgent { ctx.ui?.showMessage(error.localizedDescription) }
        }
        tab.customTitle = (device.kind == .iPhone ? "📱 " : "🤖 ") + ((provider as? MTPDeviceFS)?.model ?? device.name)
        if device.kind == .iPhone, !ctx.isAgent { ctx.ui?.showMessage(AFCDeviceFS.limitation) }
        return CommandResult(message: device.kind == .iPhone ? AFCDeviceFS.limitation : device.name)
    },
] }
