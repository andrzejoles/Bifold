import Foundation

public enum FileKind: String, Codable, Sendable, Hashable {
    case file, directory, symlink, other
}

public struct FileFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// `UF_HIDDEN` — ukryty flagą (niezależnie od kropki w nazwie).
    public static let hidden = FileFlags(rawValue: 1 << 0)
    /// `UF_IMMUTABLE` / `SF_IMMUTABLE` — zablokowany.
    public static let locked = FileFlags(rawValue: 1 << 1)
    /// Dowiązanie symboliczne wskazujące na katalog.
    public static let symlinkToDirectory = FileFlags(rawValue: 1 << 2)
}

/// Element katalogu. Struktura wartościowa — panele trzymają tablice po 100 000 elementów.
public struct FileItem: Hashable, Sendable, Identifiable, Codable {
    public var id: VFSPath { path }
    public var path: VFSPath
    public var name: String
    public var kind: FileKind
    /// Rozmiar w bajtach; dla katalogów `-1`, dopóki nie policzono.
    public var size: Int64
    public var modified: Date?
    public var created: Date?
    /// Bity uprawnień POSIX (0o7777).
    public var permissions: UInt16
    public var owner: UInt32
    public var group: UInt32
    public var flags: FileFlags
    public var inode: UInt64

    public init(
        path: VFSPath, name: String? = nil, kind: FileKind, size: Int64 = -1,
        modified: Date? = nil, created: Date? = nil, permissions: UInt16 = 0o644,
        owner: UInt32 = 0, group: UInt32 = 0, flags: FileFlags = [], inode: UInt64 = 0
    ) {
        self.path = path
        self.name = name ?? path.name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.flags = flags
        self.inode = inode
    }

    public var isDirectory: Bool { kind == .directory }
    /// Katalog lub dowiązanie do katalogu — można do niego wejść.
    public var isNavigable: Bool { kind == .directory || flags.contains(.symlinkToDirectory) }
    public var isHidden: Bool { name.hasPrefix(".") || flags.contains(.hidden) }
    public var isExecutable: Bool { kind == .file && permissions & 0o111 != 0 }
    public var isReadOnly: Bool { permissions & 0o200 == 0 || flags.contains(.locked) }
    public var fileExtension: String { isDirectory ? "" : name.fileExtension }

    /// Odcisk do wykrywania zmian przed cofnięciem operacji.
    public var fingerprint: Fingerprint {
        Fingerprint(size: isDirectory ? nil : size, modified: modified, inode: inode)
    }
}

public struct Fingerprint: Codable, Sendable, Hashable {
    public var size: Int64?
    public var modified: Date?
    public var inode: UInt64

    public init(size: Int64?, modified: Date?, inode: UInt64) {
        self.size = size
        self.modified = modified
        self.inode = inode
    }

    /// Porównanie z tolerancją 1 ms dla dat (różne systemy plików mają różną precyzję).
    public func matches(_ other: Fingerprint) -> Bool {
        guard size == other.size, inode == other.inode || inode == 0 || other.inode == 0 else { return false }
        switch (modified, other.modified) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 0.001
        default: return false
        }
    }
}

/// Zmiana atrybutów (wartości `nil` = bez zmian).
public struct AttributeChange: Codable, Sendable, Hashable {
    public var permissions: UInt16?
    public var owner: UInt32?
    public var group: UInt32?
    public var modified: Date?
    public var created: Date?
    public var hidden: Bool?
    public var locked: Bool?

    public init(
        permissions: UInt16? = nil, owner: UInt32? = nil, group: UInt32? = nil,
        modified: Date? = nil, created: Date? = nil, hidden: Bool? = nil, locked: Bool? = nil
    ) {
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.modified = modified
        self.created = created
        self.hidden = hidden
        self.locked = locked
    }

    public var isEmpty: Bool {
        permissions == nil && owner == nil && group == nil && modified == nil && created == nil
            && hidden == nil && locked == nil
    }
}

public struct VolumeInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: VFSPath { path }
    public var path: VFSPath
    public var name: String
    public var totalCapacity: Int64
    public var availableCapacity: Int64
    public var fileSystem: String
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var isNetwork: Bool
    public var isReadOnly: Bool

    public init(
        path: VFSPath, name: String, totalCapacity: Int64, availableCapacity: Int64,
        fileSystem: String = "", isRemovable: Bool = false, isEjectable: Bool = false,
        isInternal: Bool = true, isNetwork: Bool = false, isReadOnly: Bool = false
    ) {
        self.path = path
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.fileSystem = fileSystem
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isNetwork = isNetwork
        self.isReadOnly = isReadOnly
    }
}
