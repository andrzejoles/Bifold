import Darwin
import Foundation
import Security

/// Wąska lista operacji pomocnika uprawnień administratora. Nic poza nią nie jest możliwe —
/// pomocnik nie wykonuje poleceń powłoki ani dowolnych programów.
public enum HelperOperation: String, Codable, Sendable, CaseIterable {
    case setOwner, setPermissions, createDirectory, move, copy, remove

    /// Prawo w bazie autoryzacji (każda operacja osobno, zawsze z hasłem administratora).
    public var right: String { "\(HelperConstants.machService).\(rawValue)" }

    public var prompt: String {
        switch self {
        case .setOwner: "Bifold chce zmienić właściciela pliku."
        case .setPermissions: "Bifold chce zmienić uprawnienia pliku."
        case .createDirectory: "Bifold chce utworzyć katalog w chronionym miejscu."
        case .move: "Bifold chce przenieść element w chronionym miejscu."
        case .copy: "Bifold chce skopiować element do chronionego miejsca."
        case .remove: "Bifold chce trwale usunąć element z chronionego miejsca."
        }
    }
}

public enum HelperConstants {
    /// Nazwa usługi Mach = etykieta demona = `$(BIFOLD_BUNDLE_ID).helper` (`Config/Brand.xcconfig`):
    /// z klucza `BifoldHelperMachService` w Info.plist, a bez niego z identyfikatora pakietu (aplikacja
    /// `X` → `X.helper`; pomocnik ma już identyfikator `X.helper`).
    public static let machService: String = machService(info: Bundle.main.object(forInfoDictionaryKey: "BifoldHelperMachService") as? String,
                                                        bundleIdentifier: Bundle.main.bundleIdentifier)
    /// Plik demona w `Contents/Library/LaunchDaemons` (generowany przy budowaniu z `Brand.xcconfig`).
    public static var plistName: String { machService + ".plist" }
    public static let protocolVersion = 1

    static func machService(info: String?, bundleIdentifier: String?) -> String {
        if let info, !info.isEmpty, !info.hasPrefix("$(") { return info }
        guard let id = bundleIdentifier, !id.isEmpty else { return "bifold.helper" }
        return id.hasSuffix(".helper") ? id : id + ".helper"
    }
}

public struct HelperRequest: Codable, Sendable, Equatable {
    public var version = HelperConstants.protocolVersion
    public var operation: HelperOperation
    public var paths: [String]
    public var owner: UInt32?
    public var group: UInt32?
    public var mode: UInt16?

    public init(operation: HelperOperation, paths: [String], owner: UInt32? = nil, group: UInt32? = nil, mode: UInt16? = nil) {
        self.operation = operation
        self.paths = paths
        self.owner = owner
        self.group = group
        self.mode = mode
    }
}

public struct HelperReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

/// Protokół XPC (Obj-C), dane jako JSON — mniejsza powierzchnia niż obiekty NSSecureCoding.
@objc public protocol BifoldHelperProtocol {
    func perform(_ request: Data, authorization: Data, reply: @escaping @Sendable (Data) -> Void)
    func version(reply: @escaping @Sendable (Int) -> Void)
}

public enum HelperError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case forbiddenPath(String)
    case notAuthorized
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let m): "Nieprawidłowe żądanie: \(m)"
        case .forbiddenPath(let p): "Ścieżka niedozwolona dla pomocnika: \(p)"
        case .notAuthorized: "Brak autoryzacji administratora"
        case .failed(let m): m
        }
    }
}

/// Walidacja i wykonanie żądań (wspólne dla demona i testów; demon działa jako root).
public enum HelperOperations {
    /// Katalogi, których pomocnik nie ruszy nigdy (SIP i tak chroni część z nich).
    public static let forbiddenPrefixes = [
        "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/private/var/db",
        "/Library/Apple", "/private/etc/sudoers", "/etc/sudoers", "/private/etc/sudoers.d", "/etc/sudoers.d",
        "/private/var/root", "/Library/Keychains", "/Library/LaunchDaemons", "/Library/LaunchAgents",
        "/private/etc/pam.d", "/private/etc/ssh",
    ]

    /// Katalogi najwyższego poziomu: zawartość wolno zmieniać (np. program w /Applications), ale nie
    /// sam katalog (usunięcie /Users albo zmiana właściciela /usr zniszczyłyby system).
    public static let protectedDirectories = [
        "/Library", "/private", "/usr", "/Applications", "/Users", "/System", "/Volumes", "/etc", "/var", "/tmp",
        "/private/var", "/private/etc", "/private/tmp", "/usr/local", "/opt", "/cores", "/Network",
    ]

    /// Ścieżka absolutna, znormalizowana; rodzic rozwiązany przez realpath (bez sztuczek z `..`
    /// i dowiązaniami); nie korzeń i nie katalog zabroniony.
    public static func validate(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { throw HelperError.invalidRequest("ścieżka musi być absolutna") }
        let comps = raw.split(separator: "/").map(String.init)
        guard !comps.contains(".."), !comps.contains("."), !comps.isEmpty else { throw HelperError.forbiddenPath(raw) }
        let parent = "/" + comps.dropLast().joined(separator: "/")
        guard let realParent = realpath(parent, nil).map({ p -> String in defer { free(p) }; return String(cString: p) }) else {
            throw HelperError.invalidRequest("katalog nadrzędny nie istnieje: \(parent)")
        }
        let path = (realParent == "/" ? "" : realParent) + "/" + comps.last!
        // Bez rozróżniania wielkości liter: APFS domyślnie jej nie rozróżnia, a realpath poprawia tylko
        // rodzica — „/private/etc/SUDOERS” to ten sam plik co „/private/etc/sudoers”. Składanie wielkości
        // liter Unicode jak w APFS, a nie `lowercased()`: „LaunchDaemonſ” (długie s) i „\u{212A}eychains”
        // (znak kelwina) to w APFS te same nazwy co „LaunchDaemons” i „Keychains”.
        let folded = fold(path)
        // Katalog zabroniony, jego wnętrze albo jego przodek (`remove /Library` usunąłby też
        // /Library/Keychains, `move /private/etc` — sudoers).
        for f in forbiddenPrefixes.map(fold) where folded == f || folded.hasPrefix(f + "/") || f.hasPrefix(folded + "/") {
            throw HelperError.forbiddenPath(path)
        }
        for d in protectedDirectories.map(fold) where folded == d {
            throw HelperError.forbiddenPath(path)
        }
        guard path != "/" else { throw HelperError.forbiddenPath(path) }
        return path
    }

    /// Postać do porównań: składanie wielkości liter Unicode (ſ → s, K → k, ß → ss) i NFC.
    static func fold(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    public static func check(_ r: HelperRequest) throws -> [String] {
        guard r.version == HelperConstants.protocolVersion else { throw HelperError.invalidRequest("wersja") }
        let expected: Int = switch r.operation {
        case .move, .copy: 2
        default: 1
        }
        guard r.paths.count == expected else { throw HelperError.invalidRequest("liczba ścieżek") }
        let paths = try r.paths.map(validate)
        switch r.operation {
        case .setOwner: guard r.owner != nil || r.group != nil else { throw HelperError.invalidRequest("owner/group") }
        case .setPermissions: guard let m = r.mode, m <= 0o7777 else { throw HelperError.invalidRequest("mode") }
        default: break
        }
        return paths
    }

    /// Wykonanie (po weryfikacji autoryzacji). Operacje na pojedynczych elementach, bez
    /// podążania za dowiązaniami tam, gdzie się da.
    public static func execute(_ r: HelperRequest) throws -> String {
        let paths = try check(r)
        let fm = FileManager.default
        do {
            switch r.operation {
            case .setOwner:
                guard lchown(paths[0], r.owner.map { uid_t($0) } ?? uid_t.max, r.group.map { gid_t($0) } ?? gid_t.max) == 0 else { throw posix() }
            case .setPermissions:
                guard lchmod(paths[0], mode_t(r.mode!)) == 0 else { throw posix() }
            case .createDirectory:
                guard mkdir(paths[0], 0o755) == 0 else { throw posix() }
            case .move:
                guard renamex_np(paths[0], paths[1], UInt32(RENAME_EXCL)) == 0 else { throw posix() }
            case .copy:
                try fm.copyItem(atPath: paths[0], toPath: paths[1])
            case .remove:
                try fm.removeItem(atPath: paths[0])
            }
        } catch let e as HelperError {
            throw e
        } catch {
            throw HelperError.failed(error.localizedDescription)
        }
        return "\(r.operation.rawValue): \(paths.joined(separator: " → "))"
    }

    static func posix() -> HelperError { HelperError.failed(String(cString: strerror(errno))) }

    // MARK: Autoryzacja

    /// Reguła prawa: zawsze hasło administratora, bez współdzielenia i bez pamiętania.
    public static var rightRule: [String: Any] { [
        "class": "user", "group": "admin", "timeout": 0, "shared": false, "version": 1, "authenticate-user": true,
    ] }

    /// Weryfikacja po stronie demona: zewnętrzna forma autoryzacji od klienta musi dawać
    /// prawo tej konkretnej operacji (bez interakcji — klient już zapytał użytkownika).
    public static func verify(authorization data: Data, for operation: HelperOperation) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var ext = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &ext) { data.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&ext, &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        return operation.right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
            }
        }
    }
}
