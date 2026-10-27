import BifoldCore
import BifoldWorkspace
import Foundation

/// Zasób wywołania agenta: ścieżka i to, czy operacja obejmuje całe jej poddrzewo (kopiowanie,
/// przenoszenie, Kosz, archiwum, synchronizacja, rozmiar katalogu). Zasób-poddrzewo nie może zawierać
/// zablokowanej ścieżki.
struct AgentResource: Equatable, Sendable {
    let path: VFSPath
    let subtree: Bool
}

/// Wywołanie „zamrożone” przez bramkę: ścieżki względne i cele domyślne (zaznaczenie, kursor,
/// drugi panel) rozwinięte do ścieżek absolutnych. Komenda wykonuje się dokładnie z tymi
/// argumentami — tymi samymi, które sprawdziła bramka i które widział użytkownik w podglądzie.
struct FrozenCall {
    var arguments: CommandArguments
    var resources: [AgentResource] = []
    /// Komenda nadal czyta na żywo katalogi kart (cel, którego nie da się zapisać jako ścieżki,
    /// np. element archiwum albo karta bez lokalnego katalogu) — po zgodzie muszą być takie same.
    var livePaths = false
    /// Jak wyżej, dla zaznaczenia i kursora.
    var liveSelection = false
    /// Zapisane zadanie synchronizacji, które sprawdzono (po zgodzie nie może się zmienić).
    var savedSyncJob: SyncJob?
}

/// Stan paneli, z którego komenda mogłaby jeszcze czytać na żywo.
struct PanelFingerprint: Equatable {
    struct TabState: Equatable {
        let id: UUID
        let path: VFSPath
        let selection: Set<VFSPath>?
        let cursor: VFSPath?
    }

    let activeSide: PanelSide
    let left: TabState
    let right: TabState

    @MainActor
    init(_ w: Workspace, selection: Bool) {
        func state(_ t: Tab) -> TabState {
            TabState(id: t.id, path: t.path, selection: selection ? t.selection : nil, cursor: selection ? t.cursor : nil)
        }
        activeSide = w.activeSide
        left = state(w.left.activeTab)
        right = state(w.right.activeTab)
    }
}

/// Jedna funkcja rozwiązywania ścieżek dla bramki i komendy (SECURITY.md §4.5): bramka liczy ścieżki
/// tak, jak policzyłaby je komenda (te same bazy ścieżek względnych, te same cele domyślne), sprawdza
/// je i przekazuje komendzie w postaci absolutnej, więc komenda nie ma już czego liczyć inaczej.
@MainActor
struct ArgumentFreezer {
    let workspace: Workspace
    let blocked: BlockedPaths

    static let searchCommands: Set<CommandID> = ["search.find", "search.save", "search.spotlight", "search.duplicates"]
    /// Komendy czytające rekurencyjnie poddrzewo argumentu (bez zmian w plikach): argumenty, których
    /// poddrzewo czytają. Rozmiar i liczba plików `~` obejmowałyby `~/.ssh` (SECURITY.md §4.5).
    /// Pozostałe odczyty nie schodzą w głąb: `dirs.compare` porównuje tylko pliki w obu katalogach
    /// (zablokowane odfiltrowuje komenda), `file.checksumVerify` czyta wpisy pliku sum (zablokowane →
    /// `invalid` w komendzie), `archive.list`/`archive.test` — jeden plik, wyszukiwanie — wyniki filtrowane.
    static let recursiveReadCommands: [CommandID: Set<String>] = [
        "sync.preview": ["source", "destination"], "sync.run": ["source", "destination"],
        "selection.calculateSizes": ["paths"],
    ]
    /// Komendy, które obcinają spacje na brzegach ścieżki (`transferRequest`: `.whitespaces`). Cel
    /// `panel.navigate` liczy wspólna funkcja `Workspace.navigationText` (bramka i komenda).
    static let trimmingCommands: Set<CommandID> = ["file.copy", "file.move"]

    /// Znaki sterujące (C0, DEL, C1 — w tym U+0085) i separatory wierszy/akapitów (U+2028, U+2029)
    /// w ścieżce od agenta. Komendy i okna różnie je obcinają (`.newlines` ≠ `.whitespaces`), więc
    /// ścieżka „~/.ssh\n” mogła przejść bramkę jako inny katalog niż ten, który otworzyła komenda.
    static func hasControlCharacters(_ raw: String) -> Bool {
        raw.unicodeScalars.contains { s in
            s.value < 0x20 || (0x7F...0x9F).contains(s.value) || s.value == 0x2028 || s.value == 0x2029
        }
    }

    var tab: Tab { workspace.activeTab }
    var other: Tab { workspace.otherTab }
    /// Baza względnego celu kopiowania/przenoszenia — jak `CommandContext.localBaseDirectory` w komendzie:
    /// lokalny katalog aktywnego panelu, inaczej drugiego (dla ścieżki nielokalnej `parsePath` liczy
    /// od `/`, jak `resolvePath(_, relativeTo: nil)` w komendzie).
    var transferBase: VFSPath { tab.path.isLocal ? tab.path : other.path }

    /// Tekst ścieżki, który `parsePath` i (dla ścieżek lokalnych) `resolvePath` rozumieją tak samo,
    /// niezależnie od bazy. `nil` — ścieżki nie da się zapisać tekstem (archiwum, telefon, wyniki).
    static func text(_ p: VFSPath) -> String? {
        if p.isLocal { return p.path }
        if RemoteFS.alias(of: p) != nil { return p.displayPath }
        return nil
    }

    func sideTab(_ args: CommandArguments) -> Tab {
        if let raw = args.string("side"), let side = PanelSide(rawValue: raw) { return workspace.panel(side).activeTab }
        return tab
    }

    /// Domyślny katalog wyszukiwania (jak w `searchCriteria`).
    var searchBase: VFSPath { tab.path.isLocal ? tab.path : .local(NSHomeDirectory()) }

    /// Czy dany argument ścieżkowy obejmuje całe poddrzewo.
    static func subtree(_ d: CommandDescriptor, _ param: String) -> Bool {
        if let params = recursiveReadCommands[d.id] { return params.contains(param) }
        guard d.effect == .modifiesFiles else { return false }
        if ["file.copy", "file.move"].contains(d.id), param == "destination" { return false }
        if d.id == "file.split", param == "destination" { return false }
        return true
    }

    /// Ścieżka z tekstu agenta — `parsePath`, jak w komendach. Dla `alias:/…` sprawdzana jest też
    /// interpretacja lokalna (`resolvePath`), którą zobaczyłaby komenda czytająca argument
    /// przez `CommandArguments.path`, żeby `nas:/../../.ssh` nie ominęło blokady.
    func resolve(_ raw: String, base: VFSPath, subtree: Bool) throws -> VFSPath {
        if Self.hasControlCharacters(raw) { throw AgentDenial.controlCharacters }
        let parsed = workspace.parsePath(raw, relativeTo: base)
        if !parsed.isLocal {
            let local = resolvePath(raw, relativeTo: base.isLocal ? base : nil)
            if blocked.isBlocked(local) || (subtree && blocked.containsBlocked(local)) {
                throw AgentDenial.blockedPath(local.path)
            }
        }
        return parsed
    }

    func frozenText(_ p: VFSPath, raw: String) -> String? {
        guard var t = Self.text(p) else { return nil }
        // „katalog/” w kopiowaniu oznacza katalog docelowy, nie nową nazwę.
        if raw.hasSuffix("/"), !t.hasSuffix("/") { t += "/" }
        return t
    }

    func freeze(_ d: CommandDescriptor, _ input: CommandArguments) throws -> FrozenCall {
        var call = FrozenCall(arguments: input)
        let id = d.id
        func add(_ p: VFSPath, _ subtree: Bool) { call.resources.append(AgentResource(path: p, subtree: subtree)) }
        func set(_ key: String, _ p: VFSPath, raw: String = "", selection: Bool = false) {
            if let t = frozenText(p, raw: raw) {
                call.arguments[key] = .string(t)
            } else if selection {
                call.liveSelection = true
            } else {
                call.livePaths = true
            }
        }
        func trimmed(_ raw: String) -> String { Self.trimmingCommands.contains(id) ? raw.trimmingCharacters(in: .whitespaces) : raw }

        // 1. Elementy (`paths`, `names`): jawne albo domyślne (zaznaczenie / kursor, katalog wyszukiwania).
        var targets: [VFSPath] = []
        for p in d.parameters where p.type == .paths && (p.name == "paths" || p.name == "names") {
            let sub = Self.subtree(d, p.name)
            if let raws = input.strings(p.name) {
                let base = Self.searchCommands.contains(id) ? searchBase : (p.name == "names" ? sideTab(input).path : tab.path)
                var out: [JSONValue] = []
                for raw in raws {
                    let path = try resolve(raw, base: base, subtree: sub)
                    add(path, sub)
                    targets.append(path)
                    if let t = frozenText(path, raw: raw) { out.append(.string(t)) } else { call.liveSelection = true }
                }
                if !call.liveSelection { call.arguments[p.name] = .array(out) }
            } else if p.name == "paths", Self.searchCommands.contains(id) {
                add(searchBase, false)
                targets = [searchBase]
                if let t = Self.text(searchBase) { call.arguments["paths"] = .array([.string(t)]) }
            } else if p.name == "paths" {
                let items = tab.targets.map(\.path)
                for i in items { add(i, sub) }
                targets = items
                let texts = items.compactMap(Self.text)
                if texts.count == items.count {
                    call.arguments["paths"] = .array(texts.map { .string($0) })
                } else {
                    call.liveSelection = true
                }
            }
        }

        // 2. Pozostałe ścieżki jawne, każda względem bazy, której używa komenda.
        for p in d.parameters where p.type == .path {
            guard let original = input.string(p.name) else { continue }
            let base: VFSPath
            switch (id.rawValue, p.name) {
            case ("file.compare", "right"): base = other.path
            case ("file.copy", "destination"), ("file.move", "destination"): base = transferBase
            case ("panel.navigate", "path"): base = sideTab(input).path
            case ("archive.create", "destination"): base = targets.first?.parent ?? tab.path
            default: base = tab.path
            }
            if Self.hasControlCharacters(original) { throw AgentDenial.controlCharacters }
            // Cel nawigacji — ta sama funkcja co w komendzie; zamrożona ścieżka nie jest już przycinana.
            let raw = id == "panel.navigate" && p.name == "path" ? workspace.navigationText(original, relativeTo: base) : trimmed(original)
            let sub = Self.subtree(d, p.name)
            let path = try resolve(raw, base: base, subtree: sub)
            add(path, sub)
            set(p.name, path, raw: raw)
        }

        // 3. Narzędzia serwerowe: alias + ścieżka na serwerze.
        if let alias = input.string("alias") {
            add(VFSPath(provider: RemoteFS.providerID(alias), path: input.string("path") ?? "/"), false)
        }

        // 4. Cele domyślne poszczególnych komend.
        switch id.rawValue {
        case "file.copy", "file.move":
            if input["destination"] == nil {
                add(other.path, false)
                set("destination", other.path)
            }
            if let raw = call.arguments.string("destination") {
                let dest = workspace.parsePath(raw, relativeTo: transferBase)
                let isDir = dest.isLocal ? ((try? LocalFS().itemSync(at: dest))?.isNavigable ?? false) : true
                if isDir || raw.hasSuffix("/") || targets.count > 1 {
                    // Element ląduje jako `cel/nazwa` — także całe jego poddrzewo (np. katalog „.ssh” do ~).
                    for t in targets { add(dest.appending(t.name), true) }
                } else {
                    add(dest, true)
                }
            }
        case "archive.extract":
            if input["destination"] == nil {
                add(other.path, true)
                if other.path.isLocal { set("destination", other.path) } else { call.livePaths = true }
            }
        case "archive.create":
            // Domyślna nazwa archiwum zależy od formatu i zaznaczenia — komenda liczy ją z katalogu drugiego panelu.
            if input["destination"] == nil {
                add(other.path.isLocal ? other.path : (targets.first?.parent ?? tab.path), false)
                call.livePaths = true
            }
        case "file.rename":
            if input["path"] == nil {
                if let item = tab.cursorItem, !item.isParentLink {
                    add(item.path, true)
                    set("path", item.path, selection: true)
                }
            }
            if let newName = input.string("newName"), let raw = call.arguments.string("path"),
               let parent = workspace.parsePath(raw, relativeTo: tab.path).parent {
                add(resolvePath(newName, relativeTo: parent), false)
            }
        case "file.mkdir", "file.newFile":
            if let name = input.string("name") {
                if tab.path.isLocal {
                    let p = resolvePath(name, relativeTo: tab.path)
                    add(p, false)
                    call.arguments["name"] = .string(p.path)
                } else {
                    add(tab.path.appending(name), false)
                }
                // Komenda sprawdza, czy bieżący katalog jest lokalny, czy na serwerze.
                call.livePaths = true
            }
        case "file.split":
            var source: VFSPath?
            if let raw = call.arguments.string("path") { source = workspace.parsePath(raw, relativeTo: tab.path) }
            if input["path"] == nil, let cursor = tab.cursorItem?.path {
                source = cursor
                add(cursor, false)
                set("path", cursor, selection: true)
            }
            if input["destination"] == nil, let source {
                let dest = other.path.isLocal ? other.path : (source.parent ?? tab.path)
                add(dest, false)
                set("destination", dest)
            }
        case "file.join":
            var first: VFSPath?
            if let raw = call.arguments.string("path") { first = workspace.parsePath(raw, relativeTo: tab.path) }
            if input["path"] == nil, let cursor = tab.cursorItem?.path {
                first = cursor
                add(cursor, false)
                set("path", cursor, selection: true)
            }
            if input["target"] == nil, let first {
                let target = (other.path.isLocal ? other.path : (first.parent ?? tab.path)).appending(first.name.fileStem)
                add(target, true)
                set("target", target)
            }
        case "file.compare":
            let selected = tab.selectedItems.filter { $0.kind == .file }
            if input["left"] == nil, input["right"] == nil, selected.count == 2 {
                for (key, item) in zip(["left", "right"], selected) {
                    add(item.path, false)
                    set(key, item.path, selection: true)
                }
            } else {
                if input["left"] == nil, let c = tab.cursorItem?.path {
                    add(c, false)
                    set("left", c, selection: true)
                }
                if input["right"] == nil, let c = other.cursorItem?.path {
                    add(c, false)
                    set("right", c, selection: true)
                }
            }
        case "sync.preview", "sync.run", "sync.save":
            let sub = Self.subtree(d, "source")
            if input["source"] == nil {
                add(tab.path, sub)
                set("source", tab.path)
            }
            if input["destination"] == nil {
                add(other.path, sub)
                set("destination", other.path)
            }
        case "sync.runSaved":
            let jobs = workspace.syncJobs
            if let name = input.string("name") ?? jobs.first?.name, let job = jobs.first(where: { $0.name == name }) {
                call.savedSyncJob = job
                call.arguments["name"] = .string(job.name)
                add(workspace.parsePath(job.source, relativeTo: .root), true)
                add(workspace.parsePath(job.destination, relativeTo: .root), true)
            }
        case "search.runSaved":
            if let name = input.string("name"), let saved = workspace.savedSearches.first(where: { $0.name == name }) {
                for root in saved.criteria.roots { add(root, false) }
            }
        case "dirs.compare":
            add(workspace.left.activeTab.path, false)
            add(workspace.right.activeTab.path, false)
        case "agent.selection":
            add(sideTab(input).path, false)
        default:
            break
        }
        return call
    }
}
