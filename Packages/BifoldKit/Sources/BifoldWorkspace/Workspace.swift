import BifoldCore
import Foundation
import Observation

/// Bramka wywołań agenta (Etap 2): sprawdza uprawnienia, pokazuje okno zatwierdzania.
/// Rzuca błąd, jeśli wywołanie jest niedozwolone lub odrzucone.
@MainActor
public protocol AgentInvocationGate: AnyObject {
    func authorize(_ command: Command, context: CommandContext) async throws
}

/// Cały stan aplikacji: dwa panele z kartami, ustawienia, kolejka i dziennik operacji,
/// rejestr komend. Interfejs, paleta komend i API agenta korzystają z tego samego modelu.
@MainActor @Observable
public final class Workspace {
    public let paths: AppPaths
    public let providers: ProviderRegistry
    public let journal: OperationJournal
    public let jobs: JobQueue
    public let fileOps: FileOperations
    public let left: Panel
    public let right: Panel
    public var activeSide: PanelSide = .left
    /// Katalog domowy (tu wracają karty po rozłączeniu serwera).
    public let homePath: VFSPath
    /// Szybki podgląd (Ctrl+Q): drugi panel pokazuje podgląd elementu pod kursorem.
    public var quickViewActive = false
    public private(set) var keymap: Keymap
    public private(set) var statusMessage: String?
    public private(set) var volumes: [VolumeInfo] = []

    public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            if settings.showHiddenFiles != oldValue.showHiddenFiles {
                for tab in left.tabs + right.tabs { tab.showHidden = settings.showHiddenFiles }
            }
            if settings.shortcutProfile != oldValue.shortcutProfile || settings.keyOverrides != oldValue.keyOverrides {
                rebuildKeymap()
            }
            if persists { try? JSONStore.save(settings, to: paths.settings) }
        }
    }

    public var colorRules: ColorRuleSet {
        didSet { if persists, colorRules != oldValue { try? colorRules.encodedJSON().write(to: paths.colorRules, options: .atomic) } }
    }

    @ObservationIgnored public private(set) var registry = CommandRegistry()
    @ObservationIgnored public weak var ui: (any UIServices)?
    @ObservationIgnored public weak var agentGate: (any AgentInvocationGate)?
    /// Obserwatorzy wywołań komend (np. panel aktywności agenta).
    @ObservationIgnored public var invocationObservers: [@MainActor (CommandInvocationRecord) -> Void] = []
    @ObservationIgnored private let persists: Bool
    /// Serwery i chmury (Etap 5).
    @ObservationIgnored public private(set) var remotes: RemoteManager!
    /// Testy: katalog z pustą konfiguracją SSH i known_hosts (usuwany razem z obiektem).
    @ObservationIgnored private let testSSHDirectory: URL?

    /// - Parameter persists: `false` w testach — nic nie jest zapisywane na dysk.
    public init(paths: AppPaths, persists: Bool = true, home: VFSPath = .local(NSHomeDirectory())) {
        homePath = home
        self.paths = paths
        self.persists = persists
        // Osobny katalog tymczasowy — nie w katalogu danych (testy listują katalogi z nim w środku).
        testSSHDirectory = persists ? nil
            : FileManager.default.temporaryDirectory.appending(path: "bifold-tests-ssh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        if persists { paths.ensureExists() }
        let providers = ProviderRegistry([LocalFS()])
        self.providers = providers
        journal = OperationJournal(fileURL: persists ? paths.journal : nil)
        jobs = JobQueue(journal: journal)
        fileOps = FileOperations(journal: journal)

        let loaded = persists ? JSONStore.load(Settings.self, from: paths.settings) : nil
        let settings = loaded ?? Settings()
        self.settings = settings
        if persists, let data = try? Data(contentsOf: paths.colorRules), let rules = try? ColorRuleSet.decode(json: data) {
            colorRules = rules
        } else {
            colorRules = .defaults
        }

        let session = persists ? JSONStore.load(SessionSnapshot.self, from: paths.session) : nil
        func makePanel(_ side: PanelSide, _ state: SessionSnapshot.PanelState?) -> Panel {
            let tabs = (state?.tabs ?? []).map {
                Tab(path: $0.path, viewMode: $0.viewMode, sort: $0.sort, showHidden: settings.showHiddenFiles, providers: providers)
            }
            return Panel(
                side: side,
                tabs: tabs.isEmpty ? [Tab(path: home, showHidden: settings.showHiddenFiles, providers: providers)] : tabs,
                activeTabIndex: state?.activeTab ?? 0,
                showsTree: state?.showsTree ?? settings.showTreeByDefault,
                providers: providers)
        }
        let left = makePanel(.left, session?.left)
        let right = makePanel(.right, session?.right)
        self.left = left
        self.right = right
        activeSide = session?.activeSide ?? .left
        keymap = Keymap(commands: [], profile: settings.shortcutProfile)
        var cursors: [UUID: String] = [:]
        if let session {
            for (panel, state) in [(left, session.left), (right, session.right)] {
                for (tab, ts) in zip(panel.tabs, state.tabs) { if let c = ts.cursorName { cursors[tab.id] = c } }
            }
        }
        restoredCursors = cursors

        registry = CommandRegistry.standard()
        rebuildKeymap()
        remotes = RemoteManager(workspace: self, keychainService: (Bundle.main.bundleIdentifier ?? "local.aoles.bifold") + (persists ? ".remote" : ".tests"))
        // Próby na żywo (zwykle razem z BIFOLD_DATA_DIR): własna konfiguracja SSH i known_hosts zamiast ~/.ssh.
        let env = ProcessInfo.processInfo.environment
        if let config = env["BIFOLD_SSH_CONFIG"] { remotes.sshConfigFile = config }
        if let known = env["BIFOLD_SSH_KNOWN_HOSTS"] { remotes.sshKnownHostsFile = known }
        if let sshDir = testSSHDirectory {
            // Testy nie dotykają ~/.ssh (known_hosts i konfiguracja w katalogu testu).
            try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: sshDir.appending(path: "ssh_config").path, contents: Data())
            remotes.sshKnownHostsFile = sshDir.appending(path: "known_hosts").path
            remotes.sshConfigFile = sshDir.appending(path: "ssh_config").path
        }
        for panel in [left, right] { panel.onTabClosed = { [weak self] in self?.pruneProviders() } }
    }

    deinit {
        if let testSSHDirectory { try? FileManager.default.removeItem(at: testSSHDirectory) }
    }

    /// Poziom zasobu dla agenta (zasada najmniejszego poziomu, PROMPT.md 5.4–5.5):
    /// SFTP/WebDAV/SMB/chmury — odczyt, FTP/FTPS — za zgodą, woluminy sieciowe — odczyt,
    /// archiwa i wyniki wyszukiwania — odczyt, lokalne — pełny.
    public func resourceAccess(_ path: VFSPath) -> AgentAccess {
        if let alias = RemoteFS.alias(of: path) {
            guard let c = remotes.connection(alias) else { return .none }
            return c.kind.agentLevelIsApproval ? .approval : .read
        }
        if !path.isLocal { return .read }
        var st = statfs()
        var probe = path.path
        while statfs(probe, &st) != 0, probe != "/" { probe = (probe as NSString).deletingLastPathComponent }
        return st.f_flags & UInt32(MNT_LOCAL) == 0 ? .read : .full
    }

    /// Ścieżka z tekstu: `alias:/katalog` dla połączeń, `~`, ścieżki względne.
    public func parsePath(_ raw: String, relativeTo base: VFSPath) -> VFSPath {
        if let colon = raw.firstIndex(of: ":"), raw.first != "/" {
            let alias = String(raw[..<colon])
            if remotes.connection(alias) != nil {
                return VFSPath(provider: RemoteFS.providerID(alias), path: "/" + raw[raw.index(after: colon)...])
            }
        }
        return resolvePath(raw, relativeTo: base.isLocal ? base : nil)
    }

    @ObservationIgnored private var restoredCursors: [UUID: String]

    /// Wczytuje katalogi wszystkich kart (po starcie). Karty z nieistniejącą ścieżką trafiają
    /// do najbliższego istniejącego katalogu nadrzędnego.
    public func start() async {
        for tab in left.tabs + right.tabs {
            // Karty wyników wyszukiwania nie przetrwają restartu — wracają do katalogu domowego.
            var target: VFSPath? = (try? providers.provider(for: tab.path)) == nil && RemoteFS.alias(of: tab.path) == nil ? homePath : tab.path
            if let alias = RemoteFS.alias(of: tab.path) {
                // Karty zdalne łączą się ponownie; bez połączenia — katalog domowy.
                if (try? await remotes.provider(alias)) == nil { target = homePath }
            }
            var focus = restoredCursors[tab.id]
            while let t = target {
                if (try? await tab.navigate(to: t, focus: focus)) != nil { break }
                focus = nil
                target = t.parent
            }
        }
        refreshVolumes()
    }

    /// Wyniki wyszukiwania w nowej karcie aktywnego (lub wskazanego) panelu.
    @discardableResult
    public func showResults(title: String, items: [FileItem], side: PanelSide? = nil) async throws -> Tab {
        let provider = SearchResultsFS(title: title, items: items)
        registerEphemeral(provider)
        defer { unpinEphemeral(provider.id) }
        let panel = self.panel(side ?? activeSide)
        let tab = panel.newTab(at: provider.root)
        tab.customTitle = "🔍 " + title
        do {
            try await tab.navigate(to: provider.root)
        } catch {
            if let i = panel.tabs.firstIndex(where: { $0 === tab }) { panel.closeTab(at: i) }
            throw error
        }
        return tab
    }

    // MARK: Dostawcy tymczasowi (archiwa, wyniki wyszukiwania)

    /// Zarejestrowani dostawcy archiwów i wyników z licznikiem trwających otwarć (w trakcie wejścia
    /// do archiwum karta jeszcze go nie używa, a nie wolno go wtedy wyrejestrować).
    @ObservationIgnored private var ephemeralProviders: [ProviderID: Int] = [:]

    /// Rejestruje dostawcę archiwum lub wyników; po otwarciu trzeba wywołać `unpinEphemeral`.
    func registerEphemeral(_ provider: any FileSystemProvider) {
        providers.register(provider)
        ephemeralProviders[provider.id, default: 0] += 1
    }

    func unpinEphemeral(_ id: ProviderID) {
        if let n = ephemeralProviders[id] { ephemeralProviders[id] = max(0, n - 1) }
        pruneProviders()
    }

    /// Wyrejestrowuje archiwa i wyniki wyszukiwania, których nie używa żadna karta (katalog ani historia).
    func pruneProviders() {
        let used = (left.tabs + right.tabs).reduce(into: Set<ProviderID>()) { $0.formUnion($1.usedProviders) }
        for (id, pins) in ephemeralProviders where pins == 0 && !used.contains(id) {
            providers.unregister(id)
            ephemeralProviders[id] = nil
        }
    }

    /// Otwiera katalog w panelu. Karta jest związana ze swoją maszyną (dysk lokalny, serwer, telefon):
    /// aktywna karta przechodzi do `target` tylko na tej samej maszynie; inny serwer, telefon albo
    /// karta-terminal — nowa karta obok (zamykana, jeśli katalogu nie da się wczytać).
    @discardableResult
    public func open(_ target: VFSPath, in panel: Panel, focus: String? = nil) async throws -> Tab {
        try await open(target, in: panel) { try await $0.navigate(to: target, focus: focus) }
    }

    @discardableResult
    public func open(_ target: VFSPath, in panel: Panel, load: (Tab) async throws -> Void) async throws -> Tab {
        let current = panel.activeTab
        let tab: Tab
        if current.terminal == nil, current.path.machine == target.machine {
            tab = current
            try await load(tab)
        } else {
            tab = panel.newTab(at: target)
            do {
                try await load(tab)
            } catch {
                if let i = panel.tabs.firstIndex(where: { $0 === tab }) { panel.closeTab(at: i) }
                panel.selectTab(id: current.id)
                throw error
            }
        }
        if let alias = RemoteFS.alias(of: target), tab.customTitle == nil { tab.customTitle = "🌐 " + alias }
        return tab
    }

    /// Zamyka karty danej maszyny (rozłączony serwer, zamknięty telefon); ostatnia karta panelu
    /// wraca do katalogu domowego.
    public func closeTabs(where predicate: (Tab) -> Bool) async {
        for panel in [left, right] {
            for tab in panel.tabs where predicate(tab) {
                if let i = panel.tabs.firstIndex(where: { $0 === tab }), panel.closeTab(at: i) { continue }
                tab.terminal = nil
                tab.customTitle = nil
                try? await tab.navigate(to: homePath)
            }
        }
    }

    public func panel(_ side: PanelSide) -> Panel { side == .left ? left : right }
    public var activePanel: Panel { panel(activeSide) }
    public var otherPanel: Panel { panel(activeSide.other) }
    public var activeTab: Tab { activePanel.activeTab }
    public var otherTab: Tab { otherPanel.activeTab }

    public func switchPanel() { activeSide = activeSide.other }

    public func setStatus(_ message: String?) { statusMessage = message }

    public func refreshVolumes() { volumes = Volumes.mounted() }

    public func saveSession() {
        guard persists else { return }
        let snapshot = SessionSnapshot(left: left.snapshot(home: homePath), right: right.snapshot(home: homePath), activeSide: activeSide)
        try? JSONStore.save(snapshot, to: paths.session)
        journal.flush()
    }

    func rebuildKeymap() {
        keymap = Keymap(commands: registry.descriptors, profile: settings.shortcutProfile, overrides: settings.keyOverrides)
    }

    /// Rejestruje dodatkowe komendy (np. komendy agenta z Etapu 2).
    public func register(_ commands: [Command]) {
        for c in commands { registry.register(c) }
        rebuildKeymap()
    }

    // MARK: Wywoływanie komend

    /// Jedyny punkt wywołania komendy — klawiatura, menu, paleta, linia poleceń i agent.
    @discardableResult
    public func invoke(_ id: CommandID, _ arguments: CommandArguments = .empty, invoker: Invoker = .user) async throws -> CommandResult {
        guard let command = registry.command(id) else { throw CommandError.unknownCommand(id) }
        let context = CommandContext(workspace: self, invoker: invoker, arguments: arguments)
        let started = Date()
        do {
            if invoker.isAgent {
                guard let agentGate else { throw CommandError.notAvailable(L10n.tr("API agenta jest wyłączone")) }
                try await agentGate.authorize(command, context: context)
            }
            let result = try await command.run(context)
            pruneProviders()
            notify(CommandInvocationRecord(command: id, arguments: arguments, invoker: invoker, started: started, outcome: .success(result.message)))
            return result
        } catch {
            pruneProviders()
            notify(CommandInvocationRecord(command: id, arguments: arguments, invoker: invoker, started: started, outcome: .failure(error.localizedDescription)))
            throw error
        }
    }

    /// Skutki komendy „na sucho” (okno zatwierdzania, potwierdzenia).
    public func preview(_ id: CommandID, _ arguments: CommandArguments = .empty, invoker: Invoker = .user) async throws -> EffectPreview {
        guard let command = registry.command(id) else { throw CommandError.unknownCommand(id) }
        let context = CommandContext(workspace: self, invoker: invoker, arguments: arguments)
        if let preview = command.preview { return try await preview(context) }
        return EffectPreview(summary: command.descriptor.summary)
    }

    /// Wywołanie z interfejsu: błędy pokazywane użytkownikowi zamiast rzucane.
    public func perform(_ id: CommandID, _ arguments: CommandArguments = .empty) {
        Task {
            do {
                try await invoke(id, arguments)
            } catch CommandError.cancelledByUser {
            } catch VFSError.cancelled {
            } catch {
                ui?.showError(error.localizedDescription)
            }
        }
    }

    private func notify(_ record: CommandInvocationRecord) {
        for o in invocationObservers { o(record) }
    }
}

public struct CommandInvocationRecord: Sendable {
    public enum Outcome: Sendable { case success(String?), failure(String) }
    public var command: CommandID
    public var arguments: CommandArguments
    public var invoker: Invoker
    public var started: Date
    public var outcome: Outcome
}

/// Rejestr wszystkich komend aplikacji (kolejność = kolejność w menu i palecie).
public struct CommandRegistry: Sendable {
    public private(set) var commands: [Command] = []
    private var index: [CommandID: Int] = [:]

    public init(_ commands: [Command] = []) {
        for c in commands { register(c) }
    }

    public mutating func register(_ command: Command) {
        if let i = index[command.id] {
            commands[i] = command
        } else {
            index[command.id] = commands.count
            commands.append(command)
        }
    }

    public func command(_ id: CommandID) -> Command? { index[id].map { commands[$0] } }
    public var descriptors: [CommandDescriptor] { commands.map(\.descriptor) }
}
