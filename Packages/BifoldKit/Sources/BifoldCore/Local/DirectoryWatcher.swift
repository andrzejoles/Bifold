import CoreServices
import Foundation

/// Obserwowanie zmian w jednym katalogu przez FSEvents (zdarzenia na poziomie plików,
/// odfiltrowane do bezpośrednich dzieci katalogu).
final class DirectoryWatcher: @unchecked Sendable {
    private let watchedPath: String
    private let continuation: AsyncStream<DirectoryChange>.Continuation
    private let queue = DispatchQueue(label: "bifold.fsevents", qos: .utility)
    // Dostęp tylko z `queue` (start/stop i callback są tam wykonywane).
    private var stream: FSEventStreamRef?

    static func stream(for directory: String) -> AsyncStream<DirectoryChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = DirectoryWatcher(path: directory, continuation: continuation)
            watcher.start()
            continuation.onTermination = { _ in watcher.stop() }
        }
    }

    private init(path: String, continuation: AsyncStream<DirectoryChange>.Continuation) {
        // FSEvents raportuje ścieżki rzeczywiste (np. /private/tmp zamiast /tmp).
        self.watchedPath = realPath(path) ?? path
        self.continuation = continuation
    }

    private func start() {
        queue.async { [self] in
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self)
                for i in 0..<count {
                    guard let path = array[i] as? String else { continue }
                    watcher.handle(path: path, flags: flags[i])
                }
            }
            let createFlags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, [watchedPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, createFlags)
            else { return }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    /// Zatrzymanie asynchronicznie na kolejce strumienia. (Wcześniej `queue.sync` — zakleszczenie,
    /// gdy anulowanie strumienia trzyma jego blokadę, a callback FSEvents czeka na nią w `yield`.)
    /// Blok trzyma silną referencję, więc obiekt żyje do unieważnienia strumienia; po
    /// `FSEventStreamInvalidate` na tej kolejce callback już się nie wykona.
    private func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            if !FileManager.default.fileExists(atPath: watchedPath) {
                continuation.yield(.directoryRemoved)
                return
            }
        }
        if trimmed == watchedPath {
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0,
               !FileManager.default.fileExists(atPath: watchedPath) {
                continuation.yield(.directoryRemoved)
            } else {
                continuation.yield(.contentsChanged)
            }
            return
        }
        let parent = (trimmed as NSString).deletingLastPathComponent
        if parent == watchedPath || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            continuation.yield(.contentsChanged)
        }
    }
}
