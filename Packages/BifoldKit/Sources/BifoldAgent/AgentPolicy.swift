import BifoldCore
import BifoldWorkspace
import Foundation

public enum AgentDenial: Error, LocalizedError, Sendable, Equatable {
    case permissionDenied(String)
    case blockedPath(String)
    /// Operacja rekurencyjna na katalogu, w którego poddrzewie leży zablokowana ścieżka.
    case blockedSubtree(String)
    case rejectedByUser
    case rateLimited
    case sessionClosed
    /// Stan paneli, z którego komenda czyta na żywo, zmienił się w trakcie zatwierdzania.
    case stateChanged

    public var code: String {
        switch self {
        case .permissionDenied: "permission_denied"
        case .blockedPath, .blockedSubtree: "blocked_path"
        case .rejectedByUser: "rejected_by_user"
        case .rateLimited: "rate_limited"
        case .sessionClosed: "session_closed"
        case .stateChanged: "state_changed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let why): "permission_denied: \(why)"
        case .blockedPath: "blocked_path: ścieżka jest zablokowana dla agenta"
        case .blockedSubtree: "blocked_path: katalog zawiera zablokowaną ścieżkę — operacja na całym jego poddrzewie jest niedostępna dla agenta (wskaż konkretne elementy)"
        case .rejectedByUser: "rejected_by_user: użytkownik odrzucił operację"
        case .rateLimited: "rate_limited: przekroczono limit wywołań na minutę"
        case .sessionClosed: "session_closed"
        case .stateChanged: "state_changed: stan paneli zmienił się w trakcie zatwierdzania — ponów wywołanie z jawnymi ścieżkami"
        }
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

    /// Poziom zasobu: lokalny = pełny, zablokowany = brak; operacja na całym poddrzewie
    /// (`subtree`) — brak, jeśli w poddrzewie leży zablokowana ścieżka. (Serwery: `Workspace.resourceAccess`.)
    public static func resourceAccess(_ path: VFSPath, blocked: BlockedPaths, subtree: Bool = false) -> AgentAccess {
        (subtree ? blocked.containsBlocked(path) : blocked.isBlocked(path)) ? .none : .full
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
