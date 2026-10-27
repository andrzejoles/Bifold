import BifoldCore
import Foundation

extension VFSPath {
    /// Postać do wyświetlania i wpisywania: `alias:/katalog` dla połączeń, zwykła ścieżka lokalnie.
    public var displayPath: String {
        if let alias = RemoteFS.alias(of: self) { return alias + ":" + path }
        return path
    }

    /// Ścieżka na telefonie (dostawcy `device:…`).
    public var isDevice: Bool { provider.rawValue.hasPrefix("device:") }

    /// „Maszyna” ścieżki: dysk lokalny (także archiwa i wyniki wyszukiwania), serwer albo telefon.
    public var machine: String {
        provider.rawValue.hasPrefix("remote:") || isDevice ? provider.rawValue : "local"
    }
}

extension CommandContext {
    func remoteFS(_ path: VFSPath) async throws -> (any RemoteFileProvider)? {
        guard let alias = RemoteFS.alias(of: path) else { return nil }
        return try await workspace.remotes.provider(alias)
    }

    /// Katalog na serwerze dla ścieżki panelu (absolutny albo względem katalogu domowego).
    func remoteDirectory(_ path: VFSPath) async -> String? {
        guard let fs = try? await remoteFS(path) else { return nil }
        if let scp = fs as? ScpFS { return scp.remotePath(path) }
        if let r = fs as? RemoteFS {
            let p = r.remotePath(path)
            return r.connection.path.hasPrefix("/") ? "/" + p : (p.isEmpty ? nil : p)
        }
        return nil
    }

    /// Otwiera kartę-terminal SSH w panelu `side` (domyślnie drugim). Agent nie ma dostępu do terminala.
    @discardableResult
    func openTerminal(_ alias: String, directory: String?, in panel: Panel) async throws -> Tab {
        guard !isAgent else { throw CommandError.notAvailable(L10n.tr("Agent nie ma dostępu do terminala")) }
        let spec = try await workspace.remotes.terminalSpec(alias, directory: directory)
        let start = VFSPath(provider: RemoteFS.providerID(alias), path: "/")
        let tab = panel.newTab(at: start)
        tab.terminal = spec
        tab.customTitle = "⌨ " + alias
        return tab
    }

    func rcloneFS(_ path: VFSPath) async throws -> RemoteFS? {
        guard let alias = RemoteFS.alias(of: path) else { return nil }
        return try await workspace.remotes.rcloneProvider(alias)
    }

    /// Kopiowanie z udziałem serwera SCP: pobieranie przez katalog tymczasowy (konflikty i cofanie
    /// jak przy archiwach), wysyłanie jako zadanie w tle. `nil` — SCP nie bierze udziału.
    func scpTransfer(_ kind: TransferKind, items: [FileItem]) async throws -> (JobSpec, String, (any TransferDelegate)?)? {
        let sourcePath = items.first?.path ?? tab.path
        var destination = arguments.string("destination").map { workspace.parsePath($0, relativeTo: otherTab.path) } ?? otherTab.path
        let source = try await remoteFS(sourcePath) as? ScpFS
        var target = try await remoteFS(destination) as? ScpFS
        guard source != nil || target != nil else { return nil }
        guard kind == .copy else {
            throw CommandError.notAvailable(L10n.tr("Serwer SCP: przenoszenie nie jest obsługiwane — skopiuj (F5), potem usuń (F8)"))
        }
        if !isAgent && arguments["destination"] == nil, let ui {
            guard let result = await ui.promptTransfer(kind: kind, items: items, defaultDestination: destination.displayPath + "/") else { throw CommandError.cancelledByUser }
            destination = workspace.parsePath(result.destination.trimmingCharacters(in: .whitespaces), relativeTo: otherTab.path)
            target = try await remoteFS(destination) as? ScpFS
        }
        let policy = try conflictPolicy()
        // Konflikty jak przy kopiowaniu lokalnym: polityka z argumentu, okno pytania w interfejsie,
        // dla agenta bez polityki — pomijanie (z raportem pominiętych).
        let delegate: any TransferDelegate = isAgent || ui == nil ? PolicyTransferDelegate(conflict: policy ?? .skip)
            : (policy.map { PolicyTransferDelegate(conflict: $0) } ?? ui!.transferDelegate())
        if let source, destination.isLocal {
            return (.extract(source: source, sources: items.map(\.path), destination: destination),
                    L10n.tr("Kopiowanie \(Format.describe(items)) z \(source.connection.alias)"), delegate)
        }
        if let target, sourcePath.isLocal {
            return (.scpUpload(ScpUpload(fs: target, sources: items.map(\.path), destination: destination, delegate: delegate)),
                    L10n.tr("Wysyłanie \(Format.describe(items)) → \(destination.displayPath)"), delegate)
        }
        throw CommandError.notAvailable(L10n.tr("Serwer SCP ⇄ inny serwer lub archiwum: najpierw skopiuj na dysk"))
    }

    /// Kopiowanie/przenoszenie z udziałem serwera (źródło lub cel zdalny). `nil` — zwykła operacja lokalna.
    func remoteTransfer(_ kind: TransferKind, items: [FileItem]) async throws -> (RcloneTransfer, VFSPath)? {
        // Źródło wg elementów (argument `paths` może wskazywać pliki spoza bieżącej karty).
        let sourcePath = items.first?.path ?? tab.path
        let sourceRemote = RemoteFS.alias(of: sourcePath) != nil
        var destination = arguments.string("destination").map { workspace.parsePath($0, relativeTo: otherTab.path) } ?? otherTab.path
        guard sourceRemote || RemoteFS.alias(of: destination) != nil else { return nil }
        if !isAgent && arguments["destination"] == nil {
            if let ui, let result = await ui.promptTransfer(kind: kind, items: items, defaultDestination: destination.displayPath + "/") {
                destination = workspace.parsePath(result.destination.trimmingCharacters(in: .whitespaces), relativeTo: otherTab.path)
            } else if ui != nil {
                throw CommandError.cancelledByUser
            }
        }
        if !destination.isLocal, RemoteFS.alias(of: destination) == nil { throw CommandError.notAvailable(L10n.tr("Nie można kopiować do archiwum ani listy wyników")) }
        guard sourcePath.isLocal || sourceRemote else { throw CommandError.notAvailable(L10n.tr("Kopiowanie z archiwum na serwer: najpierw rozpakuj na dysk")) }
        let src = try await rcloneFS(sourcePath)
        let dst = try await rcloneFS(destination)
        var transferItems: [RcloneTransfer.Item] = []
        for listed in items {
            if let src {
                // Typ i rozmiar z serwera (element mógł przyjść jako sama ścieżka).
                let item = (try? await src.item(at: listed.path)) ?? listed
                transferItems.append(.init(srcFs: src.fs, srcRemote: src.remotePath(item.path), isDirectory: item.isNavigable, name: item.name, size: max(0, item.size)))
            } else {
                transferItems.append(.init(srcFs: listed.path.parent?.path ?? "/", srcRemote: listed.name, isDirectory: listed.isNavigable, name: listed.name, size: max(0, listed.size)))
            }
        }
        let policy = try conflictPolicy()
        let transfer = RcloneTransfer(
            kind: kind, items: transferItems,
            dstFs: dst?.fs ?? destination.path, dstRemote: dst.map { $0.remotePath(destination) } ?? "",
            localDestination: destination.isLocal ? destination : nil, skipExisting: policy != .overwrite)
        return (transfer, destination)
    }
}

@MainActor
var remoteCommands: [Command] { [
    Command(CommandDescriptor(
        id: "remote.connections", title: L10n.tr("Menedżer połączeń…"), category: .network, tc: ["ctrl+f"], cmd: ["cmd+k"],
        agent: .none, effect: .settings, summary: L10n.tr("Połączenia SFTP, SCP, FTP/FTPS, WebDAV, SMB i chmur (hasła w Keychain)."))
    ) { ctx in
        try ctx.requireUI().showConnections()
        return .ok
    },

    Command(CommandDescriptor(
        id: "remote.terminal", title: L10n.tr("Terminal SSH…"), category: .network,
        parameters: [CommandParameter("alias", .string, L10n.tr("Alias połączenia (domyślnie serwer w aktywnym panelu)")), sideParam],
        agent: .none, effect: .external,
        summary: L10n.tr("Otwiera w drugim panelu terminal zalogowany na serwer SFTP/SCP (przez to samo połączenie, bez ponownego hasła), w katalogu z aktywnego panelu."))
    ) { ctx in
        let ssh = ctx.workspace.remotes.connections.filter(\.kind.usesSSH).map(\.alias)
        let current = ctx.arguments.string("alias") ?? RemoteFS.alias(of: ctx.tab.path)
        let alias = if let current, ssh.contains(current) {
            current
        } else {
            try await ctx.text("alias", title: L10n.tr("Terminal SSH"), message: ssh.joined(separator: ", "), default: ssh.first ?? "")
        }
        guard ssh.contains(alias) else { throw CommandError.notAvailable(L10n.tr("Terminal SSH działa dla połączeń SFTP i SCP")) }
        let directory = RemoteFS.alias(of: ctx.tab.path) == alias ? await ctx.remoteDirectory(ctx.tab.path) : nil
        // Domyślnie drugi panel; `side` sprawdzany jak w innych komendach (left | right).
        let panel = ctx.arguments.string("side") != nil ? try ctx.panel(forSide: "side") : ctx.workspace.otherPanel
        try await ctx.openTerminal(alias, directory: directory, in: panel)
        return CommandResult(message: L10n.tr("Terminal SSH: \(alias)"))
    },

    Command(CommandDescriptor(
        id: "remote.disconnect", title: L10n.tr("Rozłącz"), category: .network, tc: ["ctrl+shift+f"], cmd: ["cmd+ctrl+k"],
        parameters: [CommandParameter("alias", .string, L10n.tr("Alias połączenia (domyślnie serwer w aktywnym panelu)"))],
        agent: .read, effect: .uiState,
        summary: L10n.tr("Zamyka połączenie z serwerem albo telefon z aktywnego panelu wraz z jego kartami (ostatnia karta panelu wraca do katalogu domowego)."))
    ) { ctx in
        // Telefon w aktywnym panelu: zamknięcie urządzenia (sesja MTP, karty).
        if ctx.arguments.string("alias") == nil, ctx.tab.path.isDevice {
            let provider = ctx.tab.path.provider
            await ctx.workspace.closeDevice(provider)
            return CommandResult(message: L10n.tr("Zamknięto telefon"))
        }
        let remotes = ctx.workspace.remotes!
        let tabs = ctx.workspace.left.tabs + ctx.workspace.right.tabs
        let open = Set(tabs.compactMap { RemoteFS.alias(of: $0.path) }).union(remotes.connected)
        let alias = ctx.arguments.string("alias") ?? RemoteFS.alias(of: ctx.tab.path) ?? (open.count == 1 ? open.first : nil)
        guard let alias else {
            throw CommandError.notAvailable(open.isEmpty ? L10n.tr("Brak otwartych połączeń")
                : L10n.tr("Wybierz panel z serwerem albo podaj alias: \(open.sorted().joined(separator: ", "))"))
        }
        guard open.contains(alias) else { throw CommandError.notAvailable(L10n.tr("Połączenie \(alias) nie jest otwarte")) }
        // Agent nie ma dostępu do terminala (D44): nie może też zamknąć terminali SSH ani przerwać edycji
        // plików zdalnych przez rozłączenie — także terminali innego aliasu tego samego serwera (wspólne
        // połączenie główne SSH).
        let sharing = remotes.aliasesSharingSession(with: alias)
        if ctx.isAgent, tabs.contains(where: { $0.terminal.map { sharing.contains($0.alias) } ?? false }) || remotes.hasEditSessions(alias) {
            throw CommandError.notAvailable(L10n.tr("Połączenie \(alias) ma otwarty terminal SSH albo edycję pliku — rozłączyć może tylko użytkownik"))
        }
        await ctx.workspace.closeTabs { $0.terminal?.alias == alias || RemoteFS.alias(of: $0.path) == alias }
        await remotes.disconnect(alias)
        return CommandResult(message: L10n.tr("Rozłączono \(alias)"))
    },

    Command(CommandDescriptor(
        id: "remote.open", title: L10n.tr("Otwórz połączenie…"), category: .network, cmd: ["cmd+shift+k"],
        parameters: [CommandParameter("alias", .string, required: true, L10n.tr("Alias połączenia")), CommandParameter("path", .string, L10n.tr("Katalog na serwerze")), sideParam,
                     CommandParameter("terminal", .boolean, L10n.tr("Terminal SSH w drugim panelu (domyślnie wg ustawienia połączenia)"))],
        agent: .read, effect: .uiState, summary: L10n.tr("Otwiera połączenie w nowej karcie aktywnego panelu (agent zna tylko aliasy)."))
    ) { ctx in
        let names = ctx.workspace.remotes.connections.map(\.alias)
        let alias = try await ctx.text("alias", title: L10n.tr("Połączenie"), message: names.joined(separator: ", "), default: names.first ?? "")
        let fs = try await ctx.workspace.remotes.provider(alias)
        let target = VFSPath(provider: fs.id, path: ctx.arguments.string("path") ?? "/")
        let tab = try await ctx.workspace.open(target, in: try ctx.panel(forSide: "side"))
        // Połączenie SSH: terminal w drugim panelu (ustawienie połączenia; agent — nigdy).
        if !ctx.isAgent, ctx.arguments.bool("terminal") ?? ctx.workspace.remotes.connection(alias)?.opensTerminal ?? false {
            let other = ctx.workspace.left.tabs.contains { $0 === tab } ? ctx.workspace.right : ctx.workspace.left
            do {
                try await ctx.openTerminal(alias, directory: await ctx.remoteDirectory(target), in: other)
            } catch {
                ctx.ui?.showError(L10n.tr("Terminal SSH: \(error.localizedDescription)"))
            }
        }
        return CommandResult(message: target.displayPath)
    },

    Command(CommandDescriptor(
        id: "remote.listConnections", title: L10n.tr("Lista połączeń"), category: .network,
        agent: .read, effect: .none, summary: L10n.tr("Aliasy połączeń i rodzaj dostępu agenta (bez danych logowania)."), inMenu: false)
    ) { ctx in
        CommandResult(value: .array(ctx.workspace.remotes.connections.map { c in
            ["alias": .string(c.alias), "type": .string(c.kind.rawValue), "agentAccess": .string(c.kind.agentLevelIsApproval ? "approval" : "read")]
        }))
    },

    Command(CommandDescriptor(
        id: "remote.list", title: L10n.tr("Zawartość katalogu na serwerze"), category: .network,
        parameters: [CommandParameter("alias", .string, required: true, L10n.tr("Alias połączenia")), CommandParameter("path", .string, L10n.tr("Katalog (domyślnie /)")),
                     CommandParameter("limit", .integer, L10n.tr("Maks. liczba elementów (domyślnie 1000)"))],
        agent: .read, effect: .none, summary: L10n.tr("Lista elementów katalogu na serwerze."), inMenu: false)
    ) { ctx in
        guard let alias = ctx.arguments.string("alias") else { throw CommandError.missingArgument("alias") }
        let fs = try await ctx.workspace.remotes.provider(alias)
        let dir = VFSPath(provider: fs.id, path: ctx.arguments.string("path") ?? "/")
        let items = try await fs.list(dir, options: ListOptions(includeHidden: true))
        let limit = max(0, Int(ctx.arguments.int("limit") ?? 1000))
        let value: JSONValue = [
            "directory": .string(dir.displayPath), "total": .int(Int64(items.count)),
            "items": .array(items.prefix(limit).map { i in
                ["name": .string(i.name), "type": .string(i.isDirectory ? "directory" : "file"), "size": .int(i.size),
                 "modified": .string(i.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "")]
            }),
        ]
        return CommandResult(value: ctx.isAgent ? untrusted(value) : value)
    },

    Command(CommandDescriptor(
        id: "remote.read", title: L10n.tr("Odczyt pliku z serwera"), category: .network,
        parameters: [CommandParameter("alias", .string, required: true, L10n.tr("Alias połączenia")), CommandParameter("path", .string, required: true, L10n.tr("Plik"))],
        agent: .read, effect: .none, summary: L10n.tr("Treść pliku tekstowego z serwera (limit rozmiaru jak dla plików lokalnych)."), inMenu: false)
    ) { ctx in
        guard let alias = ctx.arguments.string("alias"), let raw = ctx.arguments.string("path") else { throw CommandError.missingArgument("alias/path") }
        let fs = try await ctx.workspace.remotes.provider(alias)
        let path = VFSPath(provider: fs.id, path: raw)
        let item = try await fs.item(at: path)
        let max = ctx.workspace.settings.agent.maxReadBytes
        // Także dowiązanie do katalogu (`size` to wtedy długość celu): odczyt pobrałby całe drzewo
        // (`link -> /` — cały serwer) do katalogu tymczasowego.
        guard !item.isNavigable else { throw CommandError.invalidArgument("path", L10n.tr("to katalog")) }
        let wrap: (JSONValue) -> JSONValue = { ctx.isAgent ? untrusted($0) : $0 }
        guard item.size <= max else {
            return CommandResult(value: wrap(["error": "too_large", "size": .int(item.size), "maxReadBytes": .int(max)]))
        }
        let data = try await fs.readContents(path, range: nil)
        if TextDecoding.looksBinary(data) { return CommandResult(value: wrap(["binary": true, "size": .int(item.size)])) }
        let enc = TextDecoding.detect(data)
        return CommandResult(value: wrap([
            "path": .string(path.displayPath), "encoding": .string(enc.rawValue), "text": .string(TextDecoding.decode(data, as: enc)),
        ]))
    },

    Command(CommandDescriptor(
        id: "remote.search", title: L10n.tr("Szukaj na serwerze…"), category: .network,
        parameters: [CommandParameter("alias", .string, required: true, L10n.tr("Alias połączenia")), CommandParameter("path", .string, L10n.tr("Katalog startowy")),
                     CommandParameter("nameMask", .string, required: true, L10n.tr("Maska nazw")), CommandParameter("maxResults", .integer, L10n.tr("Limit (domyślnie 1000)")),
                     CommandParameter("toPanel", .boolean, L10n.tr("Pokaż wyniki w nowej karcie panelu"))],
        agent: .read, effect: .none, summary: L10n.tr("Wyszukiwanie plików na serwerze (rclone lsjson rekurencyjnie + maska)."))
    ) { ctx in
        let alias = try await ctx.text("alias", title: L10n.tr("Połączenie"), default: RemoteFS.alias(of: ctx.tab.path) ?? "")
        let mask = try await ctx.text("nameMask", title: L10n.tr("Maska nazw"), default: "*")
        let fs = try await ctx.workspace.remotes.rcloneProvider(alias)
        let start = VFSPath(provider: fs.id, path: ctx.arguments.string("path") ?? (RemoteFS.alias(of: ctx.tab.path) == alias ? ctx.tab.path.path : "/"))
        let entries = try await fs.rclone.list(fs: fs.fs, remote: fs.remotePath(start), recursive: true)
        let m = NameMask(mask)
        let limit = max(0, Int(ctx.arguments.int("maxResults") ?? 1000))
        let hits = entries.filter { m.matches($0.name, isDirectory: $0.isDirectory) }.prefix(limit)
        let results = hits.map { start.appending($0.path).displayPath }
        // Z menu wynik musi być widoczny (lista wyników w panelu działa tylko dla plików lokalnych — raport).
        if !ctx.isAgent, ctx.arguments.bool("toPanel") ?? true, let ui = ctx.ui {
            ui.showReport(title: L10n.tr("Znaleziono: \(results.count)"), text: results.joined(separator: "\n"))
        }
        let value: JSONValue = ["count": .int(Int64(results.count)), "results": .array(results.map { .string($0) })]
        return CommandResult(message: L10n.tr("Znaleziono: \(results.count)"), value: ctx.isAgent ? untrusted(value) : value)
    },

    Command(CommandDescriptor(
        id: "remote.edit", title: L10n.tr("Edytuj plik zdalny"), category: .network,
        agent: .none, effect: .external, summary: L10n.tr("Pobiera plik do pliku tymczasowego, otwiera w edytorze i wysyła po każdym zapisie."))
    ) { ctx in
        guard let item = ctx.tab.cursorItem, !item.isNavigable, RemoteFS.alias(of: item.path) != nil else {
            throw CommandError.notAvailable(L10n.tr("Ustaw kursor na pliku na serwerze"))
        }
        let local = try await ctx.workspace.remotes.edit(item.path)
        try ctx.requireUI().openInEditor([local])
        return CommandResult(message: L10n.tr("Edycja \(item.name) — zapis wysyła plik na serwer"))
    },

    Command(CommandDescriptor(
        id: "remote.mount", title: L10n.tr("Zamontuj udział SMB/NFS…"), category: .network,
        parameters: [CommandParameter("url", .string, required: true, L10n.tr("smb://serwer/udział lub nfs://serwer/eksport")),
                     CommandParameter("alias", .string, L10n.tr("Połączenie SMB z hasłem w Keychain"))],
        agent: .none, effect: .external, summary: L10n.tr("Montuje udział sieciowy (NetFS) i otwiera go w panelu."))
    ) { ctx in
        var user: String?, password: String?
        var url = ctx.arguments.string("url")
        if let alias = ctx.arguments.string("alias"), let c = ctx.workspace.remotes.connection(alias) {
            user = c.user
            password = ctx.workspace.remotes.keychain.get(alias)
            url = url ?? "smb://\(c.host)\(c.path.hasPrefix("/") ? c.path : "/" + c.path)"
        }
        let address = try await ctx.text("url", title: L10n.tr("Udział sieciowy"), message: "smb://serwer/udział", default: url ?? "smb://")
        let mountPoint = try await ctx.workspace.remotes.mount(address, user: user, password: password)
        try await ctx.workspace.open(mountPoint, in: ctx.workspace.activePanel)
        return CommandResult(message: mountPoint.path)
    },
] }
