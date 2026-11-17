import Foundation

public struct ItemActivity: Sendable, Equatable {
    /// Share of one core over the last interval.
    public var cpuPercent: Double
    /// Live TCP connections to the item's listening ports.
    public var connections: Int
    /// When the item was last seen doing something.
    public var lastActive: Date

    public func idleSeconds(now: Date = .now) -> TimeInterval { max(now.timeIntervalSince(lastActive), 0) }
}

/// R-5: an item is idle when nobody is connected to it and it burns no CPU.
/// History starts when mikko first sees the item — it never guesses backwards.
public final class ActivityTracker: @unchecked Sendable {
    private var lastCPU: [String: (ns: UInt64, at: Date)] = [:]
    private var lastActive: [String: Date] = [:]
    private let lock = NSLock()
    public let activeCPUPercent: Double
    public let maxSampleGap: TimeInterval

    public init(activeCPUPercent: Double = 1.0, maxSampleGap: TimeInterval = 120) {
        self.activeCPUPercent = activeCPUPercent; self.maxSampleGap = maxSampleGap
    }

    public func update(items: [RunningItem], established: [UInt16: Int], now: Date = .now) -> [String: ItemActivity] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: ItemActivity] = [:]
        for item in items {
            var cpu = 0.0
            // A sample is only evidence of idleness if it spans a short, awake interval. After sleep,
            // a long gap, or a child exiting (CPU total drops) nothing is known, which counts as active.
            var unknown = true
            if let prev = lastCPU[item.id], now > prev.at, now.timeIntervalSince(prev.at) <= maxSampleGap, item.cpuNs >= prev.ns {
                cpu = Double(item.cpuNs - prev.ns) / (now.timeIntervalSince(prev.at) * 1e9) * 100
                unknown = false
            }
            lastCPU[item.id] = (item.cpuNs, now)
            let connections = item.ports.reduce(0) { $0 + (established[$1.port] ?? 0) }
            if unknown || connections > 0 || cpu >= activeCPUPercent || item.isBuilding {
                lastActive[item.id] = now
            }
            out[item.id] = ItemActivity(cpuPercent: cpu, connections: connections, lastActive: lastActive[item.id]!)
        }
        let live = Set(items.map(\.id))
        lastCPU = lastCPU.filter { live.contains($0.key) }
        lastActive = lastActive.filter { live.contains($0.key) }
        return out
    }
}

/// One place for the rules about what may be stopped, by whom (R-5, R-6, R-7, A-2).
public struct StopPolicy: Sendable {
    public var pinned: Set<String>
    public init(pinned: Set<String> = []) { self.pinned = pinned }

    public func isPinned(_ item: RunningItem) -> Bool {
        pinned.contains(item.pinKey) || (item.project.map { pinned.contains("project:\($0.root)") } ?? false)
    }

    /// What the person must be told before this item is stopped, if anything.
    public func warning(for item: RunningItem) -> String? {
        if item.kind == .database { return "Stopping a database can lose data that has not been written to disk yet." }
        if item.isBuilding { return "A build is in progress. Stopping now discards it." }
        if item.kind == .agent { return "This ends the agent session. Unsaved work in the session is lost." }
        return nil
    }

    /// "Stop idle" and other bulk actions cover only what a developer started for a project:
    /// dev servers, bundlers and simulators. Never other apps that happen to listen on a port,
    /// MCP servers (they belong to a live agent), databases, agent sessions, builds or pins.
    public func allowsBulkStop(_ item: RunningItem) -> Bool {
        [.devServer, .bundler, .simulator].contains(item.kind) && !isPinned(item) && !item.isBuilding && !item.isSystem
    }

    /// A-2: an agent may stop only what descends from its own running process. Fails closed:
    /// no known agent process on either side means no.
    public func allowsAgentStop(_ item: RunningItem, callerAgentProcess: ProcessIdentity?) -> Bool {
        guard allowsBulkStop(item), !item.isOrphan, let owner = item.agentProcess, let caller = callerAgentProcess else { return false }
        return owner == caller
    }
}
