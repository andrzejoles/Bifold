import BifoldCore
import BifoldWorkspace
import Foundation

extension FileItem {
    func agentJSON(directorySize: DirectorySize? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name),
            "path": .string(path.path),
            "type": .string(isNavigable ? "directory" : (kind == .symlink ? "symlink" : "file")),
            "permissions": .string(String(permissions, radix: 8)),
            "hidden": .bool(isHidden),
        ]
        if !isNavigable { o["size"] = .int(size) }
        if let d = directorySize { o["size"] = .int(d.bytes); o["files"] = .int(Int64(d.files)) }
        if let m = modified { o["modified"] = .string(ISO8601DateFormatter().string(from: m)) }
        return .object(o)
    }
}

@MainActor
func blockedPaths(_ ctx: CommandContext) -> BlockedPaths {
    BlockedPaths(for: ctx.workspace)
}

/// Górna granica liczby elementów listingu dla agenta (odpowiedź musi zmieścić się w ramce 4 MB).
let agentListLimit: Int64 = 10_000

/// Ścieżka lokalna z argumentu — tą samą funkcją (`parsePath`), którą liczy bramka uprawnień.
/// Ścieżka zdalna (`alias:/…`) to błąd: pliki na serwerach czyta `remote_list` / `remote_read`.
@MainActor
func agentLocalPath(_ ctx: CommandContext, _ key: String = "path") throws -> VFSPath {
    guard let raw = ctx.arguments.string(key) else { throw CommandError.missingArgument(key) }
    let path = ctx.workspace.parsePath(raw, relativeTo: ctx.tab.path)
    guard path.isLocal else { throw CommandError.invalidArgument(key, "remote path — use remote_list / remote_read") }
    return path
}

/// Liczba całkowita z argumentu w zakresie (poza zakresem — błąd `invalidArgument`, nie awaria).
func boundedInt(_ args: CommandArguments, _ key: String, default value: Int64, in range: ClosedRange<Int64>) throws -> Int64 {
    guard args[key] != nil else { return value }
    guard let v = args.int(key), range.contains(v) else { throw CommandError.invalidArgument(key, "\(range.lowerBound)…\(range.upperBound)") }
    return v
}

/// Komendy odczytu stanu i plików dla agenta (Etap 2). Mają efekt `none`, więc nic nie zmieniają.
@MainActor
public func agentCommands() -> [Command] {
    [
        Command(CommandDescriptor(
            id: "agent.state", title: L10n.tr("Stan aplikacji (agent)"), category: .help,
            agent: .read, effect: .none,
            summary: L10n.tr("Aktywny panel, karty obu paneli (ścieżka, widok, sortowanie, filtr, kursor, liczba zaznaczonych)."), inMenu: false)
        ) { ctx in
            let blocked = blockedPaths(ctx)
            @MainActor func panelJSON(_ panel: Panel) -> JSONValue {
                .object([
                    "side": .string(panel.side.rawValue),
                    "activeTab": .int(Int64(panel.activeTabIndex)),
                    "tabs": .array(panel.tabs.enumerated().map { i, tab in
                        let hidden = blocked.isBlocked(tab.path)
                        return .object([
                            "index": .int(Int64(i)),
                            "path": .string(hidden ? "«zablokowana»" : tab.path.path),
                            "viewMode": .string(tab.viewMode.rawValue),
                            "sort": .string("\(tab.sort.field.rawValue) \(tab.sort.ascending ? "asc" : "desc")"),
                            "filter": .string(tab.quickFilter),
                            "cursor": .string(hidden ? "" : (tab.cursorItem?.name ?? "")),
                            "selectedCount": .int(Int64(tab.selection.count)),
                            "itemCount": .int(Int64(max(0, tab.visibleItems.count - (tab.path.isRoot ? 0 : 1)))),
                        ])
                    }),
                ])
            }
            let state: JSONValue = [
                "activeSide": .string(ctx.workspace.activeSide.rawValue),
                "panels": [panelJSON(ctx.workspace.left), panelJSON(ctx.workspace.right)],
                "quickView": .bool(ctx.workspace.quickViewActive),
                "jobs": .int(Int64(ctx.workspace.jobs.activeJobs.count)),
            ]
            return CommandResult(value: untrusted(state))
        },

        Command(CommandDescriptor(
            id: "agent.selection", title: L10n.tr("Zaznaczone pliki (agent)"), category: .help,
            parameters: [sideParamAgent], agent: .read, effect: .none,
            summary: L10n.tr("Zaznaczone elementy panelu (ścieżki, rozmiary, typy); bez zaznaczenia — element pod kursorem."), inMenu: false)
        ) { ctx in
            let tab = try agentTab(ctx)
            let blocked = blockedPaths(ctx)
            let items = (tab.selection.isEmpty ? (tab.cursorItem.map { $0.isParentLink ? [] : [$0] } ?? []) : tab.selectedItems)
                .filter { !blocked.isBlocked($0.path) }
            let value: JSONValue = [
                "directory": .string(blocked.isBlocked(tab.path) ? "«zablokowana»" : tab.path.path),
                "fromCursor": .bool(tab.selection.isEmpty),
                "items": .array(items.map { $0.agentJSON(directorySize: tab.directorySizes[$0.path]) }),
            ]
            return CommandResult(value: untrusted(value))
        },

        Command(CommandDescriptor(
            id: "agent.list", title: L10n.tr("Zawartość katalogu (agent)"), category: .help,
            parameters: [
                CommandParameter("path", .path, required: true, L10n.tr("Katalog")),
                CommandParameter("includeHidden", .boolean, L10n.tr("Także pliki ukryte")),
                CommandParameter("limit", .integer, L10n.tr("Maks. liczba elementów (domyślnie 1000)")),
            ],
            agent: .read, effect: .none, summary: L10n.tr("Lista elementów katalogu (bez zmiany panelu)."), inMenu: false)
        ) { ctx in
            let path = try agentLocalPath(ctx)
            let blocked = blockedPaths(ctx)
            let limit = Int(try boundedInt(ctx.arguments, "limit", default: 1000, in: 0...agentListLimit))
            let items = try await LocalFS().list(path, options: ListOptions(includeHidden: ctx.arguments.bool("includeHidden") ?? false))
                .filter { !blocked.isBlocked($0.path) }
            let sorted = ListingProcessor.process(items, in: .root, options: .init(showHidden: true)).filter { !$0.isParentLink }
            let value: JSONValue = [
                "directory": .string(path.path),
                "total": .int(Int64(sorted.count)),
                "truncated": .bool(sorted.count > limit),
                "items": .array(sorted.prefix(limit).map { $0.agentJSON() }),
            ]
            return CommandResult(value: untrusted(value))
        },

        Command(CommandDescriptor(
            id: "agent.fileInfo", title: L10n.tr("Informacje o pliku (agent)"), category: .help,
            parameters: [CommandParameter("path", .path, required: true, L10n.tr("Element"))],
            agent: .read, effect: .none, summary: L10n.tr("Metadane elementu: typ, rozmiar, daty, prawa, tagi."), inMenu: false)
        ) { ctx in
            let path = try agentLocalPath(ctx)
            let fs = LocalFS()
            let item = try fs.itemSync(at: path)
            var json = item.agentJSON().objectValue ?? [:]
            json["tags"] = .array(((try? fs.tagsSync(of: path)) ?? []).map { .string($0) })
            if let c = item.created { json["created"] = .string(ISO8601DateFormatter().string(from: c)) }
            json["locked"] = .bool(item.flags.contains(.locked))
            return CommandResult(value: untrusted(.object(json)))
        },

        Command(CommandDescriptor(
            id: "agent.readFile", title: L10n.tr("Odczyt pliku (agent)"), category: .help,
            parameters: [
                CommandParameter("path", .path, required: true, L10n.tr("Plik")),
                CommandParameter("offset", .integer, L10n.tr("Początek (bajty)")),
                CommandParameter("length", .integer, L10n.tr("Liczba bajtów (domyślnie do limitu)")),
                CommandParameter("encoding", .string, L10n.tr("Kodowanie tekstu (domyślnie wykrywane)"), allowed: TextEncoding.allCases.map(\.rawValue)),
                CommandParameter("hex", .boolean, L10n.tr("Zrzut szesnastkowy (dla plików binarnych, maks. 64 KB)")),
            ],
            agent: .read, effect: .none,
            summary: L10n.tr("Treść pliku tekstowego (z limitem rozmiaru). Pliki binarne: tylko metadane, chyba że hex=true."), inMenu: false)
        ) { ctx in
            let path = try agentLocalPath(ctx)
            let fs = LocalFS()
            let item = try fs.itemSync(at: path)
            guard item.kind == .file else { throw CommandError.invalidArgument("path", L10n.tr("to nie jest zwykły plik")) }
            let maxBytes = ctx.workspace.settings.agent.maxReadBytes
            // Zakresy sprawdzane przed arytmetyką: ujemne lub ogromne wartości nie mogą przepełnić Int64.
            let offset = min(try boundedInt(ctx.arguments, "offset", default: 0, in: 0...Int64.max), max(0, item.size))
            let explicitLength = ctx.arguments["length"] == nil ? nil : try boundedInt(ctx.arguments, "length", default: 0, in: 0...Int64.max)
            let wantsHex = ctx.arguments.bool("hex") ?? false
            let limit = wantsHex ? min(maxBytes, 64 * 1024) : maxBytes
            let remaining = max(0, item.size - offset)
            if !wantsHex, explicitLength == nil, remaining > maxBytes {
                return CommandResult(value: untrusted([
                    "error": "too_large",
                    "size": .int(item.size),
                    "maxReadBytes": .int(maxBytes),
                    "hint": "Podaj offset i length (≤ maxReadBytes), żeby odczytać fragment.",
                ]))
            }
            let length = min(explicitLength ?? remaining, limit, remaining)
            let data = try fs.readSync(path, range: offset..<(offset + length))
            if wantsHex {
                return CommandResult(value: untrusted([
                    "path": .string(path.path), "size": .int(item.size), "offset": .int(offset),
                    "hex": .string(TextDecoding.hexDump(data, startOffset: offset)),
                ]))
            }
            if TextDecoding.looksBinary(data) {
                return CommandResult(value: untrusted([
                    "path": .string(path.path), "size": .int(item.size), "binary": true,
                    "hint": "Plik binarny — treść niedostępna; użyj hex=true, żeby zobaczyć fragment.",
                ]))
            }
            let encoding = ctx.arguments.string("encoding").flatMap(TextEncoding.init(rawValue:)) ?? TextDecoding.detect(data)
            return CommandResult(value: untrusted([
                "path": .string(path.path), "size": .int(item.size), "offset": .int(offset), "length": .int(Int64(data.count)),
                "truncated": .bool(offset + Int64(data.count) < item.size), "encoding": .string(encoding.rawValue),
                "text": .string(TextDecoding.decode(data, as: encoding)),
            ]))
        },
    ]
}

let sideParamAgent = CommandParameter("side", .string, "left lub right (domyślnie aktywny panel)", allowed: ["left", "right"])

@MainActor
func agentTab(_ ctx: CommandContext) throws -> Tab {
    guard let raw = ctx.arguments.string("side") else { return ctx.tab }
    guard let side = PanelSide(rawValue: raw) else { throw CommandError.invalidArgument("side", "left | right") }
    return ctx.workspace.panel(side).activeTab
}
