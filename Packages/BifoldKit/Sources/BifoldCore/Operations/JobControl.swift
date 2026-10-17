import Foundation

/// Sterowanie zadaniem działającym w tle: pauza, wznowienie, anulowanie i limit prędkości.
/// Metody `checkpoint()` i `consume(_:)` wywołuje wątek roboczy (także z callbacku `copyfile`).
public final class JobControl: @unchecked Sendable {
    private let condition = NSCondition()
    // Wszystkie pola chronione przez `condition`.
    private var paused = false
    private var cancelled = false
    private var limit: Int64 = 0
    private var windowStart = ContinuousClock.now
    private var windowBytes: Int64 = 0

    public init(speedLimit: Int64 = 0) {
        limit = max(0, speedLimit)
    }

    public var isPaused: Bool { condition.withLock { paused } }
    public var isCancelled: Bool { condition.withLock { cancelled } }
    /// Bajty na sekundę; 0 = bez limitu.
    public var speedLimit: Int64 { condition.withLock { limit } }

    public func pause() {
        condition.withLock { paused = true }
    }

    public func resume() {
        condition.withLock {
            paused = false
            resetWindow()
            condition.broadcast()
        }
    }

    public func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    public func setSpeedLimit(_ bytesPerSecond: Int64) {
        condition.withLock {
            limit = max(0, bytesPerSecond)
            resetWindow()
            condition.broadcast()
        }
    }

    /// Blokuje wątek roboczy na czas pauzy. Zwraca `false`, jeśli zadanie anulowano.
    @discardableResult
    public func checkpoint() -> Bool {
        condition.withLock {
            while paused && !cancelled { condition.wait() }
            if !paused && windowBytes == 0 { windowStart = .now }
            return !cancelled
        }
    }

    /// Zlicza przesłane bajty i usypia wątek, jeśli przekroczono limit prędkości.
    /// Zwraca `false`, jeśli zadanie anulowano.
    @discardableResult
    public func consume(_ bytes: Int64) -> Bool {
        condition.withLock {
            windowBytes += bytes
            while !cancelled {
                if paused {
                    condition.wait()
                    continue
                }
                guard limit > 0 else { return true }
                let required = Double(windowBytes) / Double(limit)
                let elapsed = (ContinuousClock.now - windowStart).seconds
                if elapsed >= required { return true }
                // Czekamy w krótkich odcinkach, żeby szybko reagować na pauzę i anulowanie.
                let wait = min(required - elapsed, 0.1)
                _ = condition.wait(until: Date(timeIntervalSinceNow: wait))
            }
            return false
        }
    }

    private func resetWindow() {
        windowStart = .now
        windowBytes = 0
    }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
