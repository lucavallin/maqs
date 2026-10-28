import Observation
import Synchronization

/// Suspends until `condition` holds, checking it again after every change to the observable state it reads, never on
/// a timer. Cancellation resumes the wait and makes it throw, so the suite's time limit ends a wait whose condition
/// never comes true instead of hanging the run.
@MainActor
func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    while !condition() {
        try Task.checkCancellation()
        let wake = Wake()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wake.arm(continuation)
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    wake.fire()
                }
            }
        } onCancel: {
            wake.fire()
        }
    }
}

/// Resumes a continuation once, whichever comes first: a change or a cancellation, before or after it is armed.
private final class Wake: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Void, Never>?)
        case fired
    }

    private let state = Mutex(State.waiting(nil))

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        let firedAlready = state.withLock { state in
            if case .fired = state { return true }
            state = .waiting(continuation)
            return false
        }
        if firedAlready { continuation.resume() }
    }

    func fire() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = .fired }
            if case .waiting(let continuation) = state { return continuation }
            return nil
        }
        continuation?.resume()
    }
}
