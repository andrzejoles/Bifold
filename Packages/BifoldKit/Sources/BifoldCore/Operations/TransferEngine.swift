import Darwin
import Foundation

// Stałe copyfile(3) — makra złożone nie zawsze są importowane do Swifta.
enum CF {
    static let acl: UInt32 = 1 << 0
    static let stat: UInt32 = 1 << 1
    static let xattr: UInt32 = 1 << 2
    static let data: UInt32 = 1 << 3
    static let metadata: UInt32 = acl | stat | xattr
    static let all: UInt32 = metadata | data
    static let excl: UInt32 = 1 << 17
    static let nofollowSrc: UInt32 = 1 << 18
    static let clone: UInt32 = 1 << 24

    static let stateStatusCB: UInt32 = 6
    static let stateStatusCtx: UInt32 = 7
    static let stateCopied: UInt32 = 8

    static let `continue`: Int32 = 0
    static let quit: Int32 = 2
    static let progress: Int32 = 4
    static let copyData: Int32 = 4
}

/// Kontekst przekazywany do callbacku `copyfile`.
private final class CopyContext {
    let control: JobControl
    let onBytes: (Int64) -> Void
    var reported: Int64 = 0
    var cancelled = false

    init(control: JobControl, onBytes: @escaping (Int64) -> Void) {
        self.control = control
        self.onBytes = onBytes
    }
}

private let copyCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return CF.continue }
    let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if what == CF.copyData && stage == CF.progress, let state {
        var copied: off_t = 0
        copyfile_state_get(state, CF.stateCopied, &copied)
        let delta = Int64(copied) - context.reported
        if delta > 0 {
            context.reported = Int64(copied)
            context.onBytes(delta)
            if !context.control.consume(delta) {
                context.cancelled = true
                return CF.quit
            }
        }
    }
    if !context.control.checkpoint() {
        context.cancelled = true
        return CF.quit
    }
    return CF.continue
}

/// Wykonuje kopiowanie i przenoszenie lokalne. Działa synchronicznie na wątku roboczym
/// (nie w puli współbieżności Swifta): blokuje się w pauzie, w limicie prędkości i podczas
/// oczekiwania na decyzję delegata.
public final class TransferEngine: @unchecked Sendable {
    public let request: TransferRequest
    public let control: JobControl
    let delegate: (any TransferDelegate)?
    let journal: OperationJournal?
    let batchID: UUID?
    let onProgress: @Sendable (TransferProgress) -> Void

    private let fs = LocalFS()
    private var plan: TransferPlan?
    private var progress = TransferProgress()
    private var lastReport = ContinuousClock.now
    private var speedSamples: [(ContinuousClock.Instant, Int64)] = []
    private var conflictDefault: ConflictResolution?
    private var skipAllErrors = false
    public private(set) var errors: [(VFSPath, VFSError)] = []
    /// Klonowanie APFS (natychmiastowa kopia). Wyłączane w testach, żeby sprawdzić postęp.
    var allowClone = true
    /// Rozpakowanie z archiwum: przeniesienie z katalogu tymczasowego zapisujemy jako kopię
    /// (cofnięcie = do Kosza), bo katalog tymczasowy znika.
    public var recordMovesAsCopies = false

    public init(
        request: TransferRequest, control: JobControl = JobControl(), delegate: (any TransferDelegate)? = nil,
        journal: OperationJournal? = nil, batchID: UUID? = nil,
        onProgress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) {
        self.request = request
        self.control = control
        self.delegate = delegate
        self.journal = journal
        self.batchID = batchID
        self.onProgress = onProgress
    }

    // MARK: Planowanie

    /// Liczy rozmiary i konflikty bez zmieniania czegokolwiek (podgląd „na sucho”).
    /// - Parameter assumingEmptyDestination: katalog docelowy jeszcze nie istnieje (zostanie utworzony).
    public static func plan(_ request: TransferRequest, assumingEmptyDestination: Bool = false, isCancelled: () -> Bool = { false }) throws -> TransferPlan {
        let fs = LocalFS()
        if !assumingEmptyDestination {
            let destDir = try fs.itemSync(at: request.destinationDirectory)
            guard destDir.isNavigable else { throw VFSError.notADirectory(request.destinationDirectory) }
        }
        if request.newName != nil { try validateFileName(request.newName!) }

        var plan = TransferPlan(request: request, operations: [], totalBytes: 0, fileCount: 0, directoryCount: 0, conflicts: [], subtreeSizes: [:])
        for source in request.sources {
            if isCancelled() { throw VFSError.cancelled }
            let item = try fs.itemSync(at: source)
            let dest = request.destination(for: source)
            if item.kind == .directory, dest.isDescendant(of: source) && dest != source {
                throw VFSError.destinationInsideSource(source)
            }
            var conflict = false
            let size: DirectorySize
            if item.kind == .directory {
                size = try DirectorySizer.sizeSync(of: source, isCancelled: isCancelled)
                plan.subtreeSizes[source] = size
                plan.directoryCount += 1 + size.directories
                if let existing = try? fs.itemSync(at: dest), dest != source {
                    if existing.kind == .directory {
                        collectMergeConflicts(source: source, dest: dest, into: &plan, fs: fs)
                    } else {
                        conflict = true
                    }
                }
            } else {
                size = DirectorySize(bytes: max(0, item.size), files: 1)
                if dest != source, pathExists(fs, dest) { conflict = true }
            }
            if conflict { plan.conflicts.append(dest) }
            plan.totalBytes += size.bytes
            plan.fileCount += size.files
            plan.operations.append(PlannedOperation(
                kind: request.kind.rawValue, source: source, destination: dest,
                isDirectory: item.kind == .directory, bytes: size.bytes, conflict: conflict))
        }
        return plan
    }

    private static func pathExists(_ fs: LocalFS, _ p: VFSPath) -> Bool {
        var st = stat()
        return lstat(p.path, &st) == 0
    }

    private static func collectMergeConflicts(source: VFSPath, dest: VFSPath, into plan: inout TransferPlan, fs: LocalFS) {
        guard let children = try? fs.listSync(source) else { return }
        for child in children {
            let target = dest.appending(child.name)
            guard let existing = try? fs.itemSync(at: target) else { continue }
            if child.kind == .directory && existing.kind == .directory {
                plan.subtreeSizes[child.path] = try? DirectorySizer.sizeSync(of: child.path, isCancelled: { false })
                collectMergeConflicts(source: child.path, dest: target, into: &plan, fs: fs)
            } else {
                plan.conflicts.append(target)
            }
        }
    }

    // MARK: Wykonanie

    public func run() throws {
        let plan = try TransferEngine.plan(request, isCancelled: { control.isCancelled })
        self.plan = plan
        progress.bytesTotal = plan.totalBytes
        progress.filesTotal = plan.fileCount
        report(force: true)
        for source in request.sources {
            try checkCancelled()
            try transfer(source, to: request.destination(for: source))
        }
        progress.currentItem = ""
        report(force: true)
    }

    private func checkCancelled() throws {
        if !control.checkpoint() { throw VFSError.cancelled }
    }

    private func transfer(_ source: VFSPath, to requestedDestination: VFSPath) throws {
        try checkCancelled()
        guard let item = try attempt(source, { try fs.itemSync(at: source) }) else { return }
        progress.currentItem = item.name

        var destination = requestedDestination
        if destination == source {
            if request.kind == .move {
                skip(item)
                return
            }
            destination = TransferEngine.uniqueName(for: destination)
        }

        if let existing = try? fs.itemSync(at: destination) {
            if item.kind == .directory && existing.kind == .directory {
                try merge(item, into: destination)
                return
            }
            let resolution = try decideConflict(FileConflict(source: item, destination: existing, kind: request.kind))
            switch resolution {
            case .skip:
                skip(item)
                return
            case .cancel:
                throw VFSError.cancelled
            case .rename:
                destination = TransferEngine.uniqueName(for: destination)
            case .overwriteOlder:
                if let srcDate = item.modified, let dstDate = existing.modified, dstDate >= srcDate {
                    skip(item)
                    return
                }
                guard try replaceExisting(existing) else { skip(item); return }
            case .overwrite:
                guard try replaceExisting(existing) else { skip(item); return }
            }
        }

        if request.kind == .move, TransferEngine.sameDevice(source, destination.parent!) {
            guard try attempt(source, { try fs.moveSync(source, to: destination) }) != nil else { return }
            let moved = try? fs.itemSync(at: destination)
            journal(.moved(from: source, to: destination), fingerprint: moved?.fingerprint)
            complete(item)
            return
        }

        if item.kind == .directory {
            try copyDirectory(item, to: destination, record: true)
        } else {
            try copyLeaf(item, to: destination, recordAsNew: true)
        }
    }

    /// Katalog docelowy istnieje — przenosimy/kopiujemy zawartość element po elemencie.
    private func merge(_ item: FileItem, into destination: VFSPath) throws {
        guard let children = try attempt(item.path, { try fs.listSync(item.path) }) else { return }
        for child in children {
            try transfer(child.path, to: destination.appending(child.name))
        }
        if request.kind == .move { removeIfEmpty(item.path) }
    }

    /// Nowy katalog docelowy: kopiowanie (lub przenoszenie między woluminami) całego poddrzewa.
    private func copyDirectory(_ item: FileItem, to destination: VFSPath, record: Bool) throws {
        guard try attempt(destination, { try createDirectorySync(destination) }) != nil else { return }
        // Kopia: jeden wpis dla całego nowego poddrzewa. Przeniesienie między woluminami:
        // katalog utworzony + każdy przeniesiony plik osobno (bo źródło znika stopniowo).
        if request.kind == .copy {
            if record { journal(.copied(from: item.path, to: destination), fingerprint: nil) }
        } else {
            journal(.created(path: destination, isDirectory: true), fingerprint: nil)
        }
        let children = try attempt(item.path, { try fs.listSync(item.path) }) ?? []
        for child in children {
            try checkCancelled()
            progress.currentItem = child.name
            if child.kind == .directory {
                try copyDirectory(child, to: destination.appending(child.name), record: false)
            } else {
                try copyLeaf(child, to: destination.appending(child.name), recordAsNew: request.kind == .move)
            }
        }
        _ = copyfile(item.path.path, destination.path, nil, copyfile_flags_t(CF.metadata))
        if request.kind == .move { removeIfEmpty(item.path) }
    }

    private func createDirectorySync(_ path: VFSPath) throws {
        guard mkdir(path.path, 0o755) == 0 else { throw VFSError.from(errno: errno, path: path) }
    }

    /// Kopiuje plik lub dowiązanie do pliku tymczasowego i atomowo zmienia nazwę na docelową.
    private func copyLeaf(_ item: FileItem, to destination: VFSPath, recordAsNew: Bool) throws {
        let parent = destination.parent!
        let temp = parent.appending(".\(destination.name).bifold-partial-\(UInt32.random(in: 0...UInt32.max))")
        let done = try attempt(item.path) { () throws -> Bool in
            try self.copyFileData(from: item.path, to: temp, size: max(0, item.size))
            guard renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                let e = errno
                unlink(temp.path)
                throw VFSError.from(errno: e, path: destination)
            }
            return true
        }
        guard done != nil else { return }
        let fingerprint = (try? fs.itemSync(at: destination))?.fingerprint
        if request.kind == .move {
            if unlink(item.path.path) == 0 {
                if recordAsNew { journal(.moved(from: item.path, to: destination), fingerprint: fingerprint) }
            } else {
                // Źródła nie da się usunąć — zostaje kopia.
                let error = VFSError.from(errno: errno, path: item.path)
                errors.append((item.path, error))
                journal(.copied(from: item.path, to: destination), fingerprint: fingerprint)
            }
        } else if recordAsNew {
            journal(.copied(from: item.path, to: destination), fingerprint: fingerprint)
        }
        filesDone(1)
    }

    private func copyFileData(from source: VFSPath, to temp: VFSPath, size: Int64) throws {
        guard let state = copyfile_state_alloc() else { throw VFSError.io(path: source, code: ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(control: control) { [unowned self] delta in self.addBytes(delta) }
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        copyfile_state_set(state, CF.stateStatusCB, unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, CF.stateStatusCtx, unmanaged.toOpaque())

        let flags = copyfile_flags_t(CF.all | (allowClone ? CF.clone : 0) | CF.excl | CF.nofollowSrc)
        let rc = copyfile(source.path, temp.path, state, flags)
        if rc != 0 {
            let e = errno
            unlink(temp.path)
            if context.cancelled || control.isCancelled { throw VFSError.cancelled }
            throw VFSError.from(errno: e, path: source)
        }
        // Klon APFS nie wywołuje callbacku postępu — doliczamy resztę.
        if size > context.reported { addBytes(size - context.reported) }
    }

    /// Nadpisywany element trafia do Kosza (a nie znika), żeby dało się cofnąć operację.
    private func replaceExisting(_ existing: FileItem) throws -> Bool {
        let trashed = try attempt(existing.path) { () throws -> VFSPath? in
            do {
                return try self.fs.trashSync(existing.path)
            } catch VFSError.io, VFSError.unsupported {
                // Wolumin bez Kosza — trwałe usunięcie.
                try self.fs.deleteSync(existing.path)
                return nil
            }
        }
        guard let trashed else { return false }
        if let trashPath = trashed {
            journal(.trashed(original: existing.path, trashPath: trashPath), fingerprint: nil)
        } else {
            journal(.deletedPermanently(path: existing.path), fingerprint: nil)
        }
        return true
    }

    private func removeIfEmpty(_ dir: VFSPath) {
        if rmdir(dir.path) == 0 {
            journal(.removedEmptyDirectory(path: dir), fingerprint: nil)
        }
    }

    // MARK: Decyzje i błędy

    private func decideConflict(_ conflict: FileConflict) throws -> ConflictResolution {
        if let d = conflictDefault { return d }
        guard let delegate else { return .skip }
        let decision = waitFor { await delegate.resolveConflict(conflict) }
        if decision.applyToAll { conflictDefault = decision.resolution }
        return decision.resolution
    }

    /// Wykonuje operację; przy błędzie pyta delegata (pomiń / pomiń wszystkie / ponów / anuluj).
    /// Zwraca `nil`, jeśli element pominięto.
    private func attempt<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T? {
        while true {
            do {
                return try body()
            } catch let error as VFSError where error == .cancelled {
                throw error
            } catch {
                let vfsError = VFSError.from(error, path: path)
                if control.isCancelled { throw VFSError.cancelled }
                if skipAllErrors || delegate == nil {
                    errors.append((path, vfsError))
                    return nil
                }
                let decision = waitFor { await self.delegate!.resolveError(path: path, error: vfsError) }
                switch decision {
                case .retry: continue
                case .skip:
                    errors.append((path, vfsError))
                    return nil
                case .skipAll:
                    skipAllErrors = true
                    errors.append((path, vfsError))
                    return nil
                case .cancel:
                    throw VFSError.cancelled
                }
            }
        }
    }

    /// Most z kodu asynchronicznego (okna dialogowe) do wątku roboczego.
    private func waitFor<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    // MARK: Postęp i dziennik

    private func journal(_ action: JournalAction, fingerprint: Fingerprint?) {
        guard let journal, let batchID else { return }
        if recordMovesAsCopies {
            switch action {
            case let .moved(from, to): journal.record(.copied(from: from, to: to), fingerprint: fingerprint, in: batchID); return
            case .removedEmptyDirectory, .created(_, true): return
            default: break
            }
        }
        journal.record(action, fingerprint: fingerprint, in: batchID)
    }

    private func skip(_ item: FileItem) {
        let size = item.kind == .directory ? (plan?.subtreeSizes[item.path] ?? DirectorySize()) : DirectorySize(bytes: max(0, item.size), files: 1)
        progress.bytesDone += size.bytes
        filesDone(size.files)
    }

    private func complete(_ item: FileItem) {
        skip(item)
    }

    private func addBytes(_ delta: Int64) {
        progress.bytesDone += delta
        report()
    }

    private func filesDone(_ n: Int) {
        progress.filesDone += n
        report()
    }

    private func report(force: Bool = false) {
        let now = ContinuousClock.now
        guard force || now - lastReport >= .milliseconds(100) else { return }
        lastReport = now
        speedSamples.append((now, progress.bytesDone))
        speedSamples.removeAll { now - $0.0 > .seconds(3) }
        if let first = speedSamples.first, now - first.0 > .milliseconds(200) {
            progress.bytesPerSecond = Double(progress.bytesDone - first.1) / (now - first.0).seconds
        }
        onProgress(progress)
    }

    // MARK: Pomocnicze

    static func sameDevice(_ a: VFSPath, _ b: VFSPath) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }

    /// Ścieżka bez zmian, jeśli wolna; inaczej „nazwa (2)”…
    public static func uniqueOrSame(_ path: VFSPath) -> VFSPath {
        FileManager.default.fileExists(atPath: path.path) ? uniqueName(for: path) : path
    }

    /// „nazwa (2).ext”, „nazwa (3).ext”, …
    public static func uniqueName(for path: VFSPath) -> VFSPath {
        guard let parent = path.parent else { return path }
        let stem = path.name.fileStem, ext = path.name.fileExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = parent.appending(name)
            var st = stat()
            if lstat(candidate.path, &st) != 0 { return candidate }
            n += 1
        }
    }

    /// Przeniesienie pojedynczego elementu bez konfliktów (używane przy cofaniu):
    /// `rename` na tym samym woluminie, w przeciwnym razie kopia i usunięcie źródła.
    public static func moveItem(from source: VFSPath, to destination: VFSPath) throws {
        var st = stat()
        if lstat(destination.path, &st) == 0 { throw VFSError.alreadyExists(destination) }
        if let parent = destination.parent, sameDevice(source, parent) {
            try LocalFS().moveSync(source, to: destination)
            return
        }
        guard let parent = destination.parent else { throw VFSError.unsupported("move /") }
        let engine = TransferEngine(request: TransferRequest(kind: .move, sources: [source], destinationDirectory: parent, newName: destination.name))
        try engine.run()
        if let (path, error) = engine.errors.first {
            throw VFSError.from(error, path: path)
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
