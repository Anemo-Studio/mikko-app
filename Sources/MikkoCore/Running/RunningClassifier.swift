import Foundation

public enum AgentKind: String, Sendable {
    case claudeCode, codex, cursor

    public var launcher: Launcher {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .cursor: .cursor
        }
    }
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor agent"
        }
    }

    public static func detect(_ r: ProcRecord) -> AgentKind? {
        let head = r.argv.prefix(2).joined(separator: " ")
        let argv0 = r.argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let path = r.path ?? ""
        // The native installer names the binary after its version: ~/.local/share/claude/versions/2.1.226
        if r.name == "claude" || argv0 == "claude" || path.contains("/claude/versions/") || path.contains("/.claude/local/")
            || head.contains("@anthropic-ai/claude-code") { return .claudeCode }
        if r.name == "codex" || r.name.hasPrefix("codex-") || head.contains("@openai/codex") { return .codex }
        if r.name == "cursor-agent" { return .cursor }
        return nil
    }
}

public struct RunningClassifier: Sendable {
    public var uid: UInt32
    public var projectFor: @Sendable (String) -> ProjectRef?
    public var simulatorName: @Sendable (String) -> String?

    public init(uid: UInt32 = getuid(),
                projectFor: @escaping @Sendable (String) -> ProjectRef? = { _ in nil },
                simulatorName: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.uid = uid; self.projectFor = projectFor; self.simulatorName = simulatorName
    }

    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh"]
    static let sessionHosts: Set<String> = ["launchd", "login", "sshd", "sshd-session", "mosh-server", "tmux", "screen", "zellij", "sudo"]
    static let terminals: Set<String> = ["Terminal", "iTerm2", "ghostty", "WezTerm", "wezterm-gui", "Alacritty", "alacritty",
                                         "kitty", "Warp", "Hyper", "login"]
    static let databases: Set<String> = ["postgres", "mysqld", "mariadbd", "redis-server", "mongod", "memcached",
                                         "clickhouse-server", "valkey-server"]
    static let compilers: Set<String> = ["swift-frontend", "swiftc", "swift-build", "clang", "clang++", "ld", "rustc", "cargo",
                                         "javac", "kotlinc", "xcodebuild", "XCBBuildService", "tsc", "gcc", "g++", "cc1plus"]
    static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "php", "java", "tsx", "ts-node"]
    static let packageRunners: Set<String> = ["npm", "pnpm", "yarn", "npx", "bunx"]
    /// The only parents an item may grow into: things whose job is to run the server.
    /// Anything else (an editor, an unknown shell, an SSH login, a multiplexer) is a boundary.
    static let wrappers: Set<String> = interpreters.union(packageRunners).union([
        "Python", "make", "gmake", "just", "turbo", "nx", "lerna", "concurrently", "nodemon", "foreman", "overmind", "hivemind",
        "bundle", "rake", "rails", "cargo", "go", "gradle", "gradlew", "mvn", "dotnet", "uv", "poetry", "pipenv", "pdm",
        "flutter", "dart", "mix", "elixir", "watchexec", "air", "task", "docker-compose", "expo", "vite", "next",
    ])

    /// A GUI app or one of its helpers. Framework-embedded interpreters (Python.app inside
    /// Python.framework) are command-line tools, not apps.
    func isAppBundle(_ r: ProcRecord) -> Bool {
        guard let p = r.path else { return false }
        return p.contains(".app/Contents/") && !p.contains(".framework/")
    }

    func isBoundary(_ r: ProcRecord) -> Bool {
        r.pid <= 1 || r.uid != uid || AgentKind.detect(r) != nil || isAppBundle(r) || Self.sessionHosts.contains(r.name)
    }

    static func daemonTitle(_ r: ProcRecord) -> String? {
        let joined = r.argv.joined(separator: " ")
        if joined.contains("GradleDaemon") { return "Gradle daemon" }
        if joined.contains("KotlinCompileDaemon") { return "Kotlin daemon" }
        if r.name == "watchman" { return "Watchman" }
        if joined.contains("tsserver") { return "TypeScript server" }
        if joined.contains("metro") && (joined.contains("react-native") || joined.contains("expo")) { return "Metro bundler" }
        if joined.contains("esbuild") && joined.contains("--service") { return "esbuild service" }
        if r.name == "sourcekit-lsp" { return "SourceKit LSP" }
        return nil
    }

    /// "next dev", "npm run dev", "django runserver" — a name a person would use.
    public static func commandTitle(name rawName: String, argv: [String]) -> String {
        // The framework build of Python reports itself as "Python".
        let name = rawName == "Python" ? "python3" : rawName
        // Node rewrites its title: argv[0] becomes "npm exec next dev" and the rest go blank.
        if let first = argv.first, first.contains(" "), !first.hasPrefix("/"), argv.dropFirst().allSatisfy(\.isEmpty) {
            let parts = first.split(separator: " ").map(String.init)
            return commandTitle(name: (parts[0] as NSString).lastPathComponent, argv: parts)
        }
        func base(_ s: String) -> String {
            var b = (s as NSString).lastPathComponent
            for ext in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".php"] where b.hasSuffix(ext) { b.removeLast(ext.count) }
            return b
        }
        func isWord(_ s: String) -> Bool {
            !s.isEmpty && s.count <= 24 && !s.hasPrefix("-") && s.contains(where: \.isLetter)
                && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
        }
        let args = Array(argv.dropFirst())
        let positional = args.filter { !$0.hasPrefix("-") }
        if name.hasPrefix("python"), args.first == "-m", args.count > 1 { return args[1] }
        if packageRunners.contains(name) || (interpreters.contains(name) && positional.first.map { packageRunners.contains(base($0)) } == true) {
            let rest = packageRunners.contains(name) ? positional : Array(positional.dropFirst())
            let runner = packageRunners.contains(name) ? name : base(positional[0])
            // "npm exec @playwright/mcp@latest" keeps the package name; plain paths are shortened.
            let shown = rest.first == "exec" || runner == "npx" || runner == "bunx" ? 3 : 2
            return ([runner] + rest.prefix(shown).map { isWord($0) || $0.hasPrefix("@") ? $0 : base($0) }).joined(separator: " ")
        }
        if interpreters.contains(name), let script = positional.first {
            var tool = base(script)
            if tool == "manage", positional.dropFirst().first == "runserver" { return "django runserver" }
            if tool == "cli" || tool == "index" || tool == "main" || tool == "bin" || tool == "server" {
                // ".../node_modules/next/dist/bin/next" → "next"; ".../shop/server.js" → "shop server"
                let parts = script.split(separator: "/").map(String.init)
                if let i = parts.lastIndex(of: "node_modules"), i + 1 < parts.count {
                    tool = parts[i + 1].hasPrefix("@") && i + 2 < parts.count ? parts[i + 2] : parts[i + 1]
                } else if parts.count >= 2 {
                    tool = "\(parts[parts.count - 2]) \(tool)"
                }
            }
            // Only the word right after the script counts as a subcommand ("next dev"), not flag values.
            if let i = args.firstIndex(of: script), args.indices.contains(i + 1), isWord(args[i + 1]) { return "\(tool) \(args[i + 1])" }
            return tool
        }
        if let sub = args.first, isWord(sub), !sub.contains(":") { return "\(name) \(sub)" }
        return name
    }

    public func classify(_ snapshot: ProcessSnapshot) -> [RunningItem] {
        let byPid = Dictionary(snapshot.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for r in snapshot.records where r.pid != r.ppid { children[r.ppid, default: []].append(r.pid) }

        func rootOf(_ seed: ProcRecord) -> ProcRecord {
            var cur = seed
            var hops = 0
            // A database is always its own item (so it always gets its own warning): it only
            // climbs to its own server process, never into the script that launched it.
            let isDatabase = Self.databases.contains(seed.name)
            while hops < 16, let parent = byPid[cur.ppid], parent.pid != cur.pid {
                hops += 1
                if isBoundary(parent) { break }
                if isDatabase {
                    guard Self.databases.contains(parent.name) else { break }
                    cur = parent
                    continue
                }
                if Self.shells.contains(parent.name) {
                    // A shell is transparent only as glue inside a wrapper (npm → sh -c → node).
                    guard let gp = byPid[parent.ppid], !isBoundary(gp), Self.wrappers.contains(gp.name) else { break }
                    cur = gp
                    continue
                }
                guard Self.wrappers.contains(parent.name) else { break }
                cur = parent
            }
            return cur
        }

        // A child that double-forks to detach is re-parented to launchd and falls out of the
        // parent tree, but unless it also called setsid it keeps its process group. Those are
        // attached back to the group leader, so Stop ends them too. (A setsid daemon has its
        // own group and cannot be linked back; it stays its own row.)
        var detached: [Int32: [Int32]] = [:]
        for r in snapshot.records where r.ppid == 1 && r.uid == uid && r.pgid > 1 && r.pgid != r.pid {
            detached[r.pgid, default: []].append(r.pid)
        }
        func groupLeader(of r: ProcRecord) -> ProcRecord? {
            guard r.ppid == 1, r.pgid > 1, r.pgid != r.pid, let leader = byPid[r.pgid], leader.uid == uid,
                  !isBoundary(leader), !Self.shells.contains(leader.name) else { return nil }
            return leader
        }

        func descendants(of pid: Int32) -> [ProcRecord] {
            var out: [ProcRecord] = []
            var stack = children[pid] ?? []
            var seen: Set<Int32> = [pid]
            func adopt(_ p: Int32) {
                guard let r = byPid[p], r.pgid == p, !isBoundary(r), !Self.shells.contains(r.name) else { return }
                stack.append(contentsOf: detached[p] ?? [])
            }
            adopt(pid)
            while let p = stack.popLast() {
                guard seen.insert(p).inserted, let r = byPid[p] else { continue }
                out.append(r)
                stack.append(contentsOf: children[p] ?? [])
                adopt(p)
            }
            return out
        }

        func isSeed(_ r: ProcRecord) -> Bool {
            guard r.uid == uid, r.pid > 1 else { return false }
            if !r.listeners.isEmpty || AgentKind.detect(r) != nil || Self.databases.contains(r.name) { return true }
            if r.name == "launchd_sim" || r.name.hasPrefix("qemu-system") || Self.daemonTitle(r) != nil { return true }
            if let parent = byPid[r.ppid], AgentKind.detect(parent) != nil, !Self.shells.contains(r.name) { return true }
            return false
        }

        var rootsSeen = Set<Int32>()
        var items: [RunningItem] = []
        for seed in snapshot.records where isSeed(seed) {
            var root = AgentKind.detect(seed) != nil ? seed : rootOf(seed)
            if let leader = groupLeader(of: root) { root = rootOf(leader) }
            guard rootsSeen.insert(root.pid).inserted else { continue }
            if let item = makeItem(root: root, byPid: byPid, descendants: descendants(of: root.pid)) { items.append(item) }
        }

        // R-1: one process, one row. An item nested inside another's tree is dropped from the outer one.
        let rootPids = Set(items.map(\.root.pid))
        for i in items.indices where items[i].kind != .agent {
            let nested = Set(items[i].processes.dropFirst().filter { rootPids.contains($0.pid) }.map(\.pid))
            guard !nested.isEmpty else { continue }
            var drop = nested
            for n in nested { drop.formUnion(descendants(of: n).map(\.pid)) }
            items[i].processes.removeAll { drop.contains($0.pid) }
            // Ports and memory must describe only what is left, or "stop port N" hits the wrong tree.
            let left = items[i].processes.compactMap { byPid[$0.pid] }
            var ports: [Listener] = []
            for l in left.flatMap(\.listeners) where !ports.contains(l) { ports.append(l) }
            items[i].ports = ports.sorted { $0.port < $1.port }
            items[i].memory = left.reduce(0) { $0 + $1.footprint }
            items[i].cpuNs = left.reduce(0) { $0 + $1.cpuNs }
        }
        return items
    }

    private func makeItem(root: ProcRecord, byPid: [Int32: ProcRecord], descendants: [ProcRecord]) -> RunningItem? {
        let agent = AgentKind.detect(root)
        let tree = agent != nil ? [root] : [root] + descendants.filter { $0.uid == uid }
        var ports: [Listener] = []
        for l in tree.flatMap(\.listeners) where !ports.contains(l) { ports.append(l) }
        let parent = byPid[root.ppid]
        let parentAgent = parent.flatMap(AgentKind.detect)
        let project = (root.cwd ?? tree.compactMap(\.cwd).first).flatMap(projectFor)

        var kind: RunningKind
        var externalID: String?
        var title = Self.commandTitle(name: root.name, argv: root.argv)
        if let agent {
            kind = .agent
            title = agent.displayName
        } else if root.name == "launchd_sim" {
            kind = .simulator
            // ".../CoreSimulator/Devices/<UDID>/..." or ".../Previews/Simulator Devices/<UDID>/..."
            let parts = root.argv.joined(separator: " ").split(separator: "/")
            let udid = parts.firstIndex { $0.hasSuffix("Devices") }.flatMap { parts.indices.contains($0 + 1) ? String(parts[$0 + 1]) : nil }
            title = udid.flatMap(simulatorName) ?? (root.argv.joined().contains("/Previews/") ? "Xcode Preview simulator" : "iOS Simulator")
            externalID = udid
        } else if root.name.hasPrefix("qemu-system") {
            kind = .simulator
            let avd = root.argv.firstIndex(of: "-avd").flatMap { root.argv.indices.contains($0 + 1) ? root.argv[$0 + 1] : nil }
                ?? root.argv.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
            title = (avd?.replacingOccurrences(of: "_", with: " ")).map { "Android — \($0)" } ?? "Android emulator"
            externalID = avd
        } else if Self.databases.contains(root.name) {
            kind = .database
            title = root.name
        } else if parentAgent != nil {
            kind = .mcp
        } else if let daemon = Self.daemonTitle(root) ?? (ports.isEmpty ? tree.lazy.compactMap(Self.daemonTitle).first : nil) {
            kind = .bundler
            title = daemon
        } else if !ports.isEmpty {
            // A script-run listener is a dev server even outside a git project.
            let scripted = tree.contains { Self.interpreters.contains($0.name) || $0.name == "Python" || Self.packageRunners.contains($0.name) }
            kind = !isAppBundle(root) && (project != nil || scripted) ? .devServer : .other
            if isAppBundle(root) { title = root.name }
        } else {
            return nil
        }

        // Attribution (R-2): a living agent ancestor is proof. An inherited environment marker alone
        // is only trusted for a true orphan (parent is launchd); behind a terminal, multiplexer or
        // app it proves nothing, and the answer is "Unknown" rather than a guess.
        var chain = [root.name]
        var launcher: Launcher = .unknown
        var ancestorAgent: AgentKind?
        var agentProcess: ProcessIdentity?
        var sawTerminal = false
        var sawHost = false
        var sawSessionHost = false // a terminal or multiplexer: whatever is behind it was typed by someone
        var cur = root
        var hops = 0
        while hops < 32, let p = byPid[cur.ppid], p.pid != cur.pid, p.pid > 1 {
            hops += 1
            chain.append(p.name)
            if ancestorAgent == nil {
                if let a = AgentKind.detect(p) {
                    ancestorAgent = a
                    agentProcess = p.identity
                } else if !sawSessionHost, p.path?.hasSuffix("/Claude.app/Contents/MacOS/Claude") == true {
                    // Started by the Claude desktop app itself (its preview launcher): labelled, but
                    // with no agent process, so no agent can claim it.
                    ancestorAgent = .claudeCode
                }
            }
            if Self.terminals.contains(p.name) { sawTerminal = true }
            if Self.terminals.contains(p.name) || Self.sessionHosts.contains(p.name) { sawSessionHost = true }
            if ancestorAgent == nil, Self.terminals.contains(p.name) || Self.sessionHosts.contains(p.name) || isAppBundle(p) { sawHost = true }
            cur = p
        }
        let env = tree.lazy.map(\.environment).first { !$0.isEmpty } ?? [:]
        let envAgent: Launcher? = env["CLAUDECODE"] == "1" ? .claudeCode
            : env["CODEX_THREAD_ID"] != nil ? .codex
            : env["CURSOR_AGENT"] == "1" ? .cursor : nil
        var orphan = false
        if agent != nil {
            launcher = .you // an agent session is something the person opened
        } else if let a = ancestorAgent {
            launcher = a.launcher
        } else if let e = envAgent, !sawHost {
            launcher = e
            orphan = true
        } else if sawTerminal, envAgent == nil {
            launcher = .you
        }

        let path = root.path ?? ""
        let isSystem = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/Library/Apple/", "/sbin/"].contains(where: path.hasPrefix)

        return RunningItem(
            kind: kind, title: title, project: project, ports: ports.sorted { $0.port < $1.port },
            processes: tree.map(\.identity),
            memory: tree.reduce(0) { $0 + $1.footprint }, cpuNs: tree.reduce(0) { $0 + $1.cpuNs },
            launcher: launcher, chain: chain,
            sessionID: tree.lazy.compactMap { $0.environment["CLAUDE_CODE_SESSION_ID"] ?? $0.environment["CODEX_THREAD_ID"] }.first,
            isOrphan: orphan, isBuilding: tree.contains { Self.compilers.contains($0.name) },
            isSystem: isSystem && kind == .other, cwd: root.cwd,
            command: root.argv.joined(separator: " "), externalID: externalID, agentProcess: agentProcess)
    }
}

/// Finds the git root for a working directory, with a small cache (R-3).
public final class ProjectResolver: @unchecked Sendable {
    private var cache: [String: ProjectRef?] = [:]
    private var pending: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.mikko.project-resolver", qos: .utility)
    private let home: String
    private let blocking: Bool

    public init(home: String = NSHomeDirectory(), blocking: Bool = true) { self.home = home; self.blocking = blocking }

    public func project(for cwd: String) -> ProjectRef? {
        lock.lock()
        if let hit = cache[cwd] { lock.unlock(); return hit }
        if !blocking {
            // Touching ~/Documents and friends can block on a macOS consent prompt; never do that inline.
            if pending.insert(cwd).inserted {
                queue.async { [self] in
                    let found = lookup(cwd)
                    lock.lock()
                    store(cwd, found)
                    pending.remove(cwd)
                    lock.unlock()
                }
            }
            lock.unlock()
            return nil
        }
        lock.unlock()
        let found = lookup(cwd)
        lock.lock()
        store(cwd, found)
        lock.unlock()
        return found
    }

    private func store(_ cwd: String, _ value: ProjectRef?) {
        if cache.count > 2000 { cache.removeAll() }
        cache[cwd] = value
    }

    private func lookup(_ cwd: String) -> ProjectRef? {
        var dir = cwd
        while dir.count > 1, dir != home,
              dir.hasPrefix(home + "/") || dir.hasPrefix("/Volumes/") || dir.hasPrefix("/private/tmp/") || dir.hasPrefix("/tmp/") {
            if FileManager.default.fileExists(atPath: "\(dir)/.git") {
                return ProjectRef(root: dir, name: (dir as NSString).lastPathComponent, branch: GitInfo.read(root: dir).branch)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
