import Foundation

/// Kryteria wyszukiwania (Alt+F7). Wszystkie warunki muszą być spełnione.
public struct SearchCriteria: Codable, Sendable, Hashable {
    public var roots: [VFSPath]
    /// Maska nazw TC (`*.txt;*.md|*.bak`); pusta = wszystko.
    public var nameMask: String
    /// Wyrażenie regularne na nazwie (zamiast maski, gdy niepuste).
    public var nameRegex: String
    public var recursive: Bool
    public var includeHidden: Bool
    /// Tekst w treści (ripgrep). Pusty = bez przeszukiwania treści.
    public var contentText: String
    public var contentIsRegex: Bool
    public var caseSensitive: Bool
    /// Kodowanie dla ripgrep (`auto`, `utf-8`, `windows-1250`, `iso-8859-2`, `utf-16le`…).
    public var encoding: String
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var minSize: Int64?
    public var maxSize: Int64?
    public var kind: KindFilter
    public var maxResults: Int
    /// Szukaj nazw także wewnątrz archiwów (ścieżka 7zz); trafienie = plik archiwum + ścieżki wpisów.
    public var archiveTool: String?

    public enum KindFilter: String, Codable, Sendable, CaseIterable { case any, files, directories }

    public init(
        roots: [VFSPath], nameMask: String = "", nameRegex: String = "", recursive: Bool = true, includeHidden: Bool = false,
        contentText: String = "", contentIsRegex: Bool = false, caseSensitive: Bool = false, encoding: String = "auto",
        modifiedAfter: Date? = nil, modifiedBefore: Date? = nil, minSize: Int64? = nil, maxSize: Int64? = nil,
        kind: KindFilter = .any, maxResults: Int = 50_000
    ) {
        self.roots = roots
        self.nameMask = nameMask
        self.nameRegex = nameRegex
        self.recursive = recursive
        self.includeHidden = includeHidden
        self.contentText = contentText
        self.contentIsRegex = contentIsRegex
        self.caseSensitive = caseSensitive
        self.encoding = encoding
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.minSize = minSize
        self.maxSize = maxSize
        self.kind = kind
        self.maxResults = maxResults
    }

    var hasContentSearch: Bool { !contentText.isEmpty }
}

/// Warunki niezależne od treści z maską/wyrażeniem skompilowanym raz na całe wyszukiwanie
/// (wcześniej kompilowane dla każdego pliku).
struct MetadataMatcher {
    let criteria: SearchCriteria
    private let regex: NameRegex?
    private let mask: NameMask?

    init(_ criteria: SearchCriteria) {
        self.criteria = criteria
        regex = criteria.nameRegex.isEmpty ? nil : NameRegex(criteria.nameRegex, caseInsensitive: !criteria.caseSensitive)
        mask = criteria.nameRegex.isEmpty && !criteria.nameMask.isEmpty ? NameMask(criteria.nameMask) : nil
    }

    func matches(_ item: FileItem) -> Bool {
        let c = criteria
        if !c.includeHidden && item.isHidden { return false }
        switch c.kind {
        case .any: break
        case .files: if item.isNavigable { return false }
        case .directories: if !item.isNavigable { return false }
        }
        if let regex, !regex.matches(item.name) { return false }
        if let mask, !mask.matches(item) { return false }
        if let a = c.modifiedAfter, (item.modified ?? .distantPast) < a { return false }
        if let b = c.modifiedBefore, (item.modified ?? .distantFuture) > b { return false }
        if let min = c.minSize, item.isNavigable || item.size < min { return false }
        if let max = c.maxSize, item.isNavigable || item.size > max { return false }
        return true
    }
}

/// Ścieżki, których wyszukiwanie nie czyta, nie pokazuje i nie liczy (zablokowane dla agenta) — jak `skip`
/// w `Checksums.verify`. Filtrowanie dopiero listy wyników zostawiało wyrocznię: zablokowane trafienia
/// zwiększały licznik, więc `truncated` przy `maxResults: 1` zdradzał treść i nazwy zablokowanych plików.
public struct SearchExclusion: Sendable {
    /// Ścieżka wykluczona razem z całym poddrzewem.
    public let isExcluded: @Sendable (VFSPath) -> Bool
    /// Katalog, w którego poddrzewie leży ścieżka wykluczona (albo który sam nią jest).
    public let containsExcluded: @Sendable (VFSPath) -> Bool

    public init(isExcluded: @escaping @Sendable (VFSPath) -> Bool, containsExcluded: @escaping @Sendable (VFSPath) -> Bool) {
        self.isExcluded = isExcluded
        self.containsExcluded = containsExcluded
    }

    public static let none = SearchExclusion(isExcluded: { _ in false }, containsExcluded: { _ in false })
}

/// Proces `rg` bieżącego wyszukiwania — anulowanie kończy go od razu, a nie dopiero przy
/// następnym wierszu wyniku (rg potrafi długo milczeć na dużych plikach).
final class ProcessSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    /// Zapamiętuje uruchomiony proces; jeśli wyszukiwanie już anulowano — kończy go od razu.
    func set(_ p: Process) {
        let stop = lock.withLock { () -> Bool in
            process = p
            return stopped
        }
        if stop { p.terminate() }
    }

    func terminate() {
        let p = lock.withLock { () -> Process? in
            stopped = true
            return process
        }
        if let p, p.isRunning { p.terminate() }
    }
}

/// Wynik wyszukiwania: element i (dla wyszukiwania w treści) pasujące wiersze.
public struct SearchHit: Sendable, Hashable, Identifiable {
    public var id: VFSPath { item.path }
    public var item: FileItem
    public var matches: [LineMatch]

    public init(item: FileItem, matches: [LineMatch] = []) {
        self.item = item
        self.matches = matches
    }

    public struct LineMatch: Sendable, Hashable, Codable {
        public var line: Int
        public var text: String
    }
}

public enum SearchEvent: Sendable {
    case hit(SearchHit)
    case progress(scannedDirectories: Int, current: String)
    case finished(total: Int, truncated: Bool)
    case failed(String)
}

/// Wyszukiwanie po nazwie i atrybutach (własny przegląd katalogów) oraz w treści (ripgrep).
public enum SearchEngine {
    public static func search(_ criteria: SearchCriteria, ripgrep: String?, exclusion: SearchExclusion = .none) -> AsyncStream<SearchEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let flag = CancellationFlag()
            let slot = ProcessSlot()
            let thread = Thread {
                if criteria.hasContentSearch {
                    guard let ripgrep else {
                        continuation.yield(.failed(L10n.tr("Wyszukiwanie w treści wymaga ripgrep (brew install ripgrep)")))
                        continuation.finish()
                        return
                    }
                    runRipgrep(criteria, executable: ripgrep, exclusion: exclusion, flag: flag, slot: slot, continuation: continuation)
                } else {
                    walk(criteria, exclusion: exclusion, flag: flag, continuation: continuation)
                }
                continuation.finish()
            }
            thread.name = "bifold.search"
            continuation.onTermination = { _ in
                flag.cancel()
                slot.terminate()
            }
            thread.start()
        }
    }

    /// Zbiera wszystkie wyniki (testy, agent).
    public static func collect(_ criteria: SearchCriteria, ripgrep: String?, exclusion: SearchExclusion = .none) async throws -> (hits: [SearchHit], truncated: Bool) {
        var hits: [SearchHit] = []
        var truncated = false
        for await event in search(criteria, ripgrep: ripgrep, exclusion: exclusion) {
            switch event {
            case .hit(let h): hits.append(h)
            case .finished(_, let t): truncated = t
            case .failed(let m): throw SearchError.failed(m)
            case .progress: break
            }
        }
        return (hits, truncated)
    }

    public enum SearchError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case .failed(let m) = self { m } else { nil } }
    }

    static func walk(_ c: SearchCriteria, exclusion: SearchExclusion = .none, flag: CancellationFlag, continuation: AsyncStream<SearchEvent>.Continuation) {
        let fs = LocalFS()
        let matcher = MetadataMatcher(c)
        var count = 0
        var scanned = 0
        var stack = c.roots.reversed().map { $0 }
        while let dir = stack.popLast() {
            if flag.isCancelled { break }
            if exclusion.isExcluded(dir) { continue }
            guard let items = try? fs.listSync(dir) else { continue }
            scanned += 1
            if scanned % 50 == 0 { continuation.yield(.progress(scannedDirectories: scanned, current: dir.path)) }
            // Dziecko katalogu bez wykluczeń w poddrzewie może być wykluczone tylko jako dowiązanie.
            let guarded = exclusion.containsExcluded(dir)
            for item in items {
                if flag.isCancelled { break }
                // Wykluczony element nie jest liczony, czytany (archiwum) ani przeglądany w głąb.
                if guarded || item.kind == .symlink, exclusion.isExcluded(item.path) { continue }
                if let tool = c.archiveTool, item.kind == .file, ArchiveFS.isArchive(item.name),
                   let entries = try? SevenZip(executable: tool).list(item.path, password: nil, isCancelled: { flag.isCancelled }) {
                    let matching = entries.filter { e in
                        let name = (e.path as NSString).lastPathComponent
                        let probe = FileItem(path: .local("/" + e.path), name: name, kind: e.isDirectory ? .directory : .file, size: e.size, modified: e.modified)
                        return matcher.matches(probe)
                    }
                    if !matching.isEmpty {
                        continuation.yield(.hit(SearchHit(item: item, matches: matching.prefix(20).map { .init(line: 0, text: "📦 " + $0.path) })))
                        count += 1
                    }
                }
                if matcher.matches(item) {
                    continuation.yield(.hit(SearchHit(item: item, matches: [])))
                    count += 1
                    if count >= c.maxResults {
                        continuation.yield(.finished(total: count, truncated: true))
                        return
                    }
                }
                // Nie wchodzimy w dowiązania (pętle) ani w ukryte katalogi, gdy pomijamy ukryte.
                if c.recursive, item.kind == .directory, c.includeHidden || !item.isHidden {
                    stack.append(item.path)
                }
            }
        }
        continuation.yield(.finished(total: count, truncated: false))
    }

    /// Argumenty ripgrep (osobno, żeby dało się je testować). Wzorzec idzie przez plik
    /// (`--file`), bo `Process` zamienia argumenty na postać NFD i „gęślą” przestałoby pasować.
    static func ripgrepArguments(_ c: SearchCriteria, patternFile: String = "<wzorzec>") -> [String] {
        var args = ["--json", "--no-config", "--max-columns", "300", "--max-columns-preview", "--no-messages"]
        if !c.caseSensitive { args.append("--ignore-case") }
        if !c.contentIsRegex { args.append("--fixed-strings") }
        if c.includeHidden { args.append("--hidden") }
        if !c.recursive { args += ["--max-depth", "1"] }
        args += ["--no-ignore"]
        if c.encoding != "auto", !c.encoding.isEmpty { args += ["--encoding", c.encoding] }
        if c.nameRegex.isEmpty, !c.nameMask.isEmpty {
            // Maska TC → globy ripgrep (wykluczenia jako !glob).
            let parts = c.nameMask.split(separator: "|", maxSplits: 1).map(String.init)
            let sep: Character = c.nameMask.contains(";") ? ";" : " "
            for g in (parts.first ?? "").split(separator: sep).map({ $0.trimmingCharacters(in: .whitespaces) }) where !g.isEmpty && g != "*" && g != "*.*" {
                args += ["--iglob", g]
            }
            if parts.count > 1 {
                for g in parts[1].split(separator: sep).map({ $0.trimmingCharacters(in: .whitespaces) }) where !g.isEmpty {
                    args += ["--iglob", "!" + g]
                }
            }
        }
        args += ["--file", patternFile, "--"]
        args += c.roots.map(\.path)
        return args
    }

    /// Ścieżki dla `rg`: korzeń z wykluczeniem w poddrzewie jest rozpisywany na rodzeństwo wykluczonych
    /// elementów (wzdłuż ścieżki do nich), więc `rg` nigdy nie otwiera wykluczonego pliku — bez polegania
    /// na semantyce globów względem korzenia, wielkości liter i dowiązań. Tak jak `rg` przy przeglądaniu:
    /// bez dowiązań i (bez `includeHidden`) bez ukrytych; pliki podane wprost `rg` czyta mimo `--iglob`,
    /// więc przechodzą przez warunki nazwy i atrybutów.
    static func ripgrepRoots(_ c: SearchCriteria, exclusion: SearchExclusion) -> [String] {
        let fs = LocalFS()
        let matcher = MetadataMatcher(c)
        var out: [String] = []
        func expand(_ dir: VFSPath) {
            guard let items = try? fs.listSync(dir) else { return }
            for item in items {
                if exclusion.isExcluded(item.path) || item.kind == .symlink { continue }
                if !c.includeHidden && item.isHidden { continue }
                if item.kind == .directory {
                    guard c.recursive else { continue }
                    if exclusion.containsExcluded(item.path) { expand(item.path) } else { out.append(item.path.path) }
                } else if item.kind == .file, matcher.matches(item) {
                    out.append(item.path.path)
                }
            }
        }
        for root in c.roots where !exclusion.isExcluded(root) {
            if exclusion.containsExcluded(root) { expand(root) } else { out.append(root.path) }
        }
        return out
    }

    static func runRipgrep(_ c: SearchCriteria, executable: String, exclusion: SearchExclusion = .none, flag: CancellationFlag,
                           slot: ProcessSlot = ProcessSlot(), continuation: AsyncStream<SearchEvent>.Continuation) {
        var c = c
        c.roots = ripgrepRoots(c, exclusion: exclusion).map { VFSPath.local($0) }
        // Bez ścieżek `rg` przeszukałby bieżący katalog procesu.
        guard !c.roots.isEmpty else {
            continuation.yield(.finished(total: 0, truncated: false))
            return
        }
        let patternURL = FileManager.default.temporaryDirectory.appending(path: "bifold-rg-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: patternURL.path, contents: Data(c.contentText.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: patternURL) }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = ripgrepArguments(c, patternFile: patternURL.path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            continuation.yield(.failed(error.localizedDescription))
            return
        }
        slot.set(process)
        if flag.isCancelled { slot.terminate() }
        let fs = LocalFS()
        let matcher = MetadataMatcher(c)
        var current: (path: String, matches: [SearchHit.LineMatch])?
        var count = 0
        var truncated = false
        var buffer = Data()
        let handle = out.fileHandleForReading

        func flush() {
            guard let cur = current else { return }
            current = nil
            guard !exclusion.isExcluded(.local(cur.path)), let item = try? fs.itemSync(at: .local(cur.path)), matcher.matches(item) else { return }
            continuation.yield(.hit(SearchHit(item: item, matches: cur.matches)))
            count += 1
        }

        reading: while true {
            if flag.isCancelled || count >= c.maxResults {
                truncated = count >= c.maxResults
                process.terminate()
                break
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = obj["type"] as? String, let data = obj["data"] as? [String: Any] else { continue }
                let path = ((data["path"] as? [String: Any])?["text"] as? String)
                switch type {
                case "begin":
                    flush()
                    if let path { current = (path, []) }
                case "match":
                    let text = ((data["lines"] as? [String: Any])?["text"] as? String ?? "").trimmingCharacters(in: .newlines)
                    let number = data["line_number"] as? Int ?? 0
                    if current?.matches.count ?? 0 < 20 { current?.matches.append(.init(line: number, text: String(text.prefix(300)))) }
                case "end":
                    flush()
                    if count >= c.maxResults { continue reading }
                default:
                    break
                }
            }
        }
        flush()
        process.waitUntilExit()
        continuation.yield(.finished(total: count, truncated: truncated))
    }
}
