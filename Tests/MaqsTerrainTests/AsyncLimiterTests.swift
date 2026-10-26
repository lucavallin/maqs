import Synchronization
import Testing
@testable import MaqsTerrain

/// Bodies that record how many of them run at once and wait until the test lets them finish.
private final class Gate: Sendable {
    private struct State {
        var running = 0
        var maximum = 0
        var entered = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    /// Yields once each time a body enters.
    let entries: AsyncStream<Void>
    private let entered: AsyncStream<Void>.Continuation

    init() {
        (entries, entered) = AsyncStream.makeStream()
    }

    /// The body: counts itself in, waits for `releaseOne`, counts itself out.
    func pass() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.running += 1
                state.entered += 1
                state.maximum = max(state.maximum, state.running)
                state.waiting.append(continuation)
            }
            entered.yield()
        }
        state.withLock { $0.running -= 1 }
    }

    /// Lets the body that entered first finish.
    func releaseOne() {
        let next = state.withLock { state in state.waiting.isEmpty ? nil : state.waiting.removeFirst() }
        next?.resume()
    }

    var maximum: Int { state.withLock { $0.maximum } }
    var enteredCount: Int { state.withLock { $0.entered } }
}

@Suite(.timeLimit(.minutes(1))) struct AsyncLimiterTests {
    @Test func neverMoreThanFourAtOnce() async throws {
        let limiter = AsyncLimiter(limit: 4)
        let gate = Gate()
        let finished = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<12 {
                group.addTask { try await limiter.run { await gate.pass(); return index } }
            }
            var entries = gate.entries.makeAsyncIterator()
            for _ in 0..<4 { _ = await entries.next() }
            // One out, one in: the next body enters only once a running one has finished.
            for _ in 4..<12 {
                gate.releaseOne()
                _ = await entries.next()
            }
            for _ in 0..<4 { gate.releaseOne() }
            var finished: [Int] = []
            for try await index in group { finished.append(index) }
            return finished
        }
        #expect(gate.maximum == 4)
        #expect(finished.sorted() == Array(0..<12))
    }

    @Test func aWaiterCancelledBeforeItsTurnThrowsCancellationError() async throws {
        let limiter = AsyncLimiter(limit: 1)
        let gate = Gate()
        var entries = gate.entries.makeAsyncIterator()
        let holder = Task { try await limiter.run { await gate.pass() } }
        _ = await entries.next()
        let waiter = Task { try await limiter.run { await gate.pass() } }
        // Polls rather than sleeps; the check lets the time limit end the loop should the waiter never queue.
        while await limiter.waitingCount < 1 {
            try Task.checkCancellation()
            await Task.yield()
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        gate.releaseOne()
        try await holder.value
        // The cancelled waiter never ran its body and left the slot free for the next caller.
        #expect(gate.enteredCount == 1)
        #expect(try await limiter.run { 7 } == 7)
        #expect(await limiter.waitingCount == 0)
    }
}
