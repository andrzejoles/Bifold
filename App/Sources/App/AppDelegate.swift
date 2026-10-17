import AppKit
import BifoldCore
import BifoldWorkspace

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var workspace: Workspace!
    private var mainWindow: MainWindowController!
    private var services: AppUIServices!
    private var menuBuilder: MenuBuilder!
    private var agents: AgentUIController!
    private var adminHelper: AdminHelperClient!
    private let updates = UpdateService()
    private let observations = ObservationBag()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AppPaths.standard(appName: Brand.appName)
        // Język przed zbudowaniem komend i menu (tytuły powstają przy starcie).
        LanguageService.shared = LanguageService(paths: paths)
        workspace = Workspace(paths: paths)
        services = AppUIServices(workspace: workspace)
        workspace.ui = services
        Theme.apply(workspace.settings.theme)

        mainWindow = MainWindowController(workspace: workspace, services: services)
        services.mainWindow = mainWindow
        adminHelper = AdminHelperClient(workspace: workspace)
        updates.register(in: workspace)
        LanguageService.shared.register(in: workspace)
        updates.start()
        agents = AgentUIController(workspace: workspace)
        agents.mainWindow = mainWindow
        mainWindow.agentPane = agents.pane
        menuBuilder = MenuBuilder(workspace: workspace)
        NSApp.mainMenu = menuBuilder.build()

        observations.add { [weak self] in
            guard let self else { return }
            _ = self.workspace.keymap
            Theme.apply(self.workspace.settings.theme)
            NSApp.mainMenu = self.menuBuilder.build()
        }

        mainWindow.showWindow(nil)
        NSApp.activate()
        Task {
            await workspace.start()
            mainWindow.focusActivePanel()
            if !FullDiskAccess.isGranted {
                FullDiskAccess.showInstructions(for: mainWindow.window)
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.workspace.refreshVolumes() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = workspace.jobs.activeJobs
        if !active.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Trwają operacje na plikach")
            alert.informativeText = L10n.tr("Zakończenie przerwie \(active.count) zadań. Częściowo skopiowane pliki zostaną usunięte.")
            alert.addButton(withTitle: L10n.tr("Przerwij i zakończ"))
            alert.addButton(withTitle: L10n.tr("Anuluj"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            workspace.jobs.cancelAll()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        agents?.controller.stop()
        workspace.remotes.stop()
        workspace.saveSession()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Nazwa aplikacji z Info.plist (ustawiana w Config/Brand.xcconfig).
enum Brand {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "BifoldAppName") as? String ?? "Bifold"
    }
}
