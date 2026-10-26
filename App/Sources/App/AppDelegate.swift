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
    private var appliedTheme: AppTheme?
    private var menuBindings: [KeyChord: CommandID]?
    private var menuCommandCount = 0

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
        menuBuilder.mainWindow = mainWindow.window

        // Obserwacja reaguje na każdą zmianę ustawień — motyw i menu tylko, gdy zmieniło się to, od czego zależą.
        observations.add { [weak self] in
            guard let self else { return }
            let theme = self.workspace.settings.theme
            if theme != self.appliedTheme {
                self.appliedTheme = theme
                Theme.apply(theme)
            }
            let bindings = self.workspace.keymap.bindings
            let count = self.workspace.registry.commands.count
            if bindings != self.menuBindings || count != self.menuCommandCount {
                self.menuBindings = bindings
                self.menuCommandCount = count
                NSApp.mainMenu = self.menuBuilder.build()
            }
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
            guard alert.runModal() == .alertFirstButtonReturn else {
                LanguageService.shared.relaunchRequested = false
                return .terminateCancel
            }
            workspace.jobs.cancelAll()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        agents?.controller.stop()
        workspace.remotes.stop()
        workspace.saveSession()
        LanguageService.shared?.launchRelaunchHelperIfRequested()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Nazwa aplikacji z Info.plist (ustawiana w Config/Brand.xcconfig).
enum Brand {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "BifoldAppName") as? String ?? "Bifold"
    }
}
