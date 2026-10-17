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

    /// - Parameter persists: `false` w testach — nic nie jest zapisywane na dysk.
    public init(paths: AppPaths, persists: Bool = true, home: VFSPath = .local(NSHomeDirectory())) {
        self.paths = paths
        self.persists = persists
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
        if !persists {
            // Testy nie dotykają ~/.ssh (known_hosts i konfiguracja w katalogu testu).
            remotes.sshKnownHostsFile = paths.root.appending(path: "known_hosts").path
            let config = paths.root.appending(path: "ssh_config")
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: config.path, contents: Data())
            remotes.sshConfigFile = config.path
        }
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
            var target: VFSPath? = (try? providers.provider(for: tab.path)) == nil && RemoteFS.alias(of: tab.path) == nil ? .local(NSHomeDirectory()) : tab.path
            if let alias = RemoteFS.alias(of: tab.path) {
                // Karty zdalne łączą się ponownie; bez połączenia — katalog domowy.
                if (try? await remotes.provider(alias)) == nil { target = .local(NSHomeDirectory()) }
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
        providers.register(provider)
        let panel = self.panel(side ?? activeSide)
        let tab = panel.newTab(at: provider.root)
        tab.customTitle = "🔍 " + title
        try await tab.navigate(to: provider.root)
        return tab
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
        let snapshot = SessionSnapshot(left: left.snapshot, right: right.snapshot, activeSide: activeSide)
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
            notify(CommandInvocationRecord(command: id, arguments: arguments, invoker: invoker, started: started, outcome: .success(result.message)))
            return result
        } catch {
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
