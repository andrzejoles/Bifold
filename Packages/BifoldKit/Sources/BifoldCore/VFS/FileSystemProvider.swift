import Foundation
import Synchronization

public enum VFSError: Error, Sendable, Equatable, LocalizedError {
    case notFound(VFSPath)
    case permissionDenied(VFSPath)
    case alreadyExists(VFSPath)
    case notADirectory(VFSPath)
    case invalidName(String)
    case unsupported(String)
    case cancelled
    case io(path: VFSPath, code: Int32)
    case destinationInsideSource(VFSPath)
    case crossProvider

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): L10n.tr("Nie znaleziono: \(p.description)")
        case .permissionDenied(let p): L10n.tr("Brak uprawnień: \(p.description)")
        case .alreadyExists(let p): L10n.tr("Element już istnieje: \(p.description)")
        case .notADirectory(let p): L10n.tr("To nie jest katalog: \(p.description)")
        case .invalidName(let n): L10n.tr("Nieprawidłowa nazwa: \(n)")
        case .unsupported(let op): L10n.tr("Operacja nieobsługiwana: \(op)")
        case .cancelled: L10n.tr("Anulowano")
        case .io(let p, let code): L10n.tr("Błąd wejścia/wyjścia (\(String(cString: strerror(code)))): \(p.description)")
        case .destinationInsideSource(let p): L10n.tr("Nie można skopiować katalogu do jego wnętrza: \(p.description)")
        case .crossProvider: L10n.tr("Operacja między tymi systemami plików nie jest jeszcze obsługiwana")
        }
    }

    /// Mapowanie `errno` na błąd VFS.
    public static func from(errno code: Int32, path: VFSPath) -> VFSError {
        switch code {
        case ENOENT: .notFound(path)
        case EACCES, EPERM: .permissionDenied(path)
        case EEXIST: .alreadyExists(path)
        case ENOTDIR: .notADirectory(path)
        case ECANCELED: .cancelled
        default: .io(path: path, code: code)
        }
    }

    public static func from(_ error: any Error, path: VFSPath) -> VFSError {
        if let e = error as? VFSError { return e }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return from(errno: Int32(ns.code), path: path) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return from(errno: Int32(underlying.code), path: path)
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound(path)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .permissionDenied(path)
            case NSFileWriteFileExistsError: return .alreadyExists(path)
            case NSUserCancelledError: return .cancelled
            default: break
            }
        }
        return .io(path: path, code: EIO)
    }
}

public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = ProviderCapabilities(rawValue: 1 << 0)
    public static let write = ProviderCapabilities(rawValue: 1 << 1)
    public static let trash = ProviderCapabilities(rawValue: 1 << 2)
    public static let watch = ProviderCapabilities(rawValue: 1 << 3)
    public static let attributes = ProviderCapabilities(rawValue: 1 << 4)
    public static let tags = ProviderCapabilities(rawValue: 1 << 5)

    public static let all: ProviderCapabilities = [.read, .write, .trash, .watch, .attributes, .tags]
}

public struct ListOptions: Sendable, Hashable {
    public var includeHidden: Bool
    public init(includeHidden: Bool = true) { self.includeHidden = includeHidden }
}

public enum DirectoryChange: Sendable, Hashable {
    /// Coś się zmieniło w katalogu — trzeba odświeżyć listing.
    case contentsChanged
    /// Sam katalog zniknął lub został przeniesiony.
    case directoryRemoved
}

/// Wspólny interfejs wszystkich systemów plików (lokalny, archiwa, serwery, urządzenia).
/// Panele, kolejka operacji, wyszukiwanie i API agenta używają wyłącznie tego protokołu.
public protocol FileSystemProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    func list(_ directory: VFSPath, options: ListOptions) async throws -> [FileItem]
    func item(at path: VFSPath) async throws -> FileItem
    func exists(_ path: VFSPath) async -> Bool
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data
    func watch(_ directory: VFSPath) -> AsyncStream<DirectoryChange>
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo

    func createDirectory(_ path: VFSPath) async throws
    func createFile(_ path: VFSPath, contents: Data) async throws
    func rename(_ path: VFSPath, to newName: String) async throws -> VFSPath
    /// Przenosi do Kosza i zwraca nową ścieżkę elementu w Koszu (potrzebna do cofania).
    func trash(_ path: VFSPath) async throws -> VFSPath?
    func deletePermanently(_ path: VFSPath) async throws
    func setAttributes(_ path: VFSPath, _ change: AttributeChange) async throws
    func tags(of path: VFSPath) async throws -> [String]
    func setTags(_ tags: [String], on path: VFSPath) async throws
    /// Plik, w którym żyje wirtualny system plików (archiwum) — „w górę” z korzenia wraca do niego.
    var hostLocation: VFSPath? { get }
}

extension FileSystemProvider {
    public var hostLocation: VFSPath? { nil }

    public func exists(_ path: VFSPath) async -> Bool {
        (try? await item(at: path)) != nil
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<DirectoryChange> {
        AsyncStream { $0.finish() }
    }

    public func createDirectory(_ path: VFSPath) async throws { throw VFSError.unsupported("createDirectory") }
    public func createFile(_ path: VFSPath, contents: Data) async throws { throw VFSError.unsupported("createFile") }
    public func rename(_ path: VFSPath, to newName: String) async throws -> VFSPath { throw VFSError.unsupported("rename") }
    public func trash(_ path: VFSPath) async throws -> VFSPath? { throw VFSError.unsupported("trash") }
    public func deletePermanently(_ path: VFSPath) async throws { throw VFSError.unsupported("delete") }
    public func setAttributes(_ path: VFSPath, _ change: AttributeChange) async throws { throw VFSError.unsupported("setAttributes") }
    public func tags(of path: VFSPath) async throws -> [String] { [] }
    public func setTags(_ tags: [String], on path: VFSPath) async throws { throw VFSError.unsupported("setTags") }
}

/// Rejestr dostawców: `ProviderID` → implementacja.
public final class ProviderRegistry: Sendable {
    private let providers: Mutex<[ProviderID: any FileSystemProvider]>

    public init(_ providers: [any FileSystemProvider] = [LocalFS()]) {
        self.providers = Mutex(Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) }))
    }

    public func register(_ provider: any FileSystemProvider) {
        providers.withLock { $0[provider.id] = provider }
    }

    public func unregister(_ id: ProviderID) {
        providers.withLock { _ = $0.removeValue(forKey: id) }
    }

    public func provider(for id: ProviderID) throws -> any FileSystemProvider {
        guard let p = providers.withLock({ $0[id] }) else { throw VFSError.unsupported("provider \(id)") }
        return p
    }

    public func provider(for path: VFSPath) throws -> any FileSystemProvider {
        try provider(for: path.provider)
    }
}

/// Sprawdza poprawność nazwy pojedynczego elementu.
public func validateFileName(_ name: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
          name.utf8.count <= 255
    else { throw VFSError.invalidName(name) }
}
