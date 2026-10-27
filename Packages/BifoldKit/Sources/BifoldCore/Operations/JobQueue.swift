import Foundation
import Observation

public enum JobSpec: Sendable {
    case transfer(TransferRequest)
    case trash([VFSPath])
    case deletePermanently([VFSPath])
    /// Kopiowanie z archiwum lub urządzenia do katalogu lokalnego.
    case extract(source: any ExtractingProvider, sources: [VFSPath], destination: VFSPath)
    /// Rozpakowanie całych archiwów (do katalogu docelowego lub podkatalogów nazwanych jak archiwa).
    case extractArchives([VFSPath], destination: VFSPath, tool: SevenZip, overwrite: SevenZip.Overwrite, subfolders: Bool)
    /// Przesyłanie przez rclone (serwery, chmury).
    case rclone(RcloneTransfer, Rclone)
    /// Wysyłanie na serwer SCP.
    case scpUpload(ScpUpload)
    /// Synchronizacja katalogów (plan policzony wcześniej „na sucho”).
    case sync(SyncPlan, Rclone)
    /// Tworzenie archiwum.
    case createArchive(VFSPath, format: ArchiveFormat, base: VFSPath, names: [String], tool: SevenZip, level: Int, password: String?, volumeSize: String?)

}

public enum JobState: Sendable, Hashable {
    case queued, running, paused, completed, failed(String), cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

/// Jedno zadanie w kolejce (obserwowane przez interfejs).
@MainActor @Observable
public final class Job: Identifiable {
    public let id = UUID()
    public let title: String
    public let spec: JobSpec
    public let invoker: Invoker
    public internal(set) var state: JobState = .queued
    public internal(set) var progress = TransferProgress()
    public internal(set) var errors: [String] = []
    public internal(set) var batchID: UUID?
    public internal(set) var speedLimit: Int64 = 0
    public let created = Date()

    @ObservationIgnored let control = JobControl()
    @ObservationIgnored let delegate: (any TransferDelegate)?
    @ObservationIgnored var waiters: [CheckedContinuation<JobState, Never>] = []

    init(title: String, spec: JobSpec, invoker: Invoker, delegate: (any TransferDelegate)?) {
        self.title = title
        self.spec = spec
        self.invoker = invoker
        self.delegate = delegate
    }
}

/// Kolejka operacji w tle: kopiowanie, przenoszenie, Kosz, usuwanie. Zadania wykonują się
/// po kolei (jedno naraz) na osobnym wątku; postęp trafia do modelu na głównym aktorze.
@MainActor @Observable
public final class JobQueue {
    public private(set) var jobs: [Job] = []
    /// Maksymalna liczba zadań wykonywanych równocześnie.
    public var maxConcurrent = 1 { didSet { startNext() } }

    @ObservationIgnored public let journal: OperationJournal
    @ObservationIgnored private let workQueue = DispatchQueue(label: "bifold.jobs", qos: .userInitiated, attributes: .concurrent)

    public init(journal: OperationJournal) {
        self.journal = journal
    }

    public var activeJobs: [Job] { jobs.filter { !$0.state.isFinished } }

    @discardableResult
    public func enqueue(_ spec: JobSpec, title: String, invoker: Invoker = .user, delegate: (any TransferDelegate)? = nil, speedLimit: Int64 = 0) -> Job {
        let job = Job(title: title, spec: spec, invoker: invoker, delegate: delegate)
        if speedLimit > 0 { setSpeedLimit(job, speedLimit) }
        jobs.append(job)
        startNext()
        return job
    }

    public func pause(_ job: Job) {
        guard job.state == .running || job.state == .queued else { return }
        job.control.pause()
        job.state = .paused
    }

    public func resume(_ job: Job) {
        guard job.state == .paused else { return }
        job.control.resume()
        job.state = isStarted(job) ? .running : .queued
        startNext()
    }

    public func cancel(_ job: Job) {
        guard !job.state.isFinished else { return }
        job.control.cancel()
        if !isStarted(job) { finish(job, .cancelled) }
    }

    public func setSpeedLimit(_ job: Job, _ bytesPerSecond: Int64) {
        job.speedLimit = max(0, bytesPerSecond)
        job.control.setSpeedLimit(job.speedLimit)
    }

    public func cancelAll() { activeJobs.forEach(cancel) }

    public func removeFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    /// Usuwa z kolejki jedno zadanie, jeśli jest zakończone (trwające i oczekujące zostają).
    public func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id && $0.state.isFinished }
    }

    public func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// Czeka na zakończenie zadania (agent, testy).
    public func wait(for job: Job) async -> JobState {
        if job.state.isFinished { return job.state }
        return await withCheckedContinuation { job.waiters.append($0) }
    }

    // MARK: Wykonanie

    @ObservationIgnored private var started: Set<UUID> = []

    private func isStarted(_ job: Job) -> Bool { started.contains(job.id) }

    private func startNext() {
        let running = jobs.filter { started.contains($0.id) && !$0.state.isFinished }.count
        guard running < maxConcurrent else { return }
        guard let next = jobs.first(where: { $0.state == .queued && !started.contains($0.id) }) else { return }
        start(next)
        startNext()
    }

    private func start(_ job: Job) {
        started.insert(job.id)
        job.state = job.control.isPaused ? .paused : .running
        // Partia trwającego zadania nie jest proponowana do cofnięcia, dopóki zadanie się nie skończy.
        let batchID = journal.beginBatch(title: job.title, invoker: job.invoker, finished: false)
        job.batchID = batchID
        let spec = job.spec, control = job.control, delegate = job.delegate, journal = journal
        let progressSink = ProgressSink(job: job)

        workQueue.async {
            let outcome: JobState
            var errors: [String] = []
            do {
                switch spec {
                case .transfer(let request):
                    let engine = TransferEngine(
                        request: request, control: control, delegate: delegate, journal: journal, batchID: batchID,
                        onProgress: { progressSink.update($0) })
                    try engine.run()
                    errors = engine.errors.map { "\($0.0.description): \($0.1.localizedDescription)" }
                case .trash(let paths):
                    errors = try JobQueue.runTrash(paths, control: control, journal: journal, batchID: batchID, sink: progressSink)
                case .deletePermanently(let paths):
                    errors = try JobQueue.runDelete(paths, control: control, journal: journal, batchID: batchID, sink: progressSink)
                case let .extract(archive, sources, destination):
                    let isCancelled: @Sendable () -> Bool = { control.isCancelled }
                    var p = TransferProgress()
                    p.currentItem = archive.displayName
                    progressSink.update(p)
                    let (temp, items) = try archive.extract(sources, toTemporaryIn: destination, isCancelled: isCancelled)
                    defer { try? FileManager.default.removeItem(atPath: temp.path) }
                    let engine = TransferEngine(
                        request: TransferRequest(kind: .move, sources: items, destinationDirectory: destination),
                        control: control, delegate: delegate, journal: journal, batchID: batchID,
                        onProgress: { progressSink.update($0) })
                    engine.recordMovesAsCopies = true
                    try engine.run()
                    errors = engine.errors.map { "\($0.0.name): \($0.1.localizedDescription)" }
                case let .extractArchives(archives, destination, tool, overwrite, subfolders):
                    var p = TransferProgress()
                    p.filesTotal = archives.count
                    for a in archives {
                        guard control.checkpoint() else { throw VFSError.cancelled }
                        p.currentItem = a.name
                        progressSink.update(p)
                        var target = destination
                        if subfolders {
                            var stem = a.name
                            while ArchiveFS.isArchive(stem) || stem.fileExtension == "001" { stem = stem.fileStem }
                            target = TransferEngine.uniqueOrSame(destination.appending(stem))
                            try FileManager.default.createDirectory(atPath: target.path, withIntermediateDirectories: true)
                            // Nowe poddrzewo jako całość — cofnięcie przenosi je do Kosza.
                            journal.record(.copied(from: a, to: target), in: batchID)
                        }
                        do {
                            if subfolders {
                                // Nowy, pusty katalog — rozpakowanie bezpośrednio, nie ma czego nadpisać.
                                try tool.extract(a, to: target, overwrite: overwrite, password: nil, isCancelled: { control.isCancelled })
                            } else {
                                errors += try JobQueue.extractThroughTemporary(a, into: target, tool: tool, overwrite: overwrite, control: control,
                                                                              delegate: delegate, journal: journal, batchID: batchID)
                            }
                        } catch VFSError.cancelled {
                            throw VFSError.cancelled
                        } catch {
                            errors.append("\(a.name): \(error.localizedDescription)")
                        }
                        p.filesDone += 1
                        progressSink.update(p)
                    }
                case let .sync(plan, rclone):
                    errors = try SyncPlanner.execute(plan, rclone: rclone, control: control, journal: journal, batchID: batchID) { progressSink.update($0) }
                case let .rclone(transfer, rclone):
                    errors = try transfer.run(rclone: rclone, control: control, journal: journal, batchID: batchID) { progressSink.update($0) }
                case .scpUpload(let upload):
                    errors = try upload.run(control: control) { progressSink.update($0) }
                case let .createArchive(archive, format, base, names, tool, level, password, volumeSize):
                    var p = TransferProgress()
                    p.currentItem = archive.name
                    progressSink.update(p)
                    try tool.create(archive, format: format, base: base, names: names, level: level, password: password, volumeSize: volumeSize, isCancelled: { control.isCancelled })
                    let created = volumeSize.map { $0.isEmpty ? [archive] : FileSplitter.parts(startingWith: archive.parent!.appending(archive.name + ".001")) } ?? [archive]
                    for c in created { journal.record(.created(path: c, isDirectory: false), fingerprint: try? LocalFS().itemSync(at: c).fingerprint, in: batchID) }
                }
                outcome = errors.isEmpty ? .completed : .failed(L10n.tr("Błędy: \(errors.count)"))
            } catch VFSError.cancelled {
                outcome = .cancelled
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            journal.endBatch(batchID)
            let finalErrors = errors
            Task { @MainActor in
                progressSink.flush()
                job.errors = finalErrors
                self.finish(job, outcome)
            }
        }
    }

    private func finish(_ job: Job, _ state: JobState) {
        job.state = state
        started.remove(job.id)
        let waiters = job.waiters
        job.waiters = []
        waiters.forEach { $0.resume(returning: state) }
        startNext()
    }

    /// Rozpakowanie do istniejącego katalogu: najpierw do katalogu tymczasowego na tym samym woluminie,
    /// potem przeniesienie silnikiem kopiowania — nadpisywane pliki trafiają do Kosza (D14), wszystko
    /// jest w dzienniku (cofalne), a `7zz -aoa` niczego nie nadpisuje trwale.
    nonisolated static func extractThroughTemporary(
        _ archive: VFSPath, into target: VFSPath, tool: SevenZip, overwrite: SevenZip.Overwrite, control: JobControl,
        delegate: (any TransferDelegate)?, journal: OperationJournal, batchID: UUID
    ) throws -> [String] {
        let temp = target.appending(".bifold-extract-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: temp.path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: temp.path) }
        try tool.extract(archive, to: temp, overwrite: .overwrite, password: nil, isCancelled: { control.isCancelled })
        let items = try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted().map { temp.appending($0) }
        guard !items.isEmpty else { return [] }
        let conflict: ConflictResolution = switch overwrite {
        case .skip: .skip
        case .overwrite: .overwrite
        case .rename: .rename
        }
        let engine = TransferEngine(
            request: TransferRequest(kind: .move, sources: items, destinationDirectory: target), control: control,
            delegate: FixedConflictDelegate(conflict: conflict, errors: delegate), journal: journal, batchID: batchID)
        engine.recordMovesAsCopies = true
        try engine.run()
        return engine.errors.map { "\(archive.name): \($0.0.name): \($0.1.localizedDescription)" }
    }

    nonisolated static func runTrash(_ paths: [VFSPath], control: JobControl, journal: OperationJournal, batchID: UUID, sink: ProgressSink) throws -> [String] {
        let fs = LocalFS()
        var errors: [String] = []
        var p = TransferProgress()
        p.filesTotal = paths.count
        for path in paths {
            guard control.checkpoint() else { throw VFSError.cancelled }
            p.currentItem = path.name
            do {
                if let trashPath = try fs.trashSync(path) {
                    journal.record(.trashed(original: path, trashPath: trashPath), in: batchID)
                }
            } catch {
                errors.append("\(path.description): \(error.localizedDescription)")
            }
            p.filesDone += 1
            sink.update(p)
        }
        return errors
    }

    nonisolated static func runDelete(_ paths: [VFSPath], control: JobControl, journal: OperationJournal, batchID: UUID, sink: ProgressSink) throws -> [String] {
        let fs = LocalFS()
        var errors: [String] = []
        var p = TransferProgress()
        p.filesTotal = paths.count
        for path in paths {
            guard control.checkpoint() else { throw VFSError.cancelled }
            p.currentItem = path.name
            do {
                try fs.deleteSync(path)
                journal.record(.deletedPermanently(path: path), in: batchID)
            } catch {
                errors.append("\(path.description): \(error.localizedDescription)")
            }
            p.filesDone += 1
            sink.update(p)
        }
        return errors
    }
}

/// Konflikty według trybu wybranego przed zadaniem, błędy — przez delegata zadania (albo pomijane).
struct FixedConflictDelegate: TransferDelegate {
    let conflict: ConflictResolution
    let errors: (any TransferDelegate)?

    func resolveConflict(_ conflict: FileConflict) async -> ConflictDecision { ConflictDecision(self.conflict, applyToAll: true) }

    func resolveError(path: VFSPath, error: VFSError) async -> ErrorDecision {
        await errors?.resolveError(path: path, error: error) ?? .skip
    }
}

/// Przekazuje postęp z wątku roboczego do modelu, łącząc aktualizacje (najwyżej jedna
/// oczekująca na głównym aktorze).
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: TransferProgress?
    private var scheduled = false
    private weak var job: Job?

    @MainActor init(job: Job) { self.job = job }

    func update(_ progress: TransferProgress) {
        let schedule: Bool = lock.withLock {
            pending = progress
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor in self.flush() }
    }

    @MainActor func flush() {
        let value: TransferProgress? = lock.withLock {
            scheduled = false
            defer { pending = nil }
            return pending
        }
        if let value, let job { job.progress = value }
    }
}
