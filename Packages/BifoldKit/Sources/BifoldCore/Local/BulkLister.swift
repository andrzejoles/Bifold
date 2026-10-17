import Darwin
import Foundation

/// Szybkie listowanie katalogu przez `getattrlistbulk(2)`: jedno wywołanie systemowe zwraca
/// atrybuty wielu elementów naraz, bez osobnego `stat` dla każdego pliku.
enum BulkLister {
    static let bufferSize = 512 * 1024

    static func list(_ directory: VFSPath) throws -> [FileItem] {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw VFSError.from(errno: errno, path: directory) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        var common = attrgroup_t(0)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_CRTIME)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_OWNERID)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_GRPID)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_ACCESSMASK)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
        common |= attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID)
        request.commonattr = common
        request.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var items: [FileItem] = []
        items.reserveCapacity(256)
        let options = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS)
        let prefix = directory.isRoot ? "/" : directory.path + "/"

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, options)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw VFSError.from(errno: errno, path: directory)
            }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let item = parse(entry: entry, length: length, provider: directory.provider, prefix: prefix) {
                    items.append(item)
                }
                entry += length
            }
        }
        resolveSymlinkTargets(&items)
        return items
    }

    /// Układ wpisu (FSOPT_PACK_INVAL_ATTRS — wszystkie atrybuty obecne, w kolejności bitów,
    /// ATTR_CMN_ERROR zaraz po ATTR_CMN_RETURNED_ATTRS):
    /// length · returned · error · name · objtype · crtime · modtime · uid · gid · mode · flags · fileid · datalength
    private static func parse(entry: UnsafeRawPointer, length: Int, provider: ProviderID, prefix: String) -> FileItem? {
        let end = entry + length
        var p = entry + 4
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        let error = p.loadUnaligned(as: UInt32.self)
        p += 4
        if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR) != 0, error != 0 { return nil }

        let nameRefStart = p
        let nameOffset = Int(p.loadUnaligned(as: Int32.self))
        let nameLength = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        p += 8
        guard nameLength > 1, nameRefStart + nameOffset + nameLength <= end else { return nil }
        let namePtr = (nameRefStart + nameOffset).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePtr)

        let objType = p.loadUnaligned(as: UInt32.self)
        p += 4
        let crtime = p.loadUnaligned(as: timespec.self)
        p += MemoryLayout<timespec>.size
        let mtime = p.loadUnaligned(as: timespec.self)
        p += MemoryLayout<timespec>.size
        let uid = p.loadUnaligned(as: UInt32.self)
        p += 4
        let gid = p.loadUnaligned(as: UInt32.self)
        p += 4
        let mode = p.loadUnaligned(as: UInt32.self)
        p += 4
        let bsdFlags = p.loadUnaligned(as: UInt32.self)
        p += 4
        let fileID = p.loadUnaligned(as: UInt64.self)
        p += 8
        var dataLength: Int64 = 0
        if p + 8 <= end {
            dataLength = p.loadUnaligned(as: Int64.self)
        }

        let kind: FileKind
        switch objType {
        case UInt32(VREG.rawValue): kind = .file
        case UInt32(VDIR.rawValue): kind = .directory
        case UInt32(VLNK.rawValue): kind = .symlink
        default: kind = .other
        }

        var flags: FileFlags = []
        if bsdFlags & UInt32(UF_HIDDEN) != 0 { flags.insert(.hidden) }
        if bsdFlags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { flags.insert(.locked) }

        let returnedCrtime = returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_CRTIME) != 0
        return FileItem(
            path: VFSPath(provider: provider, normalizedPath: prefix + name),
            name: name,
            kind: kind,
            size: kind == .directory ? -1 : dataLength,
            modified: Date(timespec: mtime),
            created: returnedCrtime ? Date(timespec: crtime) : nil,
            permissions: UInt16(mode & 0o7777),
            owner: uid,
            group: gid,
            flags: flags,
            inode: fileID
        )
    }

    /// Dowiązania do katalogów oznaczamy flagą, żeby dało się do nich wejść.
    static func resolveSymlinkTargets(_ items: inout [FileItem]) {
        for i in items.indices where items[i].kind == .symlink {
            var st = stat()
            if stat(items[i].path.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR {
                items[i].flags.insert(.symlinkToDirectory)
            }
        }
    }
}

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}

extension FileItem {
    /// Element z wyniku `lstat`.
    init(stat st: stat, path: VFSPath) {
        let kind: FileKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        var flags: FileFlags = []
        if st.st_flags & UInt32(UF_HIDDEN) != 0 { flags.insert(.hidden) }
        if st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { flags.insert(.locked) }
        self.init(
            path: path,
            kind: kind,
            size: kind == .directory ? -1 : Int64(st.st_size),
            modified: Date(timespec: st.st_mtimespec),
            created: Date(timespec: st.st_birthtimespec),
            permissions: UInt16(st.st_mode & 0o7777),
            owner: st.st_uid,
            group: st.st_gid,
            flags: flags,
            inode: st.st_ino
        )
    }
}
