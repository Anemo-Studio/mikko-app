import Foundation

/// P-2: who started it — stated only when it can be justified.
public enum Launcher: String, Sendable, Codable, CaseIterable {
    case you, claudeCode, codex, cursor, unknown

    public var label: String {
        switch self {
        case .you: "Started by you"
        case .claudeCode: "Started by Claude Code"
        case .codex: "Started by Codex"
        case .cursor: "Started by Cursor"
        case .unknown: "Unknown"
        }
    }
    public var isAgent: Bool { self == .claudeCode || self == .codex || self == .cursor }
}

public enum RunningKind: String, Sendable, Codable, CaseIterable {
    case devServer, bundler, agent, simulator, container, database, mcp, other

    public var title: String {
        switch self {
        case .devServer: "Dev servers"
        case .bundler: "Bundlers & daemons"
        case .agent: "Agents"
        case .simulator: "Simulators & emulators"
        case .container: "Containers"
        case .database: "Databases & services"
        case .mcp: "MCP servers"
        case .other: "Other listeners"
        }
    }
}

public struct ProjectRef: Hashable, Sendable, Codable {
    public var root: String
    public var name: String
    public var branch: String?
    public init(root: String, name: String, branch: String? = nil) { self.root = root; self.name = name; self.branch = branch }
}

/// P-1: a thing the user recognises ("next dev (shop)"), backed by a whole process tree.
public struct RunningItem: Identifiable, Sendable {
    public var id: String { root.key }
    public var kind: RunningKind
    public var title: String
    public var project: ProjectRef?
    public var ports: [Listener]
    /// Root first, then every descendant.
    public var processes: [ProcessIdentity]
    public var root: ProcessIdentity { processes[0] }
    public var memory: UInt64
    public var cpuNs: UInt64
    public var launcher: Launcher
    /// e.g. ["node", "zsh", "claude", "Claude"] — root first, towards launchd.
    public var chain: [String]
    public var sessionID: String?
    /// Carries an agent's marker but no living agent ancestor: left behind.
    public var isOrphan: Bool
    public var isBuilding: Bool
    /// OS services; hidden by default (R-1).
    public var isSystem: Bool
    public var cwd: String?
    public var command: String
    /// Simulator UDID or Android AVD name, for shutting down through the official tool.
    public var externalID: String?
    /// The living agent process this item descends from, if any. Ownership for agent stops is
    /// decided by this process identity — never by environment variables, which are inherited.
    public var agentProcess: ProcessIdentity?

    public var startedAt: Date { root.startDate }
    public var exposedToLAN: Bool { ports.contains(where: \.exposedToLAN) }
    public var primaryPort: UInt16? { ports.map(\.port).min() }
    /// Stable across restarts of the same thing — used for pins.
    public var pinKey: String { "\(project?.root ?? cwd ?? "-")|\(title)" }
}
