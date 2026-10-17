import Foundation
import Security

/// Rodzaj zdalnego zasobu (typ backendu rclone).
public enum RemoteKind: String, Codable, Sendable, CaseIterable {
    case sftp, ftp, ftps, webdav, smb, drive, dropbox, onedrive

    public var displayName: String {
        switch self {
        case .sftp: "SFTP"
        case .ftp: "FTP"
        case .ftps: "FTPS"
        case .webdav: "WebDAV"
        case .smb: "SMB"
        case .drive: "Google Drive"
        case .dropbox: "Dropbox"
        case .onedrive: "OneDrive"
        }
    }

    var backend: String { self == .ftps ? "ftp" : rawValue }

    /// Chmury: logowanie OAuth przez `rclone authorize`, wykonywane przez użytkownika.
    public var usesOAuth: Bool { [.drive, .dropbox, .onedrive].contains(self) }

    /// Poziom agenta dla zasobu (PROMPT.md 5.5): FTP/FTPS zapis za zgodą, reszta tylko odczyt.
    public var agentLevelIsApproval: Bool { self == .ftp || self == .ftps }
}

/// Połączenie bez sekretów (plik `connections.json`); hasło/token/hasło klucza w Keychain.
public struct RemoteConnection: Codable, Sendable, Hashable, Identifiable {
    public var id: String { alias }
    /// Jedyna nazwa, jaką widzi agent.
    public var alias: String
    public var kind: RemoteKind
    public var host: String
    public var port: Int?
    public var user: String
    /// Katalog startowy na serwerze.
    public var path: String
    /// Plik klucza SSH (SFTP); pusty = agent SSH albo hasło.
    public var keyFile: String
    /// Dodatkowe, niejawne opcje rclone (np. `vendor` dla WebDAV).
    public var options: [String: String]

    public init(alias: String, kind: RemoteKind, host: String = "", port: Int? = nil, user: String = "", path: String = "", keyFile: String = "", options: [String: String] = [:]) {
        self.alias = alias
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.keyFile = keyFile
        self.options = options
    }

    /// Parametry `config/create`. Sekret dokładany tutaj, przekazywany tylko przez gniazdo rclone
    /// do pamięci procesu (`obscure`).
    func rcloneParameters(secret: String?) -> [String: Any] {
        var p: [String: Any] = [:]
        for (k, v) in options { p[k] = v }
        switch kind {
        case .sftp:
            p["host"] = host
            if !user.isEmpty { p["user"] = user }
            if let port { p["port"] = String(port) }
            if !keyFile.isEmpty {
                p["key_file"] = expandTilde(keyFile)
                if let secret, !secret.isEmpty { p["key_file_pass"] = secret }
            } else if let secret, !secret.isEmpty {
                p["pass"] = secret
            } else {
                p["key_use_agent"] = "true"
            }
        case .ftp, .ftps:
            p["host"] = host
            if !user.isEmpty { p["user"] = user }
            if let port { p["port"] = String(port) }
            if let secret { p["pass"] = secret }
            if kind == .ftps { p["explicit_tls"] = "true" }
        case .webdav:
            p["url"] = host
            if !user.isEmpty { p["user"] = user }
            if let secret { p["pass"] = secret }
        case .smb:
            p["host"] = host
            if !user.isEmpty { p["user"] = user }
            if let port { p["port"] = String(port) }
            if let secret { p["pass"] = secret }
        case .drive, .dropbox, .onedrive:
            if let secret { p["token"] = secret }
        }
        return p
    }
}

/// Sekrety połączeń w Keychain (nigdy w plikach ani w konfiguracji rclone).
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func set(_ secret: String, for account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw RemoteError.protocolError("Keychain \(status)") }
    }

    public func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
