import AppKit
import MikkoCore
import Observation

@Observable
final class RunningModel {
    private(set) var items: [RunningItem] = []
    private(set) var activity: [String: ItemActivity] = [:]
    private(set) var memory = MemoryStatus.current()
    /// Item id → moment the stop signal will be sent. Until then it can be undone (R-6).
    private(set) var pendingStops: [String: Date] = [:]
    private(set) var stopping: Set<String> = []
    /// Item id → processes that ignored a polite stop.
    private(set) var survivors: [String: [ProcessIdentity]] = [:]
    /// Processes still alive after their item's main process exited: shown separately so they can be force-stopped.
    private(set) var leftovers: [Leftover] = []
    var message: String?

    struct Leftover: Identifiable {
        var id: String
        var title: String
        var processes: [ProcessIdentity]
    }
    var pinned: Set<String> { didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinnedRunning") } }
    /// Faster refresh while a window is showing the list (spec §12).
    var isForeground = false { didSet { if isForeground { refresh() } } }

    static let undoWindow: TimeInterval = 4

    private let scanner = RunningScanner(blocking: false)
    private(set) var toolMarkers: Set<String> = []
    private let tracker = ActivityTracker()
    private var loop: Task<Void, Never>?

    init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: "pinnedRunning") ?? [])
        refresh()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.isForeground == true ? 3 : 30))
                self?.refresh()
            }
        }
    }

    var policy: StopPolicy { StopPolicy(pinned: pinned) }
    var idleThreshold: TimeInterval {
        let m = UserDefaults.standard.integer(forKey: "idleMinutes")
        return Double(m > 0 ? m : 30) * 60
    }

    var visibleItems: [RunningItem] { items.filter { !$0.isSystem } }
    /// Folders that have a dev server, build or database running in them (agent sessions do not count).
    var busyRoots: Set<String> {
        Set(items.filter { $0.kind != .agent && $0.kind != .other && $0.kind != .mcp }.compactMap { $0.project?.root ?? $0.cwd })
    }
    var devMemory: UInt64 { visibleItems.filter { $0.kind != .other }.reduce(0) { $0 + $1.memory } }

    func isIdle(_ item: RunningItem) -> Bool {
        guard !item.isBuilding, item.kind != .agent, let a = activity[item.id] else { return false }
        return a.idleSeconds() >= idleThreshold
    }

    var idleCandidates: [RunningItem] { visibleItems.filter { isIdle($0) && policy.allowsBulkStop($0) } }

    func refresh() {
        let scanner = scanner, tracker = tracker
        Task {
            let (items, activity, memory, markers) = await Task.detached(priority: .utility) {
                let (items, snapshot) = scanner.scan()
                return (items, tracker.update(items: items, established: snapshot.establishedByLocalPort),
                        MemoryStatus.current(), snapshot.toolMarkers())
            }.value
            toolMarkers = markers
            // Stable order so rows do not jump between refreshes (R-1).
            self.items = items.sorted {
                ($0.project?.name ?? "~", $0.title, $0.root.pid) < ($1.project?.name ?? "~", $1.title, $1.root.pid)
            }
            self.activity = activity
            self.memory = memory
            let live = Set(items.map(\.id))
            survivors = survivors.filter { live.contains($0.key) }
            stopping.formIntersection(live)
            leftovers = leftovers.compactMap { l in
                var l = l
                l.processes.removeAll { ProcessTable.identity(of: $0.pid) != $0 }
                return l.processes.isEmpty ? nil : l
            }
        }
    }

    // MARK: Pins

    func togglePin(_ item: RunningItem) {
        if pinned.contains(item.pinKey) { pinned.remove(item.pinKey) } else { pinned.insert(item.pinKey) }
    }

    func togglePin(project: ProjectRef) {
        let key = "project:\(project.root)"
        if pinned.contains(key) { pinned.remove(key) } else { pinned.insert(key) }
    }

    // MARK: Stop

    /// Starts the undo window; the signal is only sent when it runs out.
    func requestStop(_ targets: [RunningItem]) {
        let fireAt = Date().addingTimeInterval(Self.undoWindow)
        for t in targets { pendingStops[t.id] = fireAt }
        let ids = targets.map(\.id)
        Task {
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            for id in ids where pendingStops[id] == fireAt {
                pendingStops[id] = nil
                performStop(id: id, force: false)
            }
        }
    }

    func undoStop(_ id: String) { pendingStops[id] = nil }

    /// Ends exactly the processes that ignored the polite stop — not a fresh guess at the tree.
    func forceStop(_ item: RunningItem) {
        guard let ids = survivors[item.id] else { return }
        forceStop(ids, key: item.id)
    }

    func forceStop(_ leftover: Leftover) { forceStop(leftover.processes, key: leftover.id) }

    private func forceStop(_ ids: [ProcessIdentity], key: String) {
        stopping.insert(key)
        Task {
            let result = await Task.detached(priority: .userInitiated) { await ProcessStopper().forceStop(ids) }.value
            stopping.remove(key)
            survivors[key] = result.survivors.isEmpty ? nil : result.survivors
            leftovers.removeAll { $0.id == key }
            if !result.failed.isEmpty { message = "\(result.failed.count) processes could not be ended." }
            refresh()
        }
    }

    private enum StopOutcome: Sendable {
        case done
        case survivors([ProcessIdentity], title: String)
        case toolFailed(String)
    }

    private func performStop(id: String, force: Bool) {
        stopping.insert(id)
        let scanner = scanner
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> StopOutcome in
                // Never act on stale data: take a fresh look right before signalling (spec §12).
                guard let item = scanner.scan().items.first(where: { $0.id == id }) else { return .done }
                if item.kind == .simulator {
                    // R-6: simulators and emulators are shut down through their own tools, never killed.
                    if item.chain.first == "launchd_sim", let udid = item.externalID {
                        let set = item.command.contains("/Previews/") ? ["--set", "previews"] : []
                        if Subprocess.run("/usr/bin/xcrun", ["simctl"] + set + ["shutdown", udid], timeout: 60) != nil { return .done }
                        return .toolFailed("\(item.title) did not shut down when asked through simctl.")
                    }
                    if item.chain.first?.hasPrefix("qemu-system") == true,
                       let port = item.ports.map(\.port).first(where: { $0 >= 5554 && $0 <= 5584 && $0 % 2 == 0 }) {
                        if AndroidEmulators.stop(consolePort: port, sdk: AndroidEmulators.sdkRoot()) { return .done }
                        return .toolFailed("\(item.title) did not stop when asked through adb.")
                    }
                }
                let result = await ProcessStopper(grace: item.kind == .database ? 10 : 5).stop(item.processes)
                let left = result.survivors + result.failed
                return left.isEmpty ? .done : .survivors(left, title: item.title)
            }.value
            stopping.remove(id)
            switch outcome {
            case .done: survivors[id] = nil
            case .toolFailed(let text):
                message = text + " Nothing was killed; try again or quit it from its own app."
            case .survivors(let ids, let title):
                survivors[id] = ids
                // If the main process is gone the row disappears, so keep what is left visible.
                if !ids.contains(where: { $0.key == id }) { leftovers.append(Leftover(id: id, title: title, processes: ids)) }
            }
            refresh()
        }
    }

    nonisolated static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
