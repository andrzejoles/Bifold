import Foundation

/// Porównanie zawartości plików: tekst (Myers — `CollectionDifference`) i binarne (blokowe).
public enum FileCompare {
    public struct Line: Sendable, Hashable {
        public enum Kind: String, Sendable { case same, removed, added }
        public var kind: Kind
        /// Numery wierszy (od 1) w pliku lewym / prawym.
        public var left: Int?
        public var right: Int?
        public var text: String
    }

    public struct TextResult: Sendable {
        public var lines: [Line]
        public var removed: Int
        public var added: Int
        public var identical: Bool { removed == 0 && added == 0 }
    }

    public static func text(_ a: String, _ b: String) -> TextResult {
        let la = a.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lb = b.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diff = lb.difference(from: la)
        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removedAt.insert(offset)
            case let .insert(offset, _, _): insertedAt.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < la.count || j < lb.count {
            if i < la.count, removedAt.contains(i) {
                out.append(Line(kind: .removed, left: i + 1, right: nil, text: la[i]))
                i += 1
            } else if j < lb.count, insertedAt.contains(j) {
                out.append(Line(kind: .added, left: nil, right: j + 1, text: lb[j]))
                j += 1
            } else if i < la.count, j < lb.count {
                out.append(Line(kind: .same, left: i + 1, right: j + 1, text: la[i]))
                i += 1
                j += 1
            } else if i < la.count {
                out.append(Line(kind: .removed, left: i + 1, right: nil, text: la[i]))
                i += 1
            } else {
                out.append(Line(kind: .added, left: nil, right: j + 1, text: lb[j]))
                j += 1
            }
        }
        return TextResult(lines: out, removed: removedAt.count, added: insertedAt.count)
    }

    /// Format zunifikowany (diff -u) z kontekstem — dla agenta i do kopiowania.
    public static func unified(_ r: TextResult, leftName: String, rightName: String, context: Int = 3, maxLines: Int = 2000) -> String {
        var out = ["--- \(leftName)", "+++ \(rightName)"]
        let changed = r.lines.indices.filter { r.lines[$0].kind != .same }
        guard !changed.isEmpty else { return out.joined(separator: "\n") + "\n" }
        var groups: [ClosedRange<Int>] = []
        for idx in changed {
            let range = max(0, idx - context)...min(r.lines.count - 1, idx + context)
            if let last = groups.last, range.lowerBound <= last.upperBound + 1 {
                groups[groups.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                groups.append(range)
            }
        }
        for g in groups {
            let slice = r.lines[g]
            let l0 = slice.compactMap(\.left).first ?? 0, r0 = slice.compactMap(\.right).first ?? 0
            out.append("@@ -\(l0),\(slice.filter { $0.left != nil }.count) +\(r0),\(slice.filter { $0.right != nil }.count) @@")
            for line in slice {
                out.append((line.kind == .same ? " " : line.kind == .removed ? "-" : "+") + line.text)
                if out.count > maxLines { out.append("…"); return out.joined(separator: "\n") }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public struct BinaryResult: Sendable, Hashable {
        public var sizeA: Int64
        public var sizeB: Int64
        public var firstDifference: Int64?
        public var differingBytes: Int64
        public var identical: Bool { firstDifference == nil && sizeA == sizeB }
    }

    /// Porównanie blokami po 1 MB (pierwsze różniące się miejsce i liczba różnych bajtów).
    public static func binary(_ a: VFSPath, _ b: VFSPath, isCancelled: () -> Bool = { false }) throws -> BinaryResult {
        // Zwykłe pliki bez blokowania na FIFO (`LocalFS.openRegularFile`).
        let ha = FileHandle(fileDescriptor: try LocalFS.openRegularFile(a), closeOnDealloc: true)
        let hb = FileHandle(fileDescriptor: try LocalFS.openRegularFile(b), closeOnDealloc: true)
        defer { try? ha.close(); try? hb.close() }
        let sa = Int64((try? ha.seekToEnd()) ?? 0), sb = Int64((try? hb.seekToEnd()) ?? 0)
        try ha.seek(toOffset: 0)
        try hb.seek(toOffset: 0)
        var offset: Int64 = 0
        var first: Int64?
        var differing: Int64 = 0
        while true {
            if isCancelled() { throw VFSError.cancelled }
            let ca = try ha.read(upToCount: 1 << 20) ?? Data()
            let cb = try hb.read(upToCount: 1 << 20) ?? Data()
            if ca.isEmpty && cb.isEmpty { break }
            if ca != cb {
                let n = min(ca.count, cb.count)
                ca.withUnsafeBytes { pa in
                    cb.withUnsafeBytes { pb in
                        for k in 0..<n where pa[k] != pb[k] {
                            if first == nil { first = offset + Int64(k) }
                            differing += 1
                        }
                    }
                }
                if first == nil && ca.count != cb.count { first = offset + Int64(n) }
                differing += Int64(abs(ca.count - cb.count))
            }
            offset += Int64(max(ca.count, cb.count))
        }
        return BinaryResult(sizeA: sa, sizeB: sb, firstDifference: first, differingBytes: differing)
    }
}

/// Porównanie katalogów jak w TC: oznacza pliki unikalne po każdej stronie oraz nowsze
/// (albo — przy porównaniu treści — różne).
public enum DirectoryCompare {
    public struct Result: Sendable, Hashable {
        public var onlyLeft: [String]
        public var onlyRight: [String]
        public var newerLeft: [String]
        public var newerRight: [String]
        public var different: [String]
        public var identical: Int

        public var markLeft: Set<String> { Set(onlyLeft + newerLeft + different) }
        public var markRight: Set<String> { Set(onlyRight + newerRight + different) }
    }

    public static func compare(left: [FileItem], right: [FileItem], byContent: Bool = false) -> Result {
        let l = Dictionary(left.filter { $0.kind == .file }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let r = Dictionary(right.filter { $0.kind == .file }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var result = Result(onlyLeft: [], onlyRight: [], newerLeft: [], newerRight: [], different: [], identical: 0)
        for (name, a) in l {
            guard let b = r[name] else { result.onlyLeft.append(name); continue }
            if byContent {
                let same = a.size == b.size && a.path.isLocal && b.path.isLocal && ((try? FileCompare.binary(a.path, b.path).identical) ?? false)
                if same { result.identical += 1 } else { result.different.append(name) }
                continue
            }
            let ta = a.modified ?? .distantPast, tb = b.modified ?? .distantPast
            // Tolerancja 2 s (FAT, FTP zaokrąglają czasy).
            if abs(ta.timeIntervalSince(tb)) <= 2 && a.size == b.size {
                result.identical += 1
            } else if ta > tb {
                result.newerLeft.append(name)
            } else if tb > ta {
                result.newerRight.append(name)
            } else {
                result.different.append(name)
            }
        }
        result.onlyRight = r.keys.filter { l[$0] == nil }.sorted()
        result.onlyLeft.sort()
        result.newerLeft.sort()
        result.newerRight.sort()
        result.different.sort()
        return result
    }
}

// MARK: - Synchronizacja (rclone)

public enum SyncMode: String, Codable, Sendable, CaseIterable {
    /// Lustro: cel = źródło (kopiuje nowe/zmienione, usuwa nadmiarowe w celu).
    case mirror
    /// Aktualizacja: kopiuje nowe i zmienione ze źródła do celu, niczego nie usuwa.
    case update
    /// Dwukierunkowa: brakujące kopiowane w obie strony, przy różnicach wygrywa nowszy; bez usuwania.
    case twoWay

    public var displayName: String {
        switch self {
        case .mirror: L10n.tr("Lustro (źródło → cel, z usuwaniem)")
        case .update: L10n.tr("Aktualizacja (źródło → cel)")
        case .twoWay: L10n.tr("Dwukierunkowa (nowszy wygrywa)")
        }
    }
}

public struct SyncAction: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case copyToDestination, copyToSource, deleteFromDestination }
    public var id: String { kind.rawValue + ":" + path }
    public var kind: Kind
    /// Ścieżka względna wobec obu korzeni.
    public var path: String
    public var reason: String
    public var enabled: Bool = true
}

/// Plan synchronizacji — liczony „na sucho” (`operations/check` + listingi), przed jakąkolwiek zmianą.
public struct SyncPlan: Codable, Sendable, Hashable {
    public var sourceFs: String
    public var destinationFs: String
    public var mode: SyncMode
    public var actions: [SyncAction]
    public var identical: Int
    /// Korzenie lokalne (do dziennika i Kosza): nadpisywane/usuwane pliki lokalne idą do Kosza.
    public var localSource: VFSPath?
    public var localDestination: VFSPath?
}

public enum SyncPlanner {
    static func times(_ rclone: Rclone, _ fs: String) async throws -> [String: (Date?, Int64)] {
        let entries = try await rclone.list(fs: fs, remote: "", recursive: true, filesOnly: true)
        return Dictionary(entries.map { ($0.path, ($0.modified, $0.size)) }, uniquingKeysWith: { a, _ in a })
    }

    /// - Parameter byContent: porównanie sum kontrolnych (`operations/check`, czyta całe pliki);
    ///   domyślnie — jak w TC — rozmiar i data modyfikacji z listingów (szybko także dla dużych drzew).
    public static func plan(rclone: Rclone, sourceFs: String, destinationFs: String, mode: SyncMode, localSource: VFSPath?, localDestination: VFSPath?,
                            byContent: Bool = false) async throws -> SyncPlan {
        var missingOnDst: [String] = [], missingOnSrc: [String] = [], differ: [String] = []
        var identical = 0
        var st: [String: (Date?, Int64)] = [:], dt: [String: (Date?, Int64)] = [:]
        if byContent {
            let r = try await rclone.callAllowingFailure("operations/check", ["srcFs": sourceFs, "dstFs": destinationFs, "combined": true, "oneWay": false])
            missingOnDst = r["missingOnDst"] as? [String] ?? []
            missingOnSrc = r["missingOnSrc"] as? [String] ?? []
            differ = r["differ"] as? [String] ?? []
            identical = (r["combined"] as? [String] ?? []).filter { $0.hasPrefix("= ") }.count
        } else {
            st = try await times(rclone, sourceFs)
            dt = try await times(rclone, destinationFs)
            for (path, (ma, sa)) in st {
                guard let (mb, sb) = dt[path] else { missingOnDst.append(path); continue }
                let delta = abs((ma ?? .distantPast).timeIntervalSince(mb ?? .distantPast))
                if sa == sb && delta <= 2 { identical += 1 } else { differ.append(path) }
            }
            missingOnSrc = dt.keys.filter { st[$0] == nil }
        }
        var actions: [SyncAction] = missingOnDst.map { SyncAction(kind: .copyToDestination, path: $0, reason: L10n.tr("brak w celu")) }
        switch mode {
        case .mirror:
            actions += differ.map { SyncAction(kind: .copyToDestination, path: $0, reason: L10n.tr("różni się")) }
            actions += missingOnSrc.map { SyncAction(kind: .deleteFromDestination, path: $0, reason: L10n.tr("brak w źródle")) }
        case .update:
            actions += differ.map { SyncAction(kind: .copyToDestination, path: $0, reason: L10n.tr("różni się")) }
        case .twoWay:
            actions += missingOnSrc.map { SyncAction(kind: .copyToSource, path: $0, reason: L10n.tr("brak w źródle")) }
            if !differ.isEmpty {
                if st.isEmpty { st = try await times(rclone, sourceFs) }
                if dt.isEmpty { dt = try await times(rclone, destinationFs) }
                for path in differ {
                    let a = st[path]?.0 ?? .distantPast, b = dt[path]?.0 ?? .distantPast
                    actions.append(a >= b
                        ? SyncAction(kind: .copyToDestination, path: path, reason: L10n.tr("nowszy w źródle"))
                        : SyncAction(kind: .copyToSource, path: path, reason: L10n.tr("nowszy w celu")))
                }
            }
        }
        // Ścieżki pochodzą z serwera (niezaufane): `..`, znaki sterujące itp. nie trafiają do planu —
        // składane z korzeniem lokalnym wskazywałyby miejsce poza nim.
        actions.removeAll { !isSafeRelativePath($0.path) }
        actions.sort { $0.path < $1.path }
        return SyncPlan(sourceFs: sourceFs, destinationFs: destinationFs, mode: mode, actions: actions, identical: identical,
                        localSource: localSource, localDestination: localDestination)
    }

    /// Ścieżka względna, której każdy składnik jest bezpieczną nazwą (bez `/` na początku, `..`, `.`,
    /// pustych składników i znaków sterujących).
    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isSafeComponentName(String($0)) }
    }

    /// Wykonanie planu (blokujące, w zadaniu). Lokalne pliki nadpisywane lub usuwane trafiają
    /// najpierw do Kosza (dziennik → cofalne); kopie na dysk lokalny zapisywane jako utworzone.
    public static func execute(_ plan: SyncPlan, rclone: Rclone, control: JobControl, journal: OperationJournal?, batchID: UUID?,
                               progress: @Sendable (TransferProgress) -> Void) throws -> [String] {
        let fs = LocalFS()
        var errors: [String] = []
        var p = TransferProgress()
        let work = plan.actions.filter(\.enabled)
        p.filesTotal = work.count
        func record(_ a: JournalAction) { if let journal, let batchID { journal.record(a, in: batchID) } }
        for action in work {
            guard control.checkpoint() else { throw VFSError.cancelled }
            p.currentItem = action.path
            progress(p)
            let toDestination = action.kind != .copyToSource
            let targetLocal = toDestination ? plan.localDestination : plan.localSource
            do {
                guard isSafeRelativePath(action.path) else { throw VFSError.invalidName(action.path) }
                // Lokalny plik docelowy (nadpisywany lub usuwany) — najpierw do Kosza.
                if let root = targetLocal {
                    let local = VFSPath.local(root.path + "/" + action.path)
                    if FileManager.default.fileExists(atPath: local.path), let trashed = try fs.trashSync(local) {
                        record(.trashed(original: local, trashPath: trashed))
                    }
                }
                switch action.kind {
                case .deleteFromDestination:
                    if plan.localDestination == nil {
                        _ = try rclone.callSync("operations/deletefile", ["fs": plan.destinationFs, "remote": action.path])
                    }
                case .copyToDestination, .copyToSource:
                    let (src, dst) = toDestination ? (plan.sourceFs, plan.destinationFs) : (plan.destinationFs, plan.sourceFs)
                    _ = try rclone.callSync("operations/copyfile", ["srcFs": src, "srcRemote": action.path, "dstFs": dst, "dstRemote": action.path])
                    if let root = targetLocal {
                        record(.copied(from: VFSPath(provider: ProviderID("rclone"), path: "/" + action.path), to: .local(root.path + "/" + action.path)))
                    }
                }
            } catch {
                errors.append("\(action.path): \(error.localizedDescription)")
            }
            p.filesDone += 1
            progress(p)
        }
        return errors
    }
}

extension Rclone {
    /// `operations/check` zwraca 500, gdy znajdzie różnice — wynik i tak jest w treści odpowiedzi.
    public func callAllowingFailure(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: params)
        let socket = socket
        let response = try await runBlocking(qos: .userInitiated) { try Self.post(socket: socket.path, path: "/" + method, body: body) }
        guard let obj = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw RemoteError.rc(String(decoding: response.body.prefix(300), as: UTF8.self), status: response.status)
        }
        if obj["combined"] == nil, let error = obj["error"] as? String, !(200..<300).contains(response.status) {
            throw RemoteError.rc(error, status: response.status)
        }
        return obj
    }
}
