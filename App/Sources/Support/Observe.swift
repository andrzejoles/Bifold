import AppKit
import Observation

/// Śledzi model `@Observable` i wywołuje `apply` przy każdej zmianie odczytanych właściwości.
/// Pierwsze wywołanie następuje od razu. Zmiany są łączone do jednego wywołania na obrót pętli.
@discardableResult
func trackChanges(_ apply: @escaping @MainActor () -> Void) -> ObservationHandle {
    let handle = ObservationHandle(apply)
    handle.track()
    return handle
}

@MainActor
final class ObservationHandle {
    private let apply: @MainActor () -> Void
    private var cancelled = false
    private var scheduled = false

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
    }

    func cancel() { cancelled = true }

    func track() {
        guard !cancelled else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.schedule() }
        }
    }

    private func schedule() {
        guard !scheduled, !cancelled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.track()
        }
    }
}

/// Zbiór obserwacji anulowanych razem z właścicielem.
@MainActor
final class ObservationBag {
    private var handles: [ObservationHandle] = []

    func add(_ apply: @escaping @MainActor () -> Void) {
        handles.append(trackChanges(apply))
    }

    func cancelAll() {
        handles.forEach { $0.cancel() }
        handles = []
    }

    deinit {
        MainActor.assumeIsolated { handles.forEach { $0.cancel() } }
    }
}
