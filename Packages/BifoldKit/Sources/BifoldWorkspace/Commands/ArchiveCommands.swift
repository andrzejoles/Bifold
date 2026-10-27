import BifoldCore
import Foundation

extension Workspace {
    /// `7zz` z katalogu narzędzi (ustawienia) albo błąd z instrukcją instalacji.
    public func sevenZip() throws -> SevenZip {
        guard let path = settings.toolPath("7zz") else { throw ArchiveError.toolMissing }
        return SevenZip(executable: path)
    }

    /// Otwiera archiwum jako dostawcę. Hasło pyta tylko użytkownik (agent nigdy).
    public func openArchive(_ archive: VFSPath, invoker: Invoker) async throws -> ArchiveFS {
        let tool = try sevenZip()
        do {
            let fs = try await runBlocking(qos: .userInitiated) { try ArchiveFS(archive: archive, tool: tool) }
            if fs.isEncrypted && !invoker.isAgent {
                // Nagłówki jawne, ale pliki zaszyfrowane — hasło potrzebne do podglądu i kopiowania.
                if let pw = await ui?.promptPassword(title: L10n.tr("Hasło do archiwum „\(archive.name)”")) {
                    return try await runBlocking(qos: .userInitiated) { try ArchiveFS(archive: archive, tool: tool, password: pw) }
                }
            }
            return fs
        } catch ArchiveError.passwordRequired {
            guard !invoker.isAgent else { throw ArchiveError.passwordRequired }
            guard let pw = await ui?.promptPassword(title: L10n.tr("Hasło do archiwum „\(archive.name)”")) else { throw CommandError.cancelledByUser }
            return try await runBlocking(qos: .userInitiated) { try ArchiveFS(archive: archive, tool: tool, password: pw) }
        }
    }

    /// Wejście do archiwum w karcie.
    public func enterArchive(_ archive: VFSPath, in tab: Tab, invoker: Invoker = .user) async throws {
        let fs = try await openArchive(archive, invoker: invoker)
        registerEphemeral(fs)
        defer { unpinEphemeral(fs.id) }
        // Tytuł „📦 …” wylicza karta — przy wygranej nowszej nawigacji (D47) nie trafia do karty,
        // która jest już gdzie indziej.
        try await tab.navigate(to: fs.root)
    }

    /// Plik z archiwum, serwera albo telefonu skopiowany do katalogu tymczasowego (podgląd, Quick Look,
    /// edytor) — wynik ma zawsze ścieżkę lokalną. Katalogów (i dowiązań do katalogów) spoza dysku lokalnego
    /// nie kopiuje — inaczej podgląd pobierał całe drzewo z serwera albo telefonu bez limitu.
    /// - Parameter removeOnExit: katalog tymczasowy jest usuwany przy zamykaniu aplikacji (`saveSession`);
    ///   `false` dla plików otwieranych do edycji (F4) — edytor może je trzymać dłużej niż Bifold. Kopie
    ///   starsze niż doba usuwa `start()` przy kolejnym uruchomieniu.
    public func materialize(_ item: FileItem, removeOnExit: Bool = true) async throws -> FileItem {
        if item.path.isLocal { return item }
        guard !item.isNavigable else {
            throw CommandError.notAvailable(L10n.tr("Katalogu spoza dysku lokalnego nie można otworzyć jak pliku"))
        }
        let provider = try providers.provider(for: item.path)
        if let remote = provider as? any RemoteFileProvider {
            let url = try await remote.download(item.path)
            // Pobranie trafia do własnego katalogu (`bifold-remote-…`, `.bifold-scp-…`) — tylko taki usuwamy.
            let dir = url.deletingLastPathComponent()
            if removeOnExit, dir.lastPathComponent.hasPrefix("bifold-remote-") || dir.lastPathComponent.hasPrefix(".bifold-scp-") {
                temporaryViewDirectories.insert(dir)
            }
            return try LocalFS().itemSync(at: .local(url))
        }
        let archive = provider as? ArchiveFS, device = provider as? any ExtractingProvider
        guard archive != nil || device != nil else { throw VFSError.unsupported(item.path.description) }
        let dir = FileManager.default.temporaryDirectory.appending(path: Self.viewCopyPrefix + UUID().uuidString.prefix(8), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Przy błędzie albo anulowaniu katalog tymczasowy nie zostaje.
        do {
            let path = item.path, target = VFSPath.local(dir.path)
            let flag = CancellationFlag()
            let local: VFSPath = try await withTaskCancellationHandler {
                try await runBlocking(qos: .userInitiated) { () throws -> VFSPath in
                    if let archive {
                        // Rozpakowanie jednego wpisu wprost do pliku (bez wczytywania go całego do pamięci).
                        return try archive.extractFile(path, to: target, isCancelled: { flag.isCancelled })
                    }
                    // Telefon (AFC/MTP): kopia przez katalog tymczasowy jak przy kopiowaniu F5.
                    let (_, extracted) = try device!.extract([path], toTemporaryIn: target, isCancelled: { flag.isCancelled })
                    guard let local = extracted.first, local.isLocal else { throw VFSError.notFound(path) }
                    return local
                }
            } onCancel: {
                flag.cancel()
            }
            try Task.checkCancellation()
            let result = try LocalFS().itemSync(at: local)
            if removeOnExit { temporaryViewDirectories.insert(dir) }
            return result
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Przedrostek katalogów tymczasowych kopii do podglądu.
    nonisolated static let viewCopyPrefix = "bifold-view-"

    /// Usuwa katalogi tymczasowe kopii do podglądu z tej sesji (przy zamykaniu aplikacji).
    public func removeTemporaryViewCopies() {
        for dir in temporaryViewDirectories { try? FileManager.default.removeItem(at: dir) }
        temporaryViewDirectories = []
    }

    /// Usuwa pozostałości po wcześniejszych uruchomieniach: tylko własne katalogi `bifold-view-…` starsze
    /// niż `age` (plik otwarty do edycji z poprzedniej sesji ma dobę, zanim zniknie).
    nonisolated static func removeStaleViewCopies(in directory: URL, olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(viewCopyPrefix) {
            let url = directory.appending(path: name, directoryHint: .isDirectory)
            var st = stat()
            // Bez podążania za dowiązaniami: tylko prawdziwe katalogi o naszej nazwie i naszym właścicielu.
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
        }
    }
}

let archiveFormatParam = CommandParameter("format", .string, L10n.tr("Format archiwum"), allowed: ArchiveFormat.allCases.map(\.rawValue))

@MainActor
var archiveCommands: [Command] { [
    Command(
        CommandDescriptor(
            id: "archive.create", title: L10n.tr("Spakuj…"), category: .file, tc: ["alt+f5"], cmd: ["cmd+alt+5"],
            parameters: [
                pathsParam,
                CommandParameter("destination", .path, L10n.tr("Ścieżka archiwum (domyślnie w drugim panelu, nazwa wg zaznaczenia)")),
                archiveFormatParam,
                CommandParameter("level", .integer, L10n.tr("Stopień kompresji 0–9 (domyślnie 5)")),
                CommandParameter("volumeSize", .string, L10n.tr("Archiwum wieloczęściowe: rozmiar części, np. 100m, 4g")),
            ],
            agent: .approval, effect: .modifiesFiles,
            summary: L10n.tr("Tworzy archiwum ZIP, 7z, TAR, TAR.GZ/BZ2/XZ albo GZ/BZ2/XZ (także wieloczęściowe). Archiwa z hasłem tworzy tylko użytkownik.")),
        preview: { @MainActor ctx in
            let (archive, format, base, names, _) = try await archiveRequest(ctx, interactive: false)
            return EffectPreview(
                summary: L10n.tr("Pakowanie \(names.count) elementów do \(archive.path) (\(format.rawValue))"),
                operations: [PlannedOperation(kind: "archive", source: base, destination: archive)], fileCount: names.count,
                conflicts: FileManager.default.fileExists(atPath: archive.path) ? [archive.path] : [])
        }
    ) { ctx in
        let (archive, format, base, names, password) = try await archiveRequest(ctx, interactive: !ctx.isAgent)
        let tool = try ctx.workspace.sevenZip()
        let job = ctx.workspace.jobs.enqueue(
            .createArchive(archive, format: format, base: base, names: names, tool: tool,
                           level: Int(ctx.arguments.int("level") ?? 5), password: password, volumeSize: ctx.arguments.string("volumeSize")),
            title: L10n.tr("Pakowanie \(archive.name)"), invoker: ctx.invoker)
        if ctx.arguments["paths"] == nil { ctx.tab.clearSelection() }
        let state = await ctx.workspace.jobs.wait(for: job)
        if case .failed(let why) = state { throw CommandError.notAvailable(why) }
        return CommandResult(message: archive.path, value: ["archive": .string(archive.path), "state": .string("\(state)")])
    },

    Command(
        CommandDescriptor(
            id: "archive.extract", title: L10n.tr("Rozpakuj…"), category: .file, tc: ["alt+f9"], cmd: ["cmd+alt+9"],
            parameters: [
                pathsParam,
                CommandParameter("destination", .path, L10n.tr("Katalog docelowy (domyślnie drugi panel)")),
                CommandParameter("conflict", .string, L10n.tr("skip (domyślnie), overwrite, rename"), allowed: ["skip", "overwrite", "rename"]),
                CommandParameter("subfolders", .boolean, L10n.tr("Każde archiwum do podkatalogu o jego nazwie (domyślnie tak)")),
            ],
            agent: .approval, effect: .modifiesFiles,
            summary: L10n.tr("Rozpakowuje archiwa (ZIP, 7z, RAR, TAR, GZ, BZ2, XZ, wieloczęściowe). Archiwa z hasłem — tylko użytkownik.")),
        preview: { @MainActor ctx in
            let archives = try ctx.targets().filter { ArchiveFS.isArchive($0.name) }
            let dest = try extractDestination(ctx, archives: archives)
            return EffectPreview(
                summary: L10n.tr("Rozpakowanie \(archives.count) archiwów do \(dest.path)"),
                operations: archives.map { PlannedOperation(kind: "extract", source: $0.path, destination: dest, bytes: $0.size) },
                fileCount: archives.count, totalBytes: archives.reduce(0) { $0 + $1.size })
        }
    ) { ctx in
        let archives = try ctx.targets().filter { ArchiveFS.isArchive($0.name) }
        guard !archives.isEmpty else { throw CommandError.notAvailable(L10n.tr("Zaznacz archiwa")) }
        var dest = try extractDestination(ctx, archives: archives)
        if !ctx.isAgent && ctx.arguments["destination"] == nil {
            let text = try await ctx.text("destination", title: L10n.tr("Rozpakuj \(Format.describe(archives)) do:"), default: dest.path + "/")
            dest = resolvePath(text, relativeTo: ctx.tab.path)
        }
        guard dest.isLocal else { throw CommandError.notAvailable(L10n.tr("Katalog docelowy musi być lokalny")) }
        try FileManager.default.createDirectory(atPath: dest.path, withIntermediateDirectories: true)
        let overwrite: SevenZip.Overwrite = switch ctx.arguments.string("conflict") {
        case "overwrite": .overwrite
        case "rename": .rename
        default: .skip
        }
        let tool = try ctx.workspace.sevenZip()
        let job = ctx.workspace.jobs.enqueue(
            .extractArchives(archives.map(\.path), destination: dest, tool: tool, overwrite: overwrite, subfolders: ctx.arguments.bool("subfolders") ?? true),
            title: L10n.tr("Rozpakowywanie \(Format.describe(archives))"), invoker: ctx.invoker)
        let state = await ctx.workspace.jobs.wait(for: job)
        // Błędy zawierają nazwy wpisów archiwum (SECURITY.md §4.6).
        let value: JSONValue = ["destination": .string(dest.path), "state": .string("\(state)"), "errors": .array(job.errors.map { .string($0) })]
        return CommandResult(message: job.errors.isEmpty ? dest.path : job.errors.joined(separator: "\n"),
                             value: ctx.isAgent ? untrusted(value) : value)
    },

    Command(CommandDescriptor(
        id: "archive.test", title: L10n.tr("Testuj archiwum"), category: .file, tc: ["cmd+alt+shift+t"],
        parameters: [pathsParam], agent: .read, effect: .none, summary: L10n.tr("Sprawdza spójność archiwów (7zz t)."))
    ) { ctx in
        let archives = try ctx.targets().filter { ArchiveFS.isArchive($0.name) }
        let tool = try ctx.workspace.sevenZip()
        var lines: [String] = []
        var json: [JSONValue] = []
        for a in archives {
            let ok = (try? await runBlocking(qos: .userInitiated) { try tool.test(a.path, password: nil) }) ?? false
            lines.append("\(ok ? "✓" : "✕") \(a.name)")
            json.append(["archive": .string(a.path.path), "ok": .bool(ok)])
        }
        if !ctx.isAgent { ctx.ui?.showReport(title: L10n.tr("Test archiwów"), text: lines.joined(separator: "\n")) }
        // Nazwy archiwów pochodzą z dysku (SECURITY.md §4.6).
        return CommandResult(message: lines.joined(separator: "\n"), value: ctx.isAgent ? untrusted(.array(json)) : .array(json))
    },

    Command(CommandDescriptor(
        id: "archive.list", title: L10n.tr("Zawartość archiwum"), category: .file,
        parameters: [CommandParameter("path", .path, required: true, L10n.tr("Plik archiwum")),
                     CommandParameter("limit", .integer, L10n.tr("Maks. liczba wpisów (domyślnie 2000)"))],
        agent: .read, effect: .none, summary: L10n.tr("Lista plików w archiwum (bez rozpakowywania; archiwa z hasłem niedostępne dla agenta)."), inMenu: false)
    ) { ctx in
        guard let path = ctx.arguments.path("path", relativeTo: ctx.tab.path) else { throw CommandError.missingArgument("path") }
        let tool = try ctx.workspace.sevenZip()
        let entries = try await runBlocking(qos: .userInitiated) { try tool.list(path, password: nil) }
        let limit = Int(max(0, ctx.arguments.int("limit") ?? 2000))
        let value: JSONValue = [
            "archive": .string(path.path), "total": .int(Int64(entries.count)),
            "entries": .array(entries.prefix(limit).map { e in
                ["path": .string(e.path), "directory": .bool(e.isDirectory), "size": .int(e.size), "encrypted": .bool(e.encrypted)]
            }),
        ]
        // Nazwy wpisów pochodzą z pliku archiwum (SECURITY.md §4.6).
        return CommandResult(value: ctx.isAgent ? untrusted(value) : value)
    },
] }

/// Katalog docelowy rozpakowania: argument albo drugi panel, jeśli jest lokalny. Drugi panel w archiwum,
/// na serwerze albo telefonie: agent dostaje błąd, użytkownik — katalog archiwum do poprawienia w oknie
/// (wcześniej wewnętrzna ścieżka, np. `/tmp` z SFTP, trafiała na dysk lokalny).
@MainActor
private func extractDestination(_ ctx: CommandContext, archives: [FileItem]) throws -> VFSPath {
    if let d = ctx.arguments.path("destination", relativeTo: ctx.tab.path) { return d }
    if ctx.otherTab.path.isLocal { return ctx.otherTab.path }
    guard !ctx.isAgent, let dir = archives.first?.path.parent, dir.isLocal else {
        throw CommandError.notAvailable(L10n.tr("Katalog docelowy musi być lokalny"))
    }
    return dir
}

@MainActor
private func archiveRequest(_ ctx: CommandContext, interactive: Bool) async throws -> (VFSPath, ArchiveFormat, VFSPath, [String], String?) {
    let items = try ctx.targets()
    guard let base = items.first?.path.parent, items.allSatisfy({ $0.path.parent == base }), base.isLocal else {
        throw CommandError.notAvailable(L10n.tr("Spakuj elementy z jednego katalogu lokalnego"))
    }
    var format = ctx.arguments.string("format").flatMap(ArchiveFormat.init(rawValue:)) ?? .zip
    let defaultName = (items.count == 1 ? items[0].name.fileStem : base.name)
    let destDir = ctx.otherTab.path.isLocal ? ctx.otherTab.path : base
    var archive = ctx.arguments.path("destination", relativeTo: base) ?? destDir.appending(defaultName + "." + format.fileExtension)
    var password: String?
    if interactive && ctx.arguments["destination"] == nil {
        let text = try await ctx.text("destination", title: L10n.tr("Spakuj \(Format.describe(items)) do:"),
                                      message: L10n.tr("Format wg rozszerzenia: .zip, .7z, .tar, .tar.gz, .tar.bz2, .tar.xz, .gz, .bz2, .xz"),
                                      default: archive.path, selectStem: false)
        archive = resolvePath(text, relativeTo: base)
        let lower = archive.name.lowercased()
        format = ArchiveFormat.allCases.sorted { $0.rawValue.count > $1.rawValue.count }.first { lower.hasSuffix("." + $0.rawValue) } ?? format
        if format.supportsPassword, let ui = ctx.ui,
           await ui.confirm(title: L10n.tr("Zabezpieczyć archiwum hasłem?"), message: L10n.tr("Hasło szyfruje zawartość (7z — także nazwy plików)."), confirmTitle: L10n.tr("Ustaw hasło"), destructive: false) {
            password = await ui.promptPassword(title: L10n.tr("Hasło do archiwum"))
        }
    }
    if format.isSingleStream, items.count != 1 || items[0].isNavigable {
        throw CommandError.notAvailable(L10n.tr("Formaty \(format.rawValue) kompresują jeden plik — użyj tar.\(format.rawValue)"))
    }
    return (archive, format, base, items.map(\.name), password)
}
