import Darwin
import Foundation

/// `realpath(3)` — rozwiązuje dowiązania symboliczne, `.` i `..`; `nil`, jeśli ścieżka nie istnieje.
public func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Wykonuje blokującą pracę (wywołania systemowe) poza pulą wątków współbieżności Swift.
public func runBlocking<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated, _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(with: Result { try body() })
        }
    }
}

/// Rozwija `~` na początku ścieżki.
public func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    return path
}
