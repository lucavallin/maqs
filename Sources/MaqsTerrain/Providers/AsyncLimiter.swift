/// Runs at most `limit` bodies at once; callers beyond the limit wait in arrival order.
/// A caller cancelled while it waits throws `CancellationError` and never runs its body.
actor AsyncLimiter {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var running = 0
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    /// `limit` below 1 is taken as 1.
    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Callers waiting for a slot, for tests.
    var waitingCount: Int { waiters.count }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        // A waiter handed the slot just as it was cancelled gives it back without running.
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard running >= limit else {
            running += 1
            return
        }
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            // Runs after the append above: the actor is busy until the continuation is stored and the caller suspends.
            Task { await self.cancel(id) }
        }
    }

    /// Hands the slot to the longest waiter, or frees it.
    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
