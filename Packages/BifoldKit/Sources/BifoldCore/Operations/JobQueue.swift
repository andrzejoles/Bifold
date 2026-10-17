import Foundation
import Observation

public enum JobSpec: Sendable, Hashable {
    case transfer(TransferRequest)
    case trash([VFSPath])
    case deletePermanently([VFSPath])

    public var isTransfer: Bool { if case .transfer = self { true } else { false } }
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

    public func pauseAll() { activeJobs.forEach(pause) }
    public func resumeAll() { activeJobs.forEach(resume) }
    public func cancelAll() { activeJobs.forEach(cancel) }

    public func removeFinished() {
        jobs.removeAll { $0.state.isFinished }
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
        let batchID = journal.beginBatch(title: job.title, invoker: job.invoker)
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
                }
                outcome = errors.isEmpty ? .completed : .failed(L10n.tr("Błędy: \(errors.count)"))
            } catch VFSError.cancelled {
                outcome = .cancelled
            } catch {
                outcome = .failed(error.localizedDescription)
            }
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
