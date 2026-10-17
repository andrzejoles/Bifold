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

    /// Warunki niezależne od treści.
    func matchesMetadata(_ item: FileItem) -> Bool {
        if !includeHidden && item.isHidden { return false }
        switch kind {
        case .any: break
        case .files: if item.isNavigable { return false }
        case .directories: if !item.isNavigable { return false }
        }
        if !nameRegex.isEmpty {
            guard NameRegex(nameRegex, caseInsensitive: !caseSensitive).matches(item.name) else { return false }
        } else if !nameMask.isEmpty, !NameMask(nameMask).matches(item) {
            return false
        }
        if let a = modifiedAfter, (item.modified ?? .distantPast) < a { return false }
        if let b = modifiedBefore, (item.modified ?? .distantFuture) > b { return false }
        if let min = minSize, item.isNavigable || item.size < min { return false }
        if let max = maxSize, item.isNavigable || item.size > max { return false }
        return true
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
    public static func search(_ criteria: SearchCriteria, ripgrep: String?) -> AsyncStream<SearchEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let flag = CancellationFlag()
            let thread = Thread {
                if criteria.hasContentSearch {
                    guard let ripgrep else {
                        continuation.yield(.failed(L10n.tr("Wyszukiwanie w treści wymaga ripgrep (brew install ripgrep)")))
                        continuation.finish()
                        return
                    }
                    runRipgrep(criteria, executable: ripgrep, flag: flag, continuation: continuation)
                } else {
                    walk(criteria, flag: flag, continuation: continuation)
                }
                continuation.finish()
            }
            thread.name = "bifold.search"
            continuation.onTermination = { _ in flag.cancel() }
            thread.start()
        }
    }

    /// Zbiera wszystkie wyniki (testy, agent).
    public static func collect(_ criteria: SearchCriteria, ripgrep: String?) async throws -> (hits: [SearchHit], truncated: Bool) {
        var hits: [SearchHit] = []
        var truncated = false
        for await event in search(criteria, ripgrep: ripgrep) {
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

    static func walk(_ c: SearchCriteria, flag: CancellationFlag, continuation: AsyncStream<SearchEvent>.Continuation) {
        let fs = LocalFS()
        var count = 0
        var scanned = 0
        var stack = c.roots.reversed().map { $0 }
        while let dir = stack.popLast() {
            if flag.isCancelled { break }
            guard let items = try? fs.listSync(dir) else { continue }
            scanned += 1
            if scanned % 50 == 0 { continuation.yield(.progress(scannedDirectories: scanned, current: dir.path)) }
            for item in items {
                if c.matchesMetadata(item) {
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

    static func runRipgrep(_ c: SearchCriteria, executable: String, flag: CancellationFlag, continuation: AsyncStream<SearchEvent>.Continuation) {
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
        let fs = LocalFS()
        var current: (path: String, matches: [SearchHit.LineMatch])?
        var count = 0
        var truncated = false
        var buffer = Data()
        let handle = out.fileHandleForReading

        func flush() {
            guard let cur = current else { return }
            current = nil
            guard let item = try? fs.itemSync(at: .local(cur.path)), c.matchesMetadata(item) else { return }
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
