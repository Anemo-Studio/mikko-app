import MikkoCore
import Observation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview, running, simulators, containers, disk, sessions, usage

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .running: "bolt.horizontal"
        case .simulators: "iphone"
        case .containers: "shippingbox"
        case .disk: "internaldrive"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .usage: "gauge.with.dots.needle.67percent"
        }
    }

    static let groups: [(title: String, sections: [AppSection])] = [
        ("", [.overview]),
        ("Now", [.running, .simulators, .containers]),
        ("Space", [.disk]),
        ("History", [.sessions, .usage]),
    ]

    /// Tools that make a section meaningful; nil means always shown (K-4: hide, don't show empty).
    var requiredTools: Set<DevTool>? {
        switch self {
        case .simulators: [.xcode, .androidSDK]
        case .containers: [.docker, .orbstack, .colima]
        case .sessions, .usage: [.claudeCode, .codex, .cursor]
        default: nil
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case none, freeDisk, runningCount
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Icon only"
        case .freeDisk: "Free disk space"
        case .runningCount: "Running items"
        }
    }
}

enum Attention: Int, Comparable {
    case calm, warning, critical
    static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }
}

@Observable
final class AppModel {
    var detectedTools: Set<DevTool> = []
    var disk: DiskSpace?
    var section: AppSection = .overview
    let diskModel = DiskModel()
    let runningModel = RunningModel()
    let simulatorsModel = SimulatorsModel()
    let containersModel = ContainersModel()
    let sessionsModel = SessionsModel()
    let usageModel: UsageModel
    let updateModel = UpdateModel()

    private var refreshTask: Task<Void, Never>?

    init() {
        usageModel = UsageModel(database: sessionsModel.database)
        if let raw = UserDefaults.standard.string(forKey: "lastSection"), let s = AppSection(rawValue: raw) {
            section = s
        }
        diskModel.toolMarkers = { [runningModel] in runningModel.toolMarkers }
        diskModel.busyRoots = { [runningModel] in runningModel.busyRoots }
        simulatorsModel.runningAVDs = { [runningModel] in
            // Emulator console ports are the even ones from 5554; the serial is "emulator-<port>".
            Dictionary(runningModel.items.compactMap { item -> (String, UInt16)? in
                guard item.kind == .simulator, item.chain.first?.hasPrefix("qemu-system") == true, let avd = item.externalID,
                      let port = item.ports.map(\.port).first(where: { $0 >= 5554 && $0 <= 5584 && $0 % 2 == 0 }) else { return nil }
                return (avd, port)
            }, uniquingKeysWith: { a, _ in a })
        }
        refresh()
        startRefreshing()
    }

    var visibleSections: [AppSection] {
        AppSection.allCases.filter { s in
            guard let tools = s.requiredTools else { return true }
            return !tools.isDisjoint(with: detectedTools)
        }
    }

    var attention: Attention {
        guard let disk else { return .calm }
        let gb = Double(disk.free) / 1e9
        if disk.freeFraction < 0.05 || gb < 10 { return .critical }
        if disk.freeFraction < 0.10 || gb < 20 { return .warning }
        return .calm
    }

    // MARK: Attention — the short list of things worth interrupting someone for.

    var runningDevItems: [RunningItem] { runningModel.visibleItems.filter { $0.kind != .other && $0.kind != .agent && $0.kind != .mcp } }

    var attentionItems: [AttentionItem] {
        var out: [AttentionItem] = []
        let running = runningModel
        if let disk, disk.freeFraction < 0.10 || Double(disk.free) / 1e9 < 20 {
            out.append(AttentionItem(id: "disk-low", level: Double(disk.free) / 1e9 < 10 ? .critical : .warning, symbol: "internaldrive",
                                     text: "Only \(ByteFormat.string(disk.free)) of disk space left.", actionTitle: "Free Up Space") { [weak self] in self?.select(.disk) })
        }
        let leftBehind = running.visibleItems.filter(\.isOrphan).count + running.leftovers.count
        if leftBehind > 0 {
            out.append(AttentionItem(id: "left-behind", symbol: "questionmark.circle",
                                     text: "\(leftBehind) process\(leftBehind == 1 ? " was" : "es were") left behind by an agent session that has ended.",
                                     actionTitle: "Show") { [weak self] in self?.select(.running) })
        }
        let idle = running.idleCandidates
        if !idle.isEmpty {
            let mem = idle.reduce(0) { $0 + $1.memory }
            out.append(AttentionItem(id: "idle", level: .info, symbol: "moon.zzz",
                                     text: "\(idle.count) thing\(idle.count == 1 ? " has" : "s have") been idle for a while, holding \(ByteFormat.string(Int64(mem))) of memory.",
                                     actionTitle: "Review") { [weak self] in self?.select(.running) })
        }
        if running.memory.pressure != .normal, running.devMemory > 500_000_000 {
            out.append(AttentionItem(id: "pressure", level: running.memory.pressure == .critical ? .critical : .warning, symbol: "memorychip",
                                     text: "Your Mac is short on memory. Dev tools are using \(ByteFormat.string(Int64(running.devMemory))).",
                                     actionTitle: "See What") { [weak self] in self?.select(.running) })
        }
        let exposed = runningDevItems.filter(\.exposedToLAN).count
        if exposed > 0 {
            out.append(AttentionItem(id: "lan", symbol: "wifi.exclamationmark",
                                     text: "\(exposed) dev server\(exposed == 1 ? " is" : "s are") reachable from other devices on your network.",
                                     actionTitle: "Show") { [weak self] in self?.select(.running) })
        }
        if diskModel.hasScanned, diskModel.safeReclaimable > 2_000_000_000 {
            out.append(AttentionItem(id: "reclaim", level: .info, symbol: "sparkles",
                                     text: "\(ByteFormat.string(diskModel.safeReclaimable)) of caches can be safely cleared.",
                                     actionTitle: "Review") { [weak self] in self?.select(.disk) })
        }
        for b in usageModel.overBudget {
            out.append(AttentionItem(id: "budget-\(b.id)", symbol: "dollarsign.circle",
                                     text: "\(b.project ?? "All projects") went over the \(b.period.rawValue == "day" ? "daily" : "monthly") budget.",
                                     actionTitle: "Show") { [weak self] in self?.select(.usage) })
        }
        return out
    }

    var headline: String {
        let n = attentionItems.filter { $0.level != .info }.count
        if n == 0 { return attentionItems.isEmpty ? "All quiet." : "All good." }
        return n == 1 ? "One thing wants a look." : "\(n) things want a look."
    }

    func select(_ s: AppSection) {
        section = s
        UserDefaults.standard.set(s.rawValue, forKey: "lastSection")
    }

    func refresh() {
        Task {
            let (tools, disk) = await Task.detached { (ToolDetector().detect(), DiskSpace.current()) }.value
            // Assign only on change, so idle refreshes do not redraw every view.
            if self.detectedTools != tools { self.detectedTools = tools }
            if self.disk != disk { self.disk = disk }
        }
    }

    /// Keeps popover data under 5 s old (K-1) at negligible cost.
    private func startRefreshing() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
            }
        }
    }
}
