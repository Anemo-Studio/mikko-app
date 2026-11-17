import Foundation

/// K-4 step 3: which developer tools exist on this Mac. Modules for tools
/// that are not found are hidden rather than shown empty.
public enum DevTool: String, Sendable, CaseIterable, Codable {
    case xcode, androidSDK, docker, orbstack, colima
    case claudeCode, codex, cursor, node, homebrew

    public var displayName: String {
        switch self {
        case .xcode: "Xcode"
        case .androidSDK: "Android SDK"
        case .docker: "Docker Desktop"
        case .orbstack: "OrbStack"
        case .colima: "Colima"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .node: "Node.js"
        case .homebrew: "Homebrew"
        }
    }
}

public struct ToolDetector: Sendable {
    public var home: URL
    public var environment: [String: String]
    public var exists: @Sendable (String) -> Bool

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.home = home
        self.environment = environment
        self.exists = exists
    }

    /// Candidate paths; a tool counts as present when any one exists.
    public func candidatePaths(for tool: DevTool) -> [String] {
        let h = home.path
        switch tool {
        case .xcode:
            return ["/Applications/Xcode.app", "\(h)/Library/Developer/Xcode"]
        case .androidSDK:
            return [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"],
                    "\(h)/Library/Android/sdk", "\(h)/.android/avd"].compactMap { $0 }
        case .docker:
            return ["/Applications/Docker.app", "\(h)/.docker/run/docker.sock"]
        case .orbstack:
            return ["/Applications/OrbStack.app", "\(h)/.orbstack"]
        case .colima:
            return ["\(h)/.colima", "/opt/homebrew/bin/colima", "/usr/local/bin/colima"]
        case .claudeCode:
            return ["\(h)/.claude/projects"]
        case .codex:
            return ["\(h)/.codex"]
        case .cursor:
            return ["/Applications/Cursor.app", "\(h)/.cursor"]
        case .node:
            return ["/opt/homebrew/bin/node", "/usr/local/bin/node", "\(h)/.nvm", "\(h)/.volta",
                    "\(h)/.local/share/fnm", "\(h)/.asdf/installs/nodejs", "\(h)/.npm"]
        case .homebrew:
            return ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        }
    }

    public func detect() -> Set<DevTool> {
        Set(DevTool.allCases.filter { tool in candidatePaths(for: tool).contains(where: exists) })
    }
}
