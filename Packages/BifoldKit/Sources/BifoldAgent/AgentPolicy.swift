import BifoldCore
import BifoldWorkspace
import Foundation

public enum AgentDenial: Error, LocalizedError, Sendable, Equatable {
    case permissionDenied(String)
    case blockedPath(String)
    case rejectedByUser
    case rateLimited
    case sessionClosed

    public var code: String {
        switch self {
        case .permissionDenied: "permission_denied"
        case .blockedPath: "blocked_path"
        case .rejectedByUser: "rejected_by_user"
        case .rateLimited: "rate_limited"
        case .sessionClosed: "session_closed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let why): "permission_denied: \(why)"
        case .blockedPath: "blocked_path: ścieżka jest zablokowana dla agenta"
        case .rejectedByUser: "rejected_by_user: użytkownik odrzucił operację"
        case .rateLimited: "rate_limited: przekroczono limit wywołań na minutę"
        case .sessionClosed: "session_closed"
        }
    }
}

/// Zablokowane ścieżki i normalizacja ścieżek od agenta.
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
        prefixes = all
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

    public func isBlocked(_ path: String) -> Bool {
        let candidates = Set([VFSPath.normalize(expandTilde(path)), Self.canonical(path)]).map(Self.components)
        return candidates.contains { comps in
            prefixes.contains { prefix in !prefix.isEmpty && comps.count >= prefix.count && Array(comps.prefix(prefix.count)) == prefix }
        }
    }

    public func isBlocked(_ path: VFSPath) -> Bool {
        path.isLocal && isBlocked(path.path)
    }
}

/// Limit wywołań: przesuwne okno 60 s na sesję.
final class RateLimiter {
    private var calls: [String: [Date]] = [:]

    func allow(session: String, limit: Int, now: Date = Date()) -> Bool {
        var list = calls[session, default: []].filter { now.timeIntervalSince($0) < 60 }
        guard list.count < limit else {
            calls[session] = list
            return false
        }
        list.append(now)
        calls[session] = list
        return true
    }
}

/// Zasada najmniejszego poziomu (PROMPT.md 5.4): poziom wywołania = minimum z poziomu komendy,
/// nadpisania sesji, nadpisania w ustawieniach i poziomów wszystkich zasobów.
public enum AgentPolicy {
    public static func effectiveAccess(
        command: CommandDescriptor, session: AgentSession, settings: AgentSettings, viaRunCommand: Bool = false
    ) -> AgentAccess {
        var level = command.agentAccess
        if let o = session.accessOverrides[command.id] { level = min(level, o) }
        if let o = settings.accessOverrides[command.id.rawValue] { level = min(level, o) }
        if viaRunCommand { level = min(level, .approval) }
        return level
    }

    /// Poziom zasobu: lokalny = pełny, zablokowany = brak. (Serwery i archiwa — Etapy 4–5.)
    public static func resourceAccess(_ path: VFSPath, blocked: BlockedPaths) -> AgentAccess {
        blocked.isBlocked(path) ? .none : .full
    }

    /// Czy wywołanie o danym poziomie i skutkach może się odbyć bez zgody, wymaga zgody, czy jest zabronione.
    public enum Decision: Equatable, Sendable { case allow, needsApproval, deny(String) }

    public static func decide(level: AgentAccess, effect: CommandEffect) -> Decision {
        switch level {
        case .none:
            return .deny("narzędzie niedostępne dla agenta")
        case .read:
            return effect == .none || effect == .uiState ? .allow : .deny("poziom Odczyt nie pozwala na zmiany")
        case .approval:
            return effect == .none || effect == .uiState ? .allow : .needsApproval
        case .full:
            return .allow
        }
    }
}
