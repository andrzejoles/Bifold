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
        await closeTabs { $0.path.provider == provider }
    }

    /// Dostawca dla urządzenia (iPhone: media albo Documents aplikacji `appContainer`).
    public func deviceProvider(_ device: DeviceInfo, appContainer: String? = nil) async throws -> any ExtractingProvider {
        switch device.kind {
        case .iPhone:
            guard let afc = settings.toolPath("afcclient") else { throw CommandError.notAvailable(L10n.tr("iPhone wymaga libimobiledevice (brew install libimobiledevice)")) }
            return AFCDeviceFS(device: device, afcclient: afc, appContainer: appContainer)
        case .android:
            // Telefon obsługuje jedną sesję MTP naraz — otwarta sesja jest używana ponownie, ale tylko
            // dla tego samego telefonu (identyfikator USB; numer z listy zmienia się z kolejnością).
            if let open = try? providers.provider(for: MTPDeviceFS.providerID(for: device)) as? MTPDeviceFS,
               open.device.usb == device.usb, device.usb != nil || open.device.id == device.id {
                return open
            }
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
        // Nazwy podaje urządzenie (albo udające telefon urządzenie USB) — dla agenta to niezaufane dane.
        let value: JSONValue = .array(devices.map { ["id": .string($0.id), "kind": .string($0.kind.rawValue), "name": .string($0.name)] })
        return CommandResult(value: ctx.isAgent ? untrusted(value) : value)
    },

    Command(CommandDescriptor(
        id: "device.open", title: L10n.tr("Otwórz urządzenie (telefon)…"), category: .network, tc: ["ctrl+alt+p"],
        parameters: [CommandParameter("id", .string, L10n.tr("Identyfikator urządzenia (domyślnie pierwsze)")),
                     CommandParameter("app", .string, L10n.tr("iPhone: bundle id aplikacji z udostępnianiem plików (Documents)")), sideParam],
        agent: .read, effect: .uiState,
        summary: L10n.tr("Otwiera telefon w nowej karcie panelu (tylko odczyt). iPhone: tylko zdjęcia/nagrania (DCIM) i katalogi aplikacji z udostępnianiem plików."))
    ) { ctx in
        let devices = await ctx.workspace.connectedDevices()
        guard !devices.isEmpty else {
            var message = L10n.tr("Nie wykryto telefonu. Podłącz go kablem, odblokuj i zaakceptuj „Ufaj temu komputerowi” (iPhone) albo wybierz tryb „Przesyłanie plików” (Android).")
            let helper = DeviceDetector.mtpHelperPath
            if await (try? runBlocking(qos: .userInitiated) { DeviceDetector.mtpHelperWorks(helper) }) != true {
                message += " " + L10n.tr("Android wymaga libmtp (brew install libmtp)")
            }
            throw CommandError.notAvailable(message)
        }
        let device = ctx.arguments.string("id").flatMap { id in devices.first { $0.id == id } } ?? devices[0]
        let provider = try await ctx.workspace.deviceProvider(device, appContainer: ctx.arguments.string("app"))
        ctx.workspace.providers.register(provider)
        let target = VFSPath(provider: provider.id, path: "/")
        // Telefon w nowej karcie (chyba że aktywna karta już go pokazuje).
        _ = try await ctx.workspace.open(target, in: try ctx.panel(forSide: "side")) { tab in
            do {
                try await tab.navigate(to: target)
            } catch let error as MTPDeviceFS.MTPError {
                // Bez „Zezwól” na telefonie: karta na telefonie z komunikatem — Ctrl+R po zgodzie ponawia próbę.
                await tab.showUnavailable(target, error: error.localizedDescription)
                if !ctx.isAgent { ctx.ui?.showMessage(error.localizedDescription) }
            }
        }
        // Tytuł karty („📱/🤖 nazwa”) wylicza `setPath` z dostawcy.
        let name = (provider as? MTPDeviceFS)?.model ?? device.name
        if device.kind == .iPhone, !ctx.isAgent { ctx.ui?.showMessage(AFCDeviceFS.limitation) }
        // Model i nazwa pochodzą z telefonu — agent dostaje je jako niezaufane dane, nie w komunikacie.
        if ctx.isAgent {
            var value: [String: JSONValue] = ["id": .string(device.id), "kind": .string(device.kind.rawValue), "name": .string(name)]
            if device.kind == .iPhone { value["limitation"] = .string(AFCDeviceFS.limitation) }
            return CommandResult(value: untrusted(.object(value)))
        }
        return CommandResult(message: device.kind == .iPhone ? AFCDeviceFS.limitation : device.name)
    },
] }
