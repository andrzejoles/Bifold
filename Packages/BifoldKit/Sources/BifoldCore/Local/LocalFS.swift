import Darwin
import Foundation

/// Lokalny system plików.
public struct LocalFS: FileSystemProvider {
    public let id: ProviderID = .local
    public let capabilities: ProviderCapabilities = .all

    public init() {}

    /// Ścieżka innego dostawcy (archiwum, wyniki wyszukiwania) nigdy nie może dotknąć dysku —
    /// `/a/b` z archiwum to nie jest `/a/b` w systemie plików.
    @inline(__always)
    func requireLocal(_ path: VFSPath) throws {
        guard path.isLocal else { throw VFSError.unsupported("\(path.provider): \(L10n.tr("tylko do odczytu"))") }
    }

    // MARK: Odczyt

    public func list(_ directory: VFSPath, options: ListOptions = ListOptions()) async throws -> [FileItem] {
        try await runBlocking { try listSync(directory, options: options) }
    }

    public func listSync(_ directory: VFSPath, options: ListOptions = ListOptions()) throws -> [FileItem] {
        try requireLocal(directory)

        var items: [FileItem]
        do {
            items = try BulkLister.list(directory)
        } catch VFSError.io {
            items = try listWithFileManager(directory)
        }
        if !options.includeHidden { items.removeAll { $0.isHidden } }
        return items
    }

    /// Zapasowa ścieżka dla systemów plików bez `getattrlistbulk`.
    func listWithFileManager(_ directory: VFSPath) throws -> [FileItem] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw VFSError.from(error, path: directory)
        }
        var items: [FileItem] = []
        items.reserveCapacity(names.count)
        for name in names {
            let path = directory.appending(name)
            var st = stat()
            guard lstat(path.path, &st) == 0 else { continue }
            items.append(FileItem(stat: st, path: path))
        }
        BulkLister.resolveSymlinkTargets(&items)
        return items
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        try itemSync(at: path)
    }

    public func itemSync(at path: VFSPath) throws -> FileItem {
        try requireLocal(path)

        var st = stat()
        guard lstat(path.path, &st) == 0 else { throw VFSError.from(errno: errno, path: path) }
        var item = FileItem(stat: st, path: path)
        if item.kind == .symlink {
            var target = stat()
            if stat(path.path, &target) == 0, target.st_mode & S_IFMT == S_IFDIR {
                item.flags.insert(.symlinkToDirectory)
            }
        }
        return item
    }

    public func exists(_ path: VFSPath) async -> Bool {
        guard path.isLocal else { return false }
        var st = stat()
        return lstat(path.path, &st) == 0
    }

    public func readContents(_ path: VFSPath, range: Range<Int64>? = nil) async throws -> Data {
        try await runBlocking { try readSync(path, range: range) }
    }

    public func readSync(_ path: VFSPath, range: Range<Int64>? = nil) throws -> Data {
        try requireLocal(path)

        let fd = open(path.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw VFSError.from(errno: errno, path: path) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw VFSError.from(errno: errno, path: path) }
        guard st.st_mode & S_IFMT != S_IFDIR else { throw VFSError.unsupported("read directory") }
        let fileSize = Int64(st.st_size)
        let lower = max(0, range?.lowerBound ?? 0)
        let upper = min(fileSize, range?.upperBound ?? fileSize)
        guard upper > lower else { return Data() }
        var data = Data(count: Int(upper - lower))
        let read = data.withUnsafeMutableBytes { buf -> Int in
            var total = 0
            while total < buf.count {
                let n = pread(fd, buf.baseAddress! + total, buf.count - total, off_t(lower) + off_t(total))
                if n < 0 { if errno == EINTR { continue }; return -1 }
                if n == 0 { break }
                total += n
            }
            return total
        }
        guard read >= 0 else { throw VFSError.from(errno: errno, path: path) }
        data.count = read
        return data
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<DirectoryChange> {
        DirectoryWatcher.stream(for: directory.path)
    }

    public func volumeInfo(for path: VFSPath) async throws -> VolumeInfo {
        try Volumes.info(for: path)
    }

    // MARK: Zapis

    public func createDirectory(_ path: VFSPath) async throws {
        try requireLocal(path)
        try validateFileName(path.name)
        guard mkdir(path.path, 0o755) == 0 else { throw VFSError.from(errno: errno, path: path) }
    }

    public func createFile(_ path: VFSPath, contents: Data = Data()) async throws {
        try createFileSync(path, contents: contents)
    }

    public func createFileSync(_ path: VFSPath, contents: Data = Data()) throws {
        try requireLocal(path)

        try validateFileName(path.name)
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw VFSError.from(errno: errno, path: path) }
        defer { close(fd) }
        let written = contents.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress, buf.count > 0 else { return 0 }
            return write(fd, base, buf.count)
        }
        guard written == contents.count else { throw VFSError.from(errno: errno, path: path) }
    }

    public func rename(_ path: VFSPath, to newName: String) async throws -> VFSPath {
        try validateFileName(newName)
        guard let parent = path.parent else { throw VFSError.unsupported("rename /") }
        let target = parent.appending(newName)
        try moveSync(path, to: target)
        return target
    }

    /// Przeniesienie w obrębie woluminu (`rename(2)`). Nie nadpisuje istniejących elementów,
    /// z wyjątkiem zmiany wielkości liter tego samego pliku na systemie bez rozróżniania.
    public func moveSync(_ source: VFSPath, to target: VFSPath) throws {
        try requireLocal(source)
        try requireLocal(target)

        var srcStat = stat(), dstStat = stat()
        guard lstat(source.path, &srcStat) == 0 else { throw VFSError.from(errno: errno, path: source) }
        if lstat(target.path, &dstStat) == 0 {
            let sameFile = dstStat.st_ino == srcStat.st_ino && dstStat.st_dev == srcStat.st_dev
            guard sameFile else { throw VFSError.alreadyExists(target) }
            guard Darwin.rename(source.path, target.path) == 0 else { throw VFSError.from(errno: errno, path: source) }
            return
        }
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw VFSError.from(errno: errno, path: errno == EEXIST ? target : source)
        }
    }

    /// Błąd `trashSync` dla woluminu bez Kosza (tylko wtedy wolno zastąpić Kosz trwałym usunięciem).
    public static let trashUnavailable = VFSError.unsupported("trash")

    /// Wolumin nie obsługuje Kosza (`NSFeatureUnsupportedError` albo `ENOTSUP`).
    static func isTrashUnavailable(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFeatureUnsupportedError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOTSUP) || ns.code == Int(EOPNOTSUPP)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isTrashUnavailable(underlying) }
        return false
    }

    public func trash(_ path: VFSPath) async throws -> VFSPath? {
        try trashSync(path)
    }

    public func trashSync(_ path: VFSPath) throws -> VFSPath? {
        try requireLocal(path)

        guard let url = path.url else { throw VFSError.unsupported("trash") }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            if Self.isTrashUnavailable(error) { throw Self.trashUnavailable }
            throw VFSError.from(error, path: path)
        }
        return (resulting as URL?).map { VFSPath.local($0) }
    }

    public func deletePermanently(_ path: VFSPath) async throws {
        try deleteSync(path)
    }

    public func deleteSync(_ path: VFSPath) throws {
        try requireLocal(path)

        guard let url = path.url else { throw VFSError.unsupported("delete") }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw VFSError.from(error, path: path)
        }
    }

    public func setAttributes(_ path: VFSPath, _ change: AttributeChange) async throws {
        try setAttributesSync(path, change)
    }

    public func setAttributesSync(_ path: VFSPath, _ change: AttributeChange) throws {
        try requireLocal(path)

        var st = stat()
        guard lstat(path.path, &st) == 0 else { throw VFSError.from(errno: errno, path: path) }
        let wasLocked = st.st_flags & UInt32(UF_IMMUTABLE) != 0
        // Zablokowany element trzeba odblokować przed innymi zmianami.
        if wasLocked, change.locked != true || change.permissions != nil || change.modified != nil || change.created != nil {
            guard lchflags(path.path, st.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
                throw VFSError.from(errno: errno, path: path)
            }
            st.st_flags &= ~UInt32(UF_IMMUTABLE)
        }
        if let mode = change.permissions {
            guard lchmod(path.path, mode_t(mode)) == 0 else { throw VFSError.from(errno: errno, path: path) }
        }
        if change.owner != nil || change.group != nil {
            let uid = change.owner.map { uid_t($0) } ?? uid_t.max
            let gid = change.group.map { gid_t($0) } ?? gid_t.max
            guard lchown(path.path, uid, gid) == 0 else { throw VFSError.from(errno: errno, path: path) }
        }
        if change.modified != nil || change.created != nil, let url = path.url {
            var values = URLResourceValues()
            if let m = change.modified { values.contentModificationDate = m }
            if let c = change.created { values.creationDate = c }
            var mutable = url
            do { try mutable.setResourceValues(values) } catch { throw VFSError.from(error, path: path) }
        }
        var flags = st.st_flags
        if let hidden = change.hidden { flags = hidden ? flags | UInt32(UF_HIDDEN) : flags & ~UInt32(UF_HIDDEN) }
        let lockNow = change.locked ?? wasLocked
        flags = lockNow ? flags | UInt32(UF_IMMUTABLE) : flags & ~UInt32(UF_IMMUTABLE)
        if flags != st.st_flags {
            guard lchflags(path.path, flags) == 0 else { throw VFSError.from(errno: errno, path: path) }
        }
    }

    public func tags(of path: VFSPath) async throws -> [String] {
        try tagsSync(of: path)
    }

    public func tagsSync(of path: VFSPath) throws -> [String] {
        try requireLocal(path)

        guard let url = path.url else { return [] }
        do {
            return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        } catch {
            throw VFSError.from(error, path: path)
        }
    }

    public func setTags(_ tags: [String], on path: VFSPath) async throws {
        try setTagsSync(tags, on: path)
    }

    public func setTagsSync(_ tags: [String], on path: VFSPath) throws {
        try requireLocal(path)

        guard let url = path.url else { throw VFSError.unsupported("tags") }
        do {
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        } catch {
            throw VFSError.from(error, path: path)
        }
    }
}
