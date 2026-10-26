import BifoldCore
import Foundation

public enum AppTheme: String, Codable, Sendable, CaseIterable {
    case system, light, dark

    public var displayName: String {
        switch self {
        case .system: L10n.tr("Systemowy")
        case .light: L10n.tr("Jasny")
        case .dark: L10n.tr("Ciemny")
        }
    }
}

/// Ustawienia agentów AI (Etap 2). Ścieżki zablokowane są edytowalne.
public struct AgentSettings: Codable, Sendable, Equatable {
    public var strictMode = true
    public var maxReadBytes: Int64 = 2 * 1024 * 1024
    public var callsPerMinute = 120
    public var blockedPaths: [String] = AgentSettings.defaultBlockedPaths
    public var accessOverrides: [String: AgentAccess] = [:]

    public static let defaultBlockedPaths = [
        "~/.ssh", "~/.gnupg", "~/.aws", "~/.config/gcloud", "~/.kube", "~/.docker/config.json", "~/.netrc",
        "~/Library/Keychains", "~/Library/Application Support/Bifold", "~/.config/rclone",
        "~/Library/Application Support/Google/Chrome", "~/Library/Application Support/Firefox",
        "~/Library/Safari", "~/Library/Application Support/Microsoft Edge", "~/Library/Application Support/BraveSoftware",
        "~/Library/Cookies", "~/Library/Mail", "~/Library/Messages", "~/.claude", "~/.codex", "~/.grok", "~/.gemini",
    ]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSettings()
        strictMode = try c.decodeIfPresent(Bool.self, forKey: .strictMode) ?? d.strictMode
        maxReadBytes = try c.decodeIfPresent(Int64.self, forKey: .maxReadBytes) ?? d.maxReadBytes
        callsPerMinute = try c.decodeIfPresent(Int.self, forKey: .callsPerMinute) ?? d.callsPerMinute
        blockedPaths = try c.decodeIfPresent([String].self, forKey: .blockedPaths) ?? d.blockedPaths
        accessOverrides = try c.decodeIfPresent([String: AgentAccess].self, forKey: .accessOverrides) ?? [:]
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public var shortcutProfile: ShortcutProfile = .totalCommander
    /// Skrót → id komendy (pusty id = usuń domyślny skrót).
    public var keyOverrides: [String: String] = [:]
    public var theme: AppTheme = .system
    public var showHiddenFiles = false
    public var fontSize: Double = 13
    public var editorBundleID = "org.nextpadplusplus.mac"
    public var editorPath = "/Applications/Nextpad++.app"
    public var toolsDirectory = "/opt/homebrew/bin"
    public var confirmTrash = true
    public var showTreeByDefault = false
    public var agent = AgentSettings()

    public init() {}

    // Odporność na stare/niepełne pliki: brakujące klucze = wartości domyślne.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        shortcutProfile = try c.decodeIfPresent(ShortcutProfile.self, forKey: .shortcutProfile) ?? d.shortcutProfile
        keyOverrides = try c.decodeIfPresent([String: String].self, forKey: .keyOverrides) ?? d.keyOverrides
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? d.theme
        showHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? d.showHiddenFiles
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        editorBundleID = try c.decodeIfPresent(String.self, forKey: .editorBundleID) ?? d.editorBundleID
        editorPath = try c.decodeIfPresent(String.self, forKey: .editorPath) ?? d.editorPath
        toolsDirectory = try c.decodeIfPresent(String.self, forKey: .toolsDirectory) ?? d.toolsDirectory
        confirmTrash = try c.decodeIfPresent(Bool.self, forKey: .confirmTrash) ?? d.confirmTrash
        showTreeByDefault = try c.decodeIfPresent(Bool.self, forKey: .showTreeByDefault) ?? d.showTreeByDefault
        agent = try c.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? d.agent
    }

    /// Ścieżka do narzędzia CLI (np. `rg`, `7zz`, `rclone`) albo `nil`, jeśli go brak.
    public func toolPath(_ name: String) -> String? {
        let p = (expandTilde(toolsDirectory) as NSString).appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}

/// Odczyt i zapis plików JSON w katalogu aplikacji (zapis atomowy).
public enum JSONStore {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        // Tylko właściciel (adresy serwerów i nazwy użytkowników w connections.json; hasła są w Keychain).
        chmod(url.path, 0o600)
    }
}

/// Zablokowane ścieżki i normalizacja ścieżek od agenta (SECURITY.md §4.5).
public struct BlockedPaths: Sendable {
    private let prefixes: [[String]]

    public init(_ patterns: [String], home: String = NSHomeDirectory()) {
        var all: [[String]] = []
        for p in patterns {
            let expanded = VFSPath.normalize(expandTilde(p, home: home))
            all.append(Self.components(expanded))
            // Także postać rzeczywista (dowiązania, /private/…).
            if let real = realPath(expanded), real != expanded { all.append(Self.components(real)) }
        }
        prefixes = all.filter { !$0.isEmpty }
    }

    /// Lista blokad agenta: z ustawień oraz katalog danych aplikacji wyznaczony w czasie działania
    /// (także przy `BIFOLD_DATA_DIR` albo innej nazwie aplikacji — `connections.json`, dzienniki
    /// i gniazdo nigdy nie są dostępne dla agenta).
    @MainActor
    public init(for workspace: Workspace) {
        self.init(workspace.settings.agent.blockedPaths + [workspace.paths.root.path(percentEncoded: false)])
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.lowercased() }
    }

    /// Ścieżka rzeczywista: `~`, `.`, `..` i dowiązania symboliczne najdłuższego istniejącego
    /// prefiksu rozwiązane — żeby „~/x/../.ssh” albo dowiązanie do ~/.ssh nie omijały blokady.
    public static func canonical(_ path: String, home: String = NSHomeDirectory()) -> String {
        let normalized = VFSPath.normalize(expandTilde(path, home: home))
        var existing = normalized
        var rest: [String] = []
        while realPath(existing) == nil, existing != "/" {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let base = realPath(existing) ?? existing
        return VFSPath.normalize(([base] + rest).joined(separator: "/"))
    }

    private func candidates(_ path: String) -> [[String]] {
        Set([VFSPath.normalize(expandTilde(path)), Self.canonical(path)]).map(Self.components)
    }

    public func isBlocked(_ path: String) -> Bool {
        candidates(path).contains { comps in
            prefixes.contains { prefix in comps.count >= prefix.count && Array(comps.prefix(prefix.count)) == prefix }
        }
    }

    public func isBlocked(_ path: VFSPath) -> Bool {
        path.isLocal && isBlocked(path.path)
    }

    /// Czy w poddrzewie `path` leży zablokowana ścieżka (`path` jest nią albo jej przodkiem).
    /// Operacja rekurencyjna agenta na takim katalogu (kopiowanie, przenoszenie, Kosz, archiwum,
    /// synchronizacja) ominęłaby blokadę.
    public func containsBlocked(_ path: VFSPath) -> Bool {
        guard path.isLocal else { return false }
        if isBlocked(path) { return true }
        return candidates(path.path).contains { comps in
            prefixes.contains { prefix in prefix.count > comps.count && Array(prefix.prefix(comps.count)) == comps }
        }
    }
}
