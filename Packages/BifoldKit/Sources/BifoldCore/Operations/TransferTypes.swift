import Foundation

public enum TransferKind: String, Codable, Sendable, Hashable {
    case copy, move
}

/// Kopiowanie lub przenoszenie elementów do katalogu docelowego.
public struct TransferRequest: Codable, Sendable, Hashable {
    public var kind: TransferKind
    public var sources: [VFSPath]
    public var destinationDirectory: VFSPath
    /// Nowa nazwa — tylko przy jednym elemencie źródłowym.
    public var newName: String?

    public init(kind: TransferKind, sources: [VFSPath], destinationDirectory: VFSPath, newName: String? = nil) {
        self.kind = kind
        self.sources = sources
        self.destinationDirectory = destinationDirectory
        self.newName = newName
    }

    func destination(for source: VFSPath) -> VFSPath {
        let name = sources.count == 1 ? (newName ?? source.name) : source.name
        return destinationDirectory.appending(name)
    }
}

public enum ConflictResolution: String, Codable, Sendable, CaseIterable, Hashable {
    case overwrite, skip, rename, overwriteOlder, cancel
}

public struct ConflictDecision: Sendable, Hashable {
    public var resolution: ConflictResolution
    public var applyToAll: Bool

    public init(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

public struct FileConflict: Sendable, Hashable {
    public var source: FileItem
    public var destination: FileItem
    public var kind: TransferKind
}

public enum ErrorDecision: Sendable, Hashable {
    case skip, skipAll, retry, cancel
}

/// Decyzje w trakcie zadania (okna dialogowe w interfejsie, polityka dla agenta, atrapy w testach).
public protocol TransferDelegate: Sendable {
    func resolveConflict(_ conflict: FileConflict) async -> ConflictDecision
    func resolveError(path: VFSPath, error: VFSError) async -> ErrorDecision
}

/// Delegat bez interakcji: stała decyzja przy konflikcie, błędy pomijane.
public struct PolicyTransferDelegate: TransferDelegate {
    public var conflict: ConflictResolution
    public init(conflict: ConflictResolution) { self.conflict = conflict }
    public func resolveConflict(_ conflict: FileConflict) async -> ConflictDecision { ConflictDecision(self.conflict, applyToAll: true) }
    public func resolveError(path: VFSPath, error: VFSError) async -> ErrorDecision { .skip }
}

public struct TransferProgress: Sendable, Hashable {
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var filesDone: Int = 0
    public var filesTotal: Int = 0
    public var currentItem: String = ""
    public var bytesPerSecond: Double = 0

    public init() {}

    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return min(1, Double(filesDone) / Double(filesTotal)) }
        return 0
    }
}

/// Element podglądu operacji („na sucho”).
public struct PlannedOperation: Codable, Sendable, Hashable {
    public var kind: String
    public var source: VFSPath?
    public var destination: VFSPath?
    public var isDirectory: Bool
    public var bytes: Int64
    public var conflict: Bool

    public init(kind: String, source: VFSPath?, destination: VFSPath?, isDirectory: Bool = false, bytes: Int64 = 0, conflict: Bool = false) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.conflict = conflict
    }
}

/// Wynik planowania przeniesienia: liczby i konflikty (do podglądu i paska postępu).
public struct TransferPlan: Sendable, Hashable {
    public var request: TransferRequest
    public var operations: [PlannedOperation]
    public var totalBytes: Int64
    public var fileCount: Int
    public var directoryCount: Int
    /// Ścieżki docelowe, które już istnieją (pliki; katalogi są scalane).
    public var conflicts: [VFSPath]
    /// Rozmiary poddrzew katalogów źródłowych (do postępu przy szybkim przenoszeniu).
    var subtreeSizes: [VFSPath: DirectorySize]
}
