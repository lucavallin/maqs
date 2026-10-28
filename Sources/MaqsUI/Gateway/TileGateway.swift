import Foundation
import Synchronization

/// Answers MapLibre's tile requests: from an installed region's archive, from the network through the gateway's own
/// session, or from a base pack when the network cannot answer. ``GatewayState`` makes every decision; this class is
/// the URL loading system's side of it.
///
/// It goes first in MapLibre's own session configuration, before the first map view exists, and is never registered
/// globally with `URLProtocol.registerClass`. It accepts only requests that parse as tiles of the current templates;
/// anything else passes it by untouched.
///
/// The URL loading system creates one instance per request and calls `startLoading` and `stopLoading` on one loading
/// thread. Local answers are given synchronously in `startLoading`. An online answer arrives in the data task's
/// completion handler on another thread and is handed back to the loading thread, so the client is only ever called
/// there, and never after `stopLoading`, which runs on that thread too.
///
/// `@unchecked Sendable` because that completion handler is `@Sendable` and has to reach this instance, while
/// `URLProtocol` is not Sendable. What the class inherits, `request` and `client`, is set at initialisation and never
/// changes, and `client` is itself Sendable. Its own mutable state is in `loading`, behind a lock.
final class TileGateway: URLProtocol, @unchecked Sendable {
    private struct Loading {
        var task: URLSessionDataTask?
        var stopped = false
        /// The run loop of the thread that called `startLoading`, and the modes the answer may run in: the default one
        /// and the one that thread was running in. The client is called there.
        var runLoop: CFRunLoop?
        var modes: [CFRunLoopMode] = []
        /// An online answer handed to the loading thread and not delivered yet.
        var pending: TileAnswer?
    }

    private let loading = Mutex(Loading())

    override class func canInit(with request: URLRequest) -> Bool {
        GatewayState.shared.isTile(request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let gateway = GatewayState.shared
        switch gateway.start(request) {
        case .answer(let answer):
            deliver(answer)
        case .online(let online):
            // Recorded before the task exists: its answer can arrive before `send` returns.
            loading.withLock { loading in
                let runLoop = CFRunLoopGetCurrent()
                loading.runLoop = runLoop
                loading.modes = [.defaultMode]
                if let current = CFRunLoopCopyCurrentMode(runLoop), current != .defaultMode {
                    loading.modes.append(current)
                }
            }
            switch gateway.send(online, completion: { answer in self.handOver(answer) }) {
            case .sent(let task):
                loading.withLock { $0.task = task }
            case .answer(let answer):
                deliver(answer)
            }
        }
    }

    override func stopLoading() {
        let task = loading.withLock { loading in
            loading.stopped = true
            loading.pending = nil
            return loading.task
        }
        task?.cancel()
    }

    /// Queues an online answer on the loading thread's run loop, unless the load was stopped. The Core Foundation
    /// calls are the thread-safe way in (`RunLoop`'s methods are for the run loop's own thread); they only queue the
    /// block and wake the loop, so nothing re-enters the lock.
    private func handOver(_ answer: TileAnswer) {
        loading.withLock { loading in
            guard !loading.stopped, let runLoop = loading.runLoop else { return }
            loading.pending = answer
            let modes = loading.modes.map(\.rawValue) as CFArray
            // `@Sendable` keeps the block out of this caller's region; it captures only this Sendable instance.
            CFRunLoopPerformBlock(runLoop, modes) { @Sendable in self.deliverPending() }
            CFRunLoopWakeUp(runLoop)
        }
    }

    /// Runs on the loading thread, where `stopLoading` runs too, so a stopped load is never answered.
    private func deliverPending() {
        let answer: TileAnswer? = loading.withLock { loading in
            guard !loading.stopped else { return nil }
            defer { loading.pending = nil }
            return loading.pending
        }
        if let answer { deliver(answer) }
    }

    private func deliver(_ answer: TileAnswer) {
        switch answer {
        case .response(let response, let body):
            // MapLibre's session has no URL cache; its ambient cache stores what it receives on its own.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
