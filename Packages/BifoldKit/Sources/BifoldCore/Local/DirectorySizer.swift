import Foundation
import Synchronization

public struct DirectorySize: Sendable, Hashable {
    public var bytes: Int64 = 0
    public var files: Int = 0
    public var directories: Int = 0
    /// Podkatalogi, których nie dało się odczytać (brak uprawnień).
    public var unreadable: Int = 0

    public init(bytes: Int64 = 0, files: Int = 0, directories: Int = 0, unreadable: Int = 0) {
        self.bytes = bytes
        self.files = files
        self.directories = directories
        self.unreadable = unreadable
    }

    static func + (a: Self, b: Self) -> Self {
        DirectorySize(bytes: a.bytes + b.bytes, files: a.files + b.files, directories: a.directories + b.directories, unreadable: a.unreadable + b.unreadable)
    }
}

/// Liczenie rozmiaru drzewa katalogów (logiczny rozmiar plików, bez podążania za dowiązaniami,
/// bez przekraczania granic woluminów). Anulowalne przez anulowanie zadania.
public enum DirectorySizer {
    /// Anulowanie zadania przerywa liczenie.
    public static func size(of path: VFSPath) async throws -> DirectorySize {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await runBlocking(qos: .utility) { try sizeSync(of: path, isCancelled: { flag.isCancelled }) }
        } onCancel: {
            flag.cancel()
        }
    }

    public static func sizeSync(of path: VFSPath, isCancelled: () -> Bool) throws -> DirectorySize {
        let fs = LocalFS()
        let root = try fs.itemSync(at: path)
        guard root.kind == .directory else {
            return DirectorySize(bytes: max(0, root.size), files: 1)
        }
        var rootStat = stat()
        lstat(path.path, &rootStat)
        let device = rootStat.st_dev

        var total = DirectorySize()
        var stack: [VFSPath] = [path]
        while let dir = stack.popLast() {
            if isCancelled() { throw VFSError.cancelled }
            let items: [FileItem]
            do {
                items = try fs.listSync(dir)
            } catch {
                total.unreadable += 1
                continue
            }
            for item in items {
                switch item.kind {
                case .directory:
                    var st = stat()
                    if lstat(item.path.path, &st) == 0, st.st_dev != device { continue }
                    total.directories += 1
                    stack.append(item.path)
                case .file, .symlink, .other:
                    total.files += 1
                    if item.kind == .file { total.bytes += max(0, item.size) }
                }
            }
        }
        return total
    }
}

/// Prosta flaga anulowania współdzielona między wątkami.
public final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    public init() {}
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
    public func cancel() { flag.store(true, ordering: .relaxed) }
}
