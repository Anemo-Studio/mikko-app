import Darwin
import Foundation

public struct StopResult: Sendable, Equatable {
    /// Processes that were signalled and are now gone.
    public var stopped: [ProcessIdentity] = []
    /// Still alive after the grace period — the caller may offer "Force stop".
    public var survivors: [ProcessIdentity] = []
    /// Rows that no longer matched a live process: nothing was signalled (R-6).
    public var stale: [ProcessIdentity] = []
    /// Could not be signalled at all (e.g. not permitted).
    public var failed: [ProcessIdentity] = []

    /// True only when something was actually stopped and nothing was left behind.
    public var succeeded: Bool { !stopped.isEmpty && survivors.isEmpty && failed.isEmpty }
}

/// R-6: stops a whole tree politely. Every pid is re-checked against its start
/// time immediately before each signal, so a recycled PID is never hit.
public struct ProcessStopper: Sendable {
    public var grace: TimeInterval
    public var pollInterval: TimeInterval
    public init(grace: TimeInterval = 5, pollInterval: TimeInterval = 0.1) { self.grace = grace; self.pollInterval = pollInterval }

    static func isAlive(_ id: ProcessIdentity) -> Bool { ProcessTable.identity(of: id.pid) == id }

    /// Sends `signal` to every listed process that is still the one we listed.
    /// Never signals pid ≤ 1 or this process.
    func signalAll(_ ids: [ProcessIdentity], _ signal: Int32) -> (sent: [ProcessIdentity], stale: [ProcessIdentity], failed: [ProcessIdentity]) {
        var sent: [ProcessIdentity] = [], stale: [ProcessIdentity] = [], failed: [ProcessIdentity] = []
        for id in ids {
            guard id.pid > 1, id.pid != getpid() else { failed.append(id); continue }
            guard Self.isAlive(id) else { stale.append(id); continue }
            if kill(id.pid, signal) == 0 { sent.append(id) } else if errno == ESRCH { stale.append(id) } else { failed.append(id) }
        }
        return (sent, stale, failed)
    }

    private func waitForExit(_ ids: [ProcessIdentity], upTo seconds: TimeInterval) async -> [ProcessIdentity] {
        let deadline = Date().addingTimeInterval(seconds)
        var remaining = ids.filter(Self.isAlive)
        while !remaining.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .seconds(pollInterval))
            remaining.removeAll { !Self.isAlive($0) }
        }
        return remaining
    }

    /// Polite stop. The root (first id) is asked first so it can shut its own children down in
    /// order — a database or a supervisor must not see its children die underneath it. Whatever is
    /// still running shortly after is then asked directly, and the whole tree gets `grace` to exit.
    public func stop(_ ids: [ProcessIdentity]) async -> StopResult {
        guard let root = ids.first else { return StopResult() }
        var result = StopResult()
        let first = signalAll([root], SIGTERM)
        result.stale += first.stale; result.failed += first.failed
        _ = await waitForExit(ids, upTo: min(grace, 1.5))
        let rest = signalAll(Array(ids.dropFirst()).filter(Self.isAlive), SIGTERM)
        result.failed += rest.failed
        let signalled = first.sent + rest.sent
        // Children that exited on their own after the root was asked count as stopped, not stale.
        let exitedQuietly = ids.dropFirst().filter { id in !rest.sent.contains(id) && !rest.failed.contains(id) && first.sent.contains(root) }
        result.survivors = await waitForExit(ids, upTo: grace)
        let alive = Set(result.survivors)
        result.stopped = (signalled + exitedQuietly).filter { !alive.contains($0) }
        if first.sent.isEmpty { result.stale += ids.dropFirst().filter { !Self.isAlive($0) && !result.stopped.contains($0) } }
        return result
    }

    /// SIGKILL for whatever a polite stop left behind.
    public func forceStop(_ ids: [ProcessIdentity]) async -> StopResult {
        let r = signalAll(ids, SIGKILL)
        let survivors = await waitForExit(r.sent, upTo: grace)
        let alive = Set(survivors)
        return StopResult(stopped: r.sent.filter { !alive.contains($0) }, survivors: survivors, stale: r.stale, failed: r.failed)
    }
}
