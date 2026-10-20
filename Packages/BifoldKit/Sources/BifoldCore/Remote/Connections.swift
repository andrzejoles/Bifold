import Foundation
import Security

/// Rodzaj zdalnego zasobu (typ backendu rclone).
public enum RemoteKind: String, Codable, Sendable, CaseIterable {
    case sftp, scp, ftp, ftps, webdav, smb, drive, dropbox, onedrive

    public var displayName: String {
        switch self {
        case .sftp: "SFTP"
        case .scp: "SCP (klasyczny, np. AIX)"
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

    /// SSH (klucz, zgodność ze starymi serwerami).
    public var usesSSH: Bool { self == .sftp || self == .scp }

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
    /// SFTP/SCP: stare algorytmy SSH (diffie-hellman-group1/14-sha1, ssh-rsa, CBC) dla starych serwerów.
    public var legacyAlgorithms: Bool?
    /// SCP: kodowanie nazw plików na serwerze (domyślnie UTF-8).
    public var nameEncoding: NameEncoding?
    /// SFTP/SCP: przy otwarciu połączenia terminal SSH w drugim panelu (domyślnie tak).
    public var openTerminal: Bool?
    /// SFTP/SCP: typ terminala (`TERM`) dla terminala SSH, np. `xterm` dla starego AIX; `nil` = `xterm-256color`.
    public var terminalType: String?

    public static let defaultTerminalType = "xterm-256color"
    /// Typy proponowane w ustawieniach połączenia.
    public static let terminalTypes = ["xterm-256color", "xterm", "vt100", "vt220", "aixterm", "dtterm", "ansi"]

    /// `TERM` przekazywany przez ssh na serwer (tylko bezpieczne znaki — wartość trafia do środowiska procesu).
    public var effectiveTerminalType: String {
        guard let t = terminalType, t.range(of: "^[A-Za-z0-9._+-]{1,40}$", options: .regularExpression) != nil else { return Self.defaultTerminalType }
        return t
    }

    /// Czy otwarcie połączenia otwiera też terminal SSH w drugim panelu.
    public var opensTerminal: Bool { kind.usesSSH && openTerminal != false }

    public init(alias: String, kind: RemoteKind, host: String = "", port: Int? = nil, user: String = "", path: String = "", keyFile: String = "",
                options: [String: String] = [:], legacyAlgorithms: Bool? = nil, nameEncoding: NameEncoding? = nil) {
        self.alias = alias
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.keyFile = keyFile
        self.options = options
        self.legacyAlgorithms = legacyAlgorithms
        self.nameEncoding = nameEncoding
    }

    /// Parametry `config/create`. Sekret dokładany tutaj, przekazywany tylko przez gniazdo rclone
    /// do pamięci procesu (`obscure`).
    func rcloneParameters(secret: String?, knownHostsFile: String? = nil, hostKeyAlgorithms: [String] = []) -> [String: Any] {
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
            // Weryfikacja klucza serwera (bez tego rclone przyjmuje każdy klucz — ryzyko podsłuchu hasła).
            if let knownHostsFile { p["known_hosts_file"] = knownHostsFile }
            if legacyAlgorithms == true {
                // Domyślne algorytmy rclone + stare (Go x/crypto: group1/14-sha1, ssh-rsa, aes128-cbc, 3des-cbc).
                p["key_exchange"] = "curve25519-sha256 curve25519-sha256@libssh.org ecdh-sha2-nistp256 diffie-hellman-group14-sha256 diffie-hellman-group14-sha1 diffie-hellman-group-exchange-sha1 diffie-hellman-group1-sha1"
                p["ciphers"] = "aes128-gcm@openssh.com chacha20-poly1305@openssh.com aes128-ctr aes192-ctr aes256-ctr aes128-cbc 3des-cbc"
                p["host_key_algorithms"] = "ssh-ed25519 ecdsa-sha2-nistp256 rsa-sha2-512 rsa-sha2-256 ssh-rsa"
                // Bez wariantów ETM — z szyframi CBC Go ich nie obsługuje („packet too large”).
                p["macs"] = "hmac-sha2-256 hmac-sha2-512 hmac-sha1"
            }
            if !hostKeyAlgorithms.isEmpty { p["host_key_algorithms"] = hostKeyAlgorithms.joined(separator: " ") }
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
        case .scp:
            break
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
