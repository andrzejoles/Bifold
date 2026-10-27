import BifoldCore
import Foundation

/// Zapisane wyszukiwania (`searches.json` w katalogu aplikacji).
public struct SavedSearch: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var criteria: SearchCriteria

    public init(name: String, criteria: SearchCriteria) {
        self.name = name
        self.criteria = criteria
    }
}

extension Workspace {
    var searchesURL: URL { paths.root.appending(path: "searches.json") }

    public var savedSearches: [SavedSearch] {
        get { JSONStore.load([SavedSearch].self, from: searchesURL) ?? [] }
        set { try? JSONStore.save(newValue, to: searchesURL) }
    }
}

let searchParams: [CommandParameter] = [
    CommandParameter("paths", .paths, L10n.tr("Katalogi przeszukiwania (domyślnie bieżący)")),
    CommandParameter("nameMask", .string, L10n.tr("Maska nazw, np. *.jpg;*.png|tmp*")),
    CommandParameter("nameRegex", .string, L10n.tr("Wyrażenie regularne na nazwie (zamiast maski)")),
    CommandParameter("content", .string, L10n.tr("Tekst w treści plików (ripgrep)")),
    CommandParameter("contentRegex", .boolean, L10n.tr("Tekst w treści jest wyrażeniem regularnym")),
    CommandParameter("caseSensitive", .boolean, L10n.tr("Rozróżniaj wielkość liter")),
    CommandParameter("encoding", .string, L10n.tr("Kodowanie treści: auto, utf-8, windows-1250, iso-8859-2, utf-16le…")),
    CommandParameter("recursive", .boolean, L10n.tr("Także podkatalogi (domyślnie tak)")),
    CommandParameter("includeHidden", .boolean, L10n.tr("Także ukryte")),
    CommandParameter("modifiedAfter", .string, L10n.tr("Zmodyfikowane po (ISO 8601)")),
    CommandParameter("modifiedBefore", .string, L10n.tr("Zmodyfikowane przed (ISO 8601)")),
    CommandParameter("minSize", .integer, L10n.tr("Minimalny rozmiar w bajtach")),
    CommandParameter("maxSize", .integer, L10n.tr("Maksymalny rozmiar w bajtach")),
    CommandParameter("kind", .string, L10n.tr("any | files | directories"), allowed: ["any", "files", "directories"]),
    CommandParameter("maxResults", .integer, L10n.tr("Limit wyników (domyślnie 1000 dla agenta)")),
    CommandParameter("toPanel", .boolean, L10n.tr("Pokaż wyniki w nowej karcie panelu")),
    CommandParameter("searchArchives", .boolean, L10n.tr("Szukaj nazw także wewnątrz archiwów (bez rozpakowywania)")),
]

extension CommandContext {
    func searchCriteria() throws -> SearchCriteria {
        let a = arguments
        let iso = ISO8601DateFormatter()
        func date(_ key: String) throws -> Date? {
            guard let s = a.string(key) else { return nil }
            guard let d = iso.date(from: s) else { throw CommandError.invalidArgument(key, "ISO 8601") }
            return d
        }
        // Wzorzec odrzucony (zbyt złożony, zbyt długi) albo niepoprawny to błąd, nie „0 wyników”.
        if let pattern = a.string("nameRegex"), !pattern.isEmpty {
            let regex = NameRegex(pattern)
            guard regex.isValid else { throw CommandError.invalidArgument("nameRegex", regex.problem ?? pattern) }
        }
        return SearchCriteria(
            roots: searchRoots(),
            nameMask: a.string("nameMask") ?? "",
            nameRegex: a.string("nameRegex") ?? "",
            recursive: a.bool("recursive") ?? true,
            includeHidden: a.bool("includeHidden") ?? false,
            contentText: a.string("content") ?? "",
            contentIsRegex: a.bool("contentRegex") ?? false,
            caseSensitive: a.bool("caseSensitive") ?? false,
            encoding: a.string("encoding") ?? "auto",
            modifiedAfter: try date("modifiedAfter"),
            modifiedBefore: try date("modifiedBefore"),
            minSize: a.int("minSize"),
            maxSize: a.int("maxSize"),
            kind: a.string("kind").flatMap(SearchCriteria.KindFilter.init(rawValue:)) ?? .any,
            maxResults: Int(a.int("maxResults") ?? (isAgent ? 1000 : 50_000)))
            .with { if a.bool("searchArchives") == true { $0.archiveTool = workspace.settings.toolPath("7zz") } }
    }

    /// Katalogi przeszukiwania: argument `paths` (jak przy elementach — `parsePath`, więc także
    /// ścieżki absolutne zamrożone przez bramkę agenta) albo bieżący katalog lokalny / domowy.
    func searchRoots() -> [VFSPath] {
        let base = tab.path.isLocal ? tab.path : workspace.homePath
        return arguments.strings("paths")?.map { workspace.parsePath($0, relativeTo: base) } ?? [base]
    }

    /// Dla agenta silnik wyszukiwania nie czyta, nie pokazuje i nie liczy zablokowanych ścieżek — inaczej
    /// `truncated` przy `maxResults: 1` zdradzałby treść i nazwy zablokowanych plików.
    var searchExclusion: SearchExclusion {
        guard isAgent else { return .none }
        let blocked = BlockedPaths(for: workspace)
        return SearchExclusion(isExcluded: { blocked.isBlocked($0) }, containsExcluded: { blocked.containsBlocked($0) })
    }

    /// Dla agenta: bez ścieżek zablokowanych (SECURITY.md §4.5) — ani ścieżki, ani dopasowanej treści.
    func visibleToAgent(_ hits: [SearchHit]) -> [SearchHit] {
        guard isAgent else { return hits }
        let blocked = BlockedPaths(for: workspace)
        return hits.filter { !blocked.isBlocked($0.item.path) }
    }

    /// Wyniki do JSON (dla agenta) albo do panelu.
    func deliver(_ allHits: [SearchHit], truncated: Bool, title: String) async throws -> CommandResult {
        let hits = visibleToAgent(allHits)
        if arguments.bool("toPanel") ?? !isAgent {
            try await workspace.showResults(title: title, items: hits.map(\.item))
        }
        let value: JSONValue = [
            "count": .int(Int64(hits.count)),
            "truncated": .bool(truncated),
            "results": .array(hits.prefix(isAgent ? 1000 : 0).map { hit in
                var o: [String: JSONValue] = [
                    "path": .string(hit.item.path.path),
                    "type": .string(hit.item.isNavigable ? "directory" : "file"),
                ]
                if !hit.item.isNavigable { o["size"] = .int(hit.item.size) }
                if !hit.matches.isEmpty {
                    o["matches"] = .array(hit.matches.prefix(5).map { ["line": .int(Int64($0.line)), "text": .string($0.text)] })
                }
                return .object(o)
            }),
        ]
        // Nazwy i treść z plików — dla agenta oznaczone jako niezaufane (SECURITY.md §4.6).
        return CommandResult(message: L10n.tr("Znaleziono: \(hits.count)"), value: isAgent ? untrusted(value) : value)
    }
}

/// Rozmiar w zapisie „100M”, „1,5G”, „700k” albo w bajtach (także okno wyszukiwania).
public func parseSize(_ text: String) -> Int64? {
    let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").uppercased()
    let kb = 1024.0, mb = kb * 1024, gb = mb * 1024, tb = gb * 1024
    let units: [(String, Double)] = [("TB", tb), ("GB", gb), ("MB", mb), ("KB", kb), ("T", tb), ("G", gb), ("M", mb), ("K", kb), ("B", 1)]
    for (suffix, mult) in units where t.hasSuffix(suffix) {
        guard let v = Double(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
        // „1E30K”, „INFB”, „NANM” — poza zakresem Int64 to błąd, nie awaria.
        let bytes = v * mult
        guard bytes.isFinite, bytes >= 0, bytes < 9.0e18 else { return nil }
        return Int64(bytes)
    }
    return Int64(t)
}

extension RenameRule {
    /// Zakresy licznika: `counterStart + indeks * counterStep` i dopełnienie zerami nie mogą przepełnić Int.
    init(arguments a: CommandArguments) throws {
        func bounded(_ key: String, _ range: ClosedRange<Int64>) throws {
            guard a[key] != nil else { return }
            guard let v = a.int(key), range.contains(v) else { throw CommandError.invalidArgument(key, "\(range.lowerBound)…\(range.upperBound)") }
        }
        try bounded("counterStart", -1_000_000_000...1_000_000_000)
        try bounded("counterStep", -1_000_000...1_000_000)
        try bounded("counterDigits", 0...20)
        self.init(
            nameMask: a.string("nameMask") ?? "[N]", extensionMask: a.string("extensionMask") ?? "[E]",
            search: a.string("search") ?? "", replace: a.string("replace") ?? "", regex: a.bool("regex") ?? false,
            caseSensitive: a.bool("caseSensitive") ?? false,
            nameCase: a.string("nameCase").flatMap(CaseMode.init(rawValue:)) ?? .unchanged,
            extensionCase: a.string("extensionCase").flatMap(CaseMode.init(rawValue:)) ?? .unchanged,
            counterStart: Int(a.int("counterStart") ?? 1), counterStep: Int(a.int("counterStep") ?? 1),
            counterDigits: Int(a.int("counterDigits") ?? 1))
    }
}

/// Plan zmiany nazw poza głównym wątkiem: wyrażenie regularne od agenta (liczone przed oknem zgody)
/// albo odczyt EXIF/metadanych wielu plików nie mogą zawiesić interfejsu.
func renamePlan(_ items: [FileItem], rule: RenameRule) async throws -> [RenamePlanEntry] {
    try await runBlocking(qos: .userInitiated) { MultiRename.plan(items, rule: rule) }
}

let renameParams: [CommandParameter] = [
    pathsParam,
    CommandParameter("nameMask", .string, L10n.tr("Maska nazwy: [N] nazwa, [N2-5] fragment, [C] licznik, [P] katalog, [Y][M][D][h][m][s] data, [Exif:DateTimeOriginal:yyyy-MM-dd], [Exif:Model], [Media:artist|title|album|year]")),
    CommandParameter("extensionMask", .string, L10n.tr("Maska rozszerzenia (domyślnie [E])")),
    CommandParameter("search", .string, L10n.tr("Znajdź (w całej nowej nazwie)")),
    CommandParameter("replace", .string, L10n.tr("Zamień na ($1… dla wyrażeń regularnych)")),
    CommandParameter("regex", .boolean, L10n.tr("Znajdź jako wyrażenie regularne")),
    CommandParameter("caseSensitive", .boolean, L10n.tr("Rozróżniaj wielkość liter przy znajdowaniu")),
    CommandParameter("nameCase", .string, L10n.tr("Wielkość liter nazwy"), allowed: CaseMode.allCases.map(\.rawValue)),
    CommandParameter("extensionCase", .string, L10n.tr("Wielkość liter rozszerzenia"), allowed: CaseMode.allCases.map(\.rawValue)),
    CommandParameter("counterStart", .integer, L10n.tr("Licznik: początek")),
    CommandParameter("counterStep", .integer, L10n.tr("Licznik: krok")),
    CommandParameter("counterDigits", .integer, L10n.tr("Licznik: liczba cyfr")),
]

@MainActor
var searchCommands: [Command] { [
    Command(CommandDescriptor(
        id: "search.find", title: L10n.tr("Szukaj plików…"), category: .tools, tc: ["alt+f7"], cmd: ["cmd+alt+f"],
        parameters: searchParams, agent: .full, effect: .uiState,
        summary: L10n.tr("Wyszukiwanie po nazwie (maska, regex), treści (ripgrep, kodowania), dacie, rozmiarze i atrybutach; wyniki opcjonalnie w panelu."))
    ) { ctx in
        if !ctx.isAgent && ctx.arguments.isEmpty {
            try ctx.requireUI().showSearch(directory: ctx.tab.path, criteria: nil)
            return .ok
        }
        let criteria = try ctx.searchCriteria()
        let (hits, truncated) = try await SearchEngine.collect(criteria, ripgrep: ctx.workspace.settings.toolPath("rg"), exclusion: ctx.searchExclusion)
        let title = !criteria.contentText.isEmpty ? "„\(criteria.contentText)”" : (criteria.nameMask.isEmpty ? criteria.nameRegex : criteria.nameMask)
        return try await ctx.deliver(hits, truncated: truncated, title: title.isEmpty ? L10n.tr("wyniki") : title)
    },

    Command(CommandDescriptor(
        id: "search.spotlight", title: L10n.tr("Szukaj w Spotlight…"), category: .tools, tc: ["ctrl+alt+f"],
        parameters: [CommandParameter("query", .string, required: true, L10n.tr("Szukany tekst (nazwa lub treść)")), pathsParam,
                     CommandParameter("toPanel", .boolean, L10n.tr("Pokaż wyniki w nowej karcie panelu"))],
        agent: .full, effect: .uiState, summary: L10n.tr("Wyszukiwanie przez indeks Spotlight w bieżącym katalogu."))
    ) { ctx in
        let query = try await ctx.text("query", title: L10n.tr("Spotlight"), message: L10n.tr("Szukaj (nazwa lub treść):"))
        let scopes = ctx.searchRoots()
        let paths = await SpotlightSearch.run(query, scopes: scopes)
        let fs = LocalFS()
        let hits = paths.compactMap { try? fs.itemSync(at: $0) }.map { SearchHit(item: $0, matches: []) }
        return try await ctx.deliver(hits, truncated: false, title: "Spotlight: \(query)")
    },

    Command(CommandDescriptor(
        id: "search.save", title: L10n.tr("Zapisz wyszukiwanie"), category: .tools,
        parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa"))] + searchParams,
        agent: .full, effect: .settings, summary: L10n.tr("Zapisuje kryteria wyszukiwania pod nazwą."), inMenu: false)
    ) { ctx in
        let name = try await ctx.text("name", title: L10n.tr("Nazwa wyszukiwania"))
        var all = ctx.workspace.savedSearches.filter { $0.name != name }
        all.append(SavedSearch(name: name, criteria: try ctx.searchCriteria()))
        ctx.workspace.savedSearches = all
        return CommandResult(message: name)
    },

    Command(CommandDescriptor(
        id: "search.runSaved", title: L10n.tr("Uruchom zapisane wyszukiwanie…"), category: .tools,
        parameters: [CommandParameter("name", .string, required: true, L10n.tr("Nazwa zapisanego wyszukiwania")),
                     CommandParameter("toPanel", .boolean, L10n.tr("Pokaż wyniki w nowej karcie panelu"))],
        agent: .full, effect: .uiState, summary: L10n.tr("Uruchamia zapisane wyszukiwanie; wyniki trafiają do panelu."))
    ) { ctx in
        let saved = ctx.workspace.savedSearches
        if ctx.arguments.string("name") == nil, !ctx.isAgent {
            if saved.isEmpty { throw CommandError.notAvailable(L10n.tr("Brak zapisanych wyszukiwań (zapisz je w oknie Szukaj).")) }
        }
        let name = try await ctx.text("name", title: L10n.tr("Zapisane wyszukiwanie"), message: saved.map(\.name).joined(separator: ", "), default: saved.first?.name ?? "")
        guard let s = saved.first(where: { $0.name == name }) else { throw CommandError.invalidArgument("name", name) }
        let (hits, truncated) = try await SearchEngine.collect(s.criteria, ripgrep: ctx.workspace.settings.toolPath("rg"), exclusion: ctx.searchExclusion)
        return try await ctx.deliver(hits, truncated: truncated, title: s.name)
    },

    Command(CommandDescriptor(
        id: "search.listSaved", title: L10n.tr("Zapisane wyszukiwania"), category: .tools,
        agent: .read, effect: .none, summary: L10n.tr("Lista zapisanych wyszukiwań."), inMenu: false)
    ) { ctx in
        CommandResult(value: try JSONValue.encode(ctx.workspace.savedSearches.map(\.name)))
    },

    Command(CommandDescriptor(
        id: "search.duplicates", title: L10n.tr("Szukaj duplikatów…"), category: .tools, tc: ["ctrl+alt+d"],
        parameters: [pathsParam,
                     CommandParameter("mode", .string, L10n.tr("content (treść), nameAndSize, name"), allowed: DuplicateFinder.Mode.allCases.map(\.rawValue)),
                     CommandParameter("minSize", .integer, L10n.tr("Pomijaj pliki mniejsze (bajty)")),
                     CommandParameter("toPanel", .boolean, L10n.tr("Pokaż wyniki w nowej karcie panelu"))],
        agent: .read, effect: .none, summary: L10n.tr("Grupy identycznych plików (nazwa, rozmiar, zawartość SHA-256) w katalogach."))
    ) { ctx in
        let roots = ctx.searchRoots()
        let mode = ctx.arguments.string("mode").flatMap(DuplicateFinder.Mode.init(rawValue:)) ?? .content
        let minSize = ctx.arguments.int("minSize") ?? 1
        var groups = try await runBlocking(qos: .utility) { try DuplicateFinder.find(in: roots, mode: mode, minSize: minSize) }
        if ctx.isAgent {
            // Bez zablokowanych ścieżek; grupa z jednym widocznym plikiem zdradzałaby duplikat w zablokowanym katalogu.
            let blocked = BlockedPaths(for: ctx.workspace)
            groups = groups.map { $0.filter { !blocked.isBlocked($0.path) } }.filter { $0.count > 1 }
        }
        if ctx.arguments.bool("toPanel") ?? !ctx.isAgent {
            try await ctx.workspace.showResults(title: L10n.tr("duplikaty (\(groups.count))"), items: groups.flatMap { $0 })
        }
        let value: JSONValue = .array(groups.prefix(500).map { g in .array(g.map { .string($0.path.path) }) })
        return CommandResult(message: L10n.tr("Grupy duplikatów: \(groups.count)"), value: ctx.isAgent ? untrusted(value) : value)
    },

    Command(
        CommandDescriptor(
            id: "file.multiRename", title: L10n.tr("Zmiana nazw wielu plików…"), category: .file, tc: ["ctrl+m"], cmd: ["cmd+shift+m"],
            parameters: renameParams, agent: .approval, effect: .modifiesFiles,
            summary: L10n.tr("Zmienia nazwy wielu elementów według masek, licznika, dat, metadanych EXIF/multimediów, znajdź-zamień (regex) i wielkości liter; z podglądem.")),
        preview: { @MainActor ctx in
            let items = try ctx.targets()
            let plan = try await renamePlan(items, rule: try RenameRule(arguments: ctx.arguments))
            let problems = plan.filter { $0.problem != nil }
            return EffectPreview(
                summary: L10n.tr("Zmiana nazw: \(plan.filter(\.changes).count) z \(plan.count)"),
                operations: plan.filter(\.changes).map { PlannedOperation(kind: "rename", source: $0.source, destination: $0.source.parent?.appending($0.newName), conflict: $0.problem != nil) },
                fileCount: plan.count,
                conflicts: problems.map { "\($0.source.name): \($0.problem!)" })
        }
    ) { ctx in
        let items = try ctx.targets()
        if !ctx.isAgent, ctx.arguments.values.keys.allSatisfy({ $0 == "paths" }) {
            try ctx.requireUI().showMultiRename(items: items)
            return .ok
        }
        let plan = try await renamePlan(items, rule: try RenameRule(arguments: ctx.arguments))
        let problems = plan.filter { $0.problem != nil }
        let journal = ctx.workspace.journal, invoker = ctx.invoker
        let count = try await runBlocking(qos: .userInitiated) {
            try MultiRename.execute(plan, journal: journal, invoker: invoker, title: L10n.tr("Zmiana nazw (\(plan.count))"))
        }
        await ctx.tab.reload()
        let value: JSONValue = ["renamed": .int(Int64(count)), "skipped": .array(problems.map { .string("\($0.source.name): \($0.problem!)") })]
        return CommandResult(message: L10n.tr("Zmieniono nazwy: \(count), pominięto: \(problems.count)"), value: ctx.isAgent ? untrusted(value) : value)
    },

    Command(CommandDescriptor(
        id: "file.checksumCreate", title: L10n.tr("Utwórz sumy kontrolne…"), category: .file, tc: ["cmd+alt+k"],
        parameters: [pathsParam,
                     CommandParameter("algorithm", .string, L10n.tr("md5, sha1, sha256 (domyślnie)"), allowed: ChecksumAlgorithm.allCases.map(\.rawValue)),
                     CommandParameter("name", .string, L10n.tr("Nazwa pliku sum (domyślnie wg pierwszego elementu)")),
                     CommandParameter("write", .boolean, L10n.tr("Zapisz plik sum (domyślnie tak); false = tylko zwróć sumy"))],
        agent: .full, effect: .modifiesFiles, summary: L10n.tr("Liczy sumy MD5/SHA-1/SHA-256 plików i zapisuje je w pliku sum w bieżącym katalogu."))
    ) { ctx in
        let files = try ctx.targets().filter { $0.kind == .file }
        guard !files.isEmpty else { throw CommandError.nothingSelected }
        let algorithm = ctx.arguments.string("algorithm").flatMap(ChecksumAlgorithm.init(rawValue:)) ?? .sha256
        let base = files[0].path.parent ?? .root
        let pairs = try await runBlocking(qos: .userInitiated) {
            try files.map { f -> (String, String) in
                let rel = f.path.path.hasPrefix(base.path + "/") ? String(f.path.path.dropFirst(base.path.count + 1)) : f.path.path
                return (try Checksums.hash(f.path, algorithm: algorithm), rel)
            }
        }
        var message = pairs.map { "\($0.0)  \($0.1)" }.joined(separator: "\n")
        if ctx.arguments.bool("write") ?? true {
            let name = ctx.arguments.string("name") ?? ((files.count == 1 ? files[0].name : base.name) + "." + algorithm.fileExtension)
            try validateFileName(name)
            let target = base.appending(name)
            // Plik od razu z treścią (O_EXCL), a wpis dziennika z odciskiem po zapisie — cofnięcie widzi
            // plik niezmieniony i może go usunąć.
            let contents = Data(Checksums.format(pairs.map { (hash: $0.0, relativePath: $0.1) }).utf8)
            try await LocalFS().createFile(target, contents: contents)
            let batch = ctx.workspace.journal.beginBatch(title: L10n.tr("Nowy plik \(target.name)"), invoker: ctx.invoker)
            ctx.workspace.journal.record(.created(path: target, isDirectory: false), fingerprint: try? LocalFS().itemSync(at: target).fingerprint, in: batch)
            message += "\n→ " + target.path
            if target.parent == ctx.tab.path { await ctx.tab.reload() }
        }
        if !ctx.isAgent { ctx.ui?.showReport(title: algorithm.displayName, text: message) }
        return CommandResult(message: message, value: .array(pairs.map { ["hash": .string($0.0), "path": .string($0.1)] }))
    },

    Command(CommandDescriptor(
        id: "file.checksumVerify", title: L10n.tr("Sprawdź sumy kontrolne"), category: .file, tc: ["cmd+alt+shift+k"],
        parameters: [pathsParam], agent: .full, effect: .none,
        summary: L10n.tr("Sprawdza pliki wymienione w pliku sum (.md5, .sha1, .sha256)."))
    ) { ctx in
        let sumFiles = try ctx.targets().filter { ChecksumAlgorithm(fileExtension: $0.fileExtension) != nil }
        guard !sumFiles.isEmpty else { throw CommandError.notAvailable(L10n.tr("Zaznacz plik sum (.md5, .sha1, .sha256)")) }
        var lines: [String] = []
        var json: [JSONValue] = []
        let blocked = ctx.isAgent ? BlockedPaths(for: ctx.workspace) : nil
        for f in sumFiles {
            // Dla agenta wpis wskazujący zablokowany plik (np. `.ssh/id_ed25519` w pliku sum w `~`) to `invalid`
            // bez czytania pliku — `ok`/`mismatch`/`missing` byłyby wyrocznią treści i istnienia (SECURITY.md §4.5).
            let results = try await runBlocking(qos: .userInitiated) {
                try Checksums.verify(checksumFile: f.path, skip: { blocked?.isBlocked($0) ?? false })
            }
            for r in results {
                lines.append("\(r.status == .ok ? "✓" : "✕") \(r.status.rawValue)  \(r.path)")
                json.append(["path": .string(r.path), "status": .string(r.status.rawValue)])
            }
        }
        let bad = json.filter { $0["status"]?.stringValue != "ok" }.count
        let text = L10n.tr("Błędy: \(bad) z \(json.count)") + "\n" + lines.joined(separator: "\n")
        if !ctx.isAgent { ctx.ui?.showReport(title: L10n.tr("Weryfikacja sum"), text: text) }
        // Ścieżki wpisów pochodzą z pliku (SECURITY.md §4.6).
        return CommandResult(message: text, value: ctx.isAgent ? untrusted(.array(json)) : .array(json))
    },

    Command(
        CommandDescriptor(
            id: "file.split", title: L10n.tr("Podziel plik…"), category: .file, tc: ["cmd+alt+shift+s"],
            parameters: [CommandParameter("path", .path, L10n.tr("Plik (domyślnie pod kursorem)")),
                         CommandParameter("partSize", .string, required: true, L10n.tr("Rozmiar części, np. 100M, 4,7G, 1440K")),
                         CommandParameter("destination", .path, L10n.tr("Katalog części (domyślnie drugi panel)"))],
            agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Dzieli plik na części .001, .002… z plikiem .sha256 do kontroli.")),
        preview: { @MainActor ctx in
            let item = try splitSource(ctx)
            guard let size = parseSize(ctx.arguments.string("partSize") ?? ""), size > 0 else { throw CommandError.invalidArgument("partSize", "100M") }
            let parts = Int((item.size + size - 1) / size)
            return EffectPreview(summary: L10n.tr("Podział \(item.name) na \(parts) części po \(Format.bytes(size))"), fileCount: parts + 1, totalBytes: item.size)
        }
    ) { ctx in
        let item = try splitSource(ctx)
        let sizeText = try await ctx.text("partSize", title: L10n.tr("Podziel plik"), message: L10n.tr("Rozmiar części (np. 100M, 4,7G):"), default: "100M")
        guard let size = parseSize(sizeText), size > 0 else { throw CommandError.invalidArgument("partSize", sizeText) }
        let dest = ctx.arguments.path("destination", relativeTo: ctx.tab.path) ?? (ctx.otherTab.path.isLocal ? ctx.otherTab.path : item.path.parent!)
        let created = try await runBlocking(qos: .userInitiated) { try FileSplitter.split(item.path, partSize: size, into: dest) }
        let batch = ctx.workspace.journal.beginBatch(title: L10n.tr("Podział \(item.name)"), invoker: ctx.invoker)
        for p in created { ctx.workspace.journal.record(.created(path: p, isDirectory: false), fingerprint: try? LocalFS().itemSync(at: p).fingerprint, in: batch) }
        return CommandResult(message: L10n.tr("Utworzono \(created.count) plików"), value: .array(created.map { .string($0.path) }))
    },

    Command(
        CommandDescriptor(
            id: "file.join", title: L10n.tr("Połącz pliki…"), category: .file, tc: ["cmd+alt+shift+j"],
            parameters: [CommandParameter("path", .path, L10n.tr("Pierwsza część (.001)")),
                         CommandParameter("target", .path, L10n.tr("Plik wynikowy (domyślnie w drugim panelu, nazwa bez .001)"))],
            agent: .approval, effect: .modifiesFiles, summary: L10n.tr("Łączy części .001, .002… w jeden plik i sprawdza sumę, jeśli jest plik .sha256.")),
        preview: { @MainActor ctx in
            let (parts, target) = try joinPlan(ctx)
            return EffectPreview(summary: L10n.tr("Połączenie \(parts.count) części → \(target.path)"),
                                 operations: [PlannedOperation(kind: "join", source: parts.first, destination: target)], fileCount: 1)
        }
    ) { ctx in
        let (parts, target) = try joinPlan(ctx)
        let verified = try await runBlocking(qos: .userInitiated) { try FileSplitter.join(parts, into: target) }
        let batch = ctx.workspace.journal.beginBatch(title: L10n.tr("Połączenie \(target.name)"), invoker: ctx.invoker)
        ctx.workspace.journal.record(.created(path: target, isDirectory: false), fingerprint: try? LocalFS().itemSync(at: target).fingerprint, in: batch)
        let status = verified.map { $0 ? L10n.tr("suma zgodna") : L10n.tr("SUMA NIEZGODNA") } ?? L10n.tr("bez pliku sum")
        if verified == false { ctx.ui?.showError(L10n.tr("Połączony plik ma inną sumę SHA-256 niż oryginał: \(target.path)")) }
        return CommandResult(message: "\(target.path) — \(status)", value: ["path": .string(target.path), "verified": verified.map { .bool($0) } ?? .null])
    },
] }

@MainActor
private func splitSource(_ ctx: CommandContext) throws -> FileItem {
    let path = ctx.arguments.path("path", relativeTo: ctx.tab.path) ?? ctx.tab.cursorItem?.path
    guard let path, let item = try? LocalFS().itemSync(at: path), item.kind == .file else { throw CommandError.nothingSelected }
    return item
}

@MainActor
private func joinPlan(_ ctx: CommandContext) throws -> ([VFSPath], VFSPath) {
    let first = ctx.arguments.path("path", relativeTo: ctx.tab.path) ?? ctx.tab.cursorItem?.path
    guard let first else { throw CommandError.nothingSelected }
    let parts = FileSplitter.parts(startingWith: first)
    guard parts.count > 1 || first.name.fileExtension == "001" else { throw CommandError.notAvailable(L10n.tr("Wybierz pierwszą część (.001)")) }
    let defaultDir = ctx.otherTab.path.isLocal ? ctx.otherTab.path : first.parent!
    let target = ctx.arguments.path("target", relativeTo: ctx.tab.path) ?? defaultDir.appending(first.name.fileStem)
    return (parts, target)
}

extension SearchCriteria {
    func with(_ change: (inout SearchCriteria) -> Void) -> SearchCriteria {
        var copy = self
        change(&copy)
        return copy
    }
}
