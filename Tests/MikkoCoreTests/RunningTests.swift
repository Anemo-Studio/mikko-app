import Foundation
import Testing
@testable import MikkoCore

private func rec(_ pid: Int32, _ ppid: Int32, _ name: String, argv: [String] = [], path: String? = nil, cwd: String? = nil,
                 env: [String: String] = [:], ports: [UInt16] = [], uid: UInt32 = 501, mem: UInt64 = 100, wildcard: Bool = false) -> ProcRecord {
    ProcRecord(identity: .init(pid: pid, startSec: 1000 + Int64(pid), startUsec: 0), ppid: ppid, uid: uid, name: name,
               path: path ?? "/usr/local/bin/\(name)", argv: argv.isEmpty ? [name] : argv, environment: env, cwd: cwd,
               footprint: mem, listeners: ports.map {
                   Listener(port: $0, address: wildcard ? "0.0.0.0" : "127.0.0.1", isWildcard: wildcard, isLoopback: !wildcard)
               })
}

private let classifier = RunningClassifier(uid: 501, projectFor: { cwd in
    cwd.hasPrefix("/Users/t/dev/shop") ? ProjectRef(root: "/Users/t/dev/shop", name: "shop", branch: "main") : nil
})

private let base: [ProcRecord] = [
    rec(1, 0, "launchd", uid: 0),
    rec(10, 1, "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
    rec(11, 10, "login", uid: 0),
    rec(12, 11, "zsh"),
]

@Test func devServerStartedByYouIsOneItemForTheWholeTree() {
    let snap = ProcessSnapshot(records: base + [
        rec(20, 12, "npm", argv: ["npm", "run", "dev"], cwd: "/Users/t/dev/shop"),
        rec(21, 20, "sh", argv: ["sh", "-c", "next dev"], cwd: "/Users/t/dev/shop"),
        rec(22, 21, "node", argv: ["node", "/Users/t/dev/shop/node_modules/next/dist/bin/next", "dev"], cwd: "/Users/t/dev/shop", ports: [3000], mem: 500),
        rec(23, 22, "node", argv: ["node", "worker.js"], cwd: "/Users/t/dev/shop"),
    ])
    let items = classifier.classify(snap)
    #expect(items.count == 1)
    let i = items[0]
    #expect(i.kind == .devServer && i.title == "npm run dev" && i.project?.name == "shop")
    #expect(i.processes.map(\.pid) == [20, 21, 22, 23] || Set(i.processes.map(\.pid)) == [20, 21, 22, 23])
    #expect(i.root.pid == 20 && i.memory == 800 && i.primaryPort == 3000)
    #expect(i.launcher == .you && !i.isOrphan && !i.exposedToLAN)
    #expect(i.chain.prefix(3) == ["npm", "zsh", "login"])
}

@Test func agentChildrenAreAttributedAndMCPIsSeparate() {
    let claudePath = "/Users/t/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude"
    let snap = ProcessSnapshot(records: base + [
        rec(30, 12, "claude", path: claudePath, cwd: "/Users/t/dev/shop", ports: [51000]),
        rec(31, 30, "zsh", argv: ["zsh", "-c", "pnpm dev"]),
        rec(32, 31, "node", argv: ["node", "/x/node_modules/vite/bin/vite.js"], cwd: "/Users/t/dev/shop",
            env: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "abc"], ports: [5173], wildcard: true),
        rec(33, 30, "npm", argv: ["npm", "exec", "@playwright/mcp@latest"]),
        rec(34, 33, "node", argv: ["node", "/x/.bin/mcp-server-playwright"]),
    ])
    let items = classifier.classify(snap)
    let byKind = Dictionary(grouping: items, by: \.kind)
    #expect(items.count == 3)
    #expect(byKind[.agent]?.first?.title == "Claude Code" && byKind[.agent]?.first?.processes.count == 1)
    #expect(byKind[.agent]?.first?.launcher == .you)
    let server = byKind[.devServer]?.first
    #expect(server?.title == "vite" && server?.launcher == .claudeCode && server?.sessionID == "abc")
    #expect(server?.exposedToLAN == true && server?.isOrphan == false)
    let mcp = byKind[.mcp]?.first
    #expect(mcp?.processes.count == 2 && mcp?.launcher == .claudeCode)
}

@Test func orphanedAgentProcessIsFlaggedAndUnknownStaysUnknown() {
    let snap = ProcessSnapshot(records: base + [
        rec(40, 1, "node", argv: ["node", "server.js"], cwd: "/Users/t/dev/shop", env: ["CLAUDECODE": "1"], ports: [4000]),
        rec(41, 1, "node", argv: ["node", "other.js"], cwd: "/Users/t/dev/shop", ports: [4001]),
        rec(42, 1, "rapportd", path: "/usr/libexec/rapportd", ports: [49152], wildcard: true),
        rec(43, 1, "postgres", cwd: "/opt/homebrew/var/postgres", ports: [5432]),
        rec(44, 1, "mysqld", ports: [3306], uid: 74),
    ])
    let items = classifier.classify(snap)
    let byPid = Dictionary(uniqueKeysWithValues: items.map { ($0.root.pid, $0) })
    #expect(byPid[40]?.launcher == .claudeCode && byPid[40]?.isOrphan == true)
    #expect(byPid[41]?.launcher == .unknown && byPid[41]?.isOrphan == false)
    #expect(byPid[42]?.kind == .other && byPid[42]?.isSystem == true)
    #expect(byPid[43]?.kind == .database)
    #expect(byPid[44] == nil) // another user's process: never ours to manage
}

@Test func buildingAndDaemonsAndEmulators() {
    let snap = ProcessSnapshot(records: base + [
        rec(50, 12, "java", argv: ["java", "-cp", "x", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.5"]),
        rec(51, 50, "clang", argv: ["clang", "a.c"]),
        rec(52, 1, "qemu-system-aarch64", argv: ["qemu-system-aarch64", "-avd", "Pixel_8_API_35"], ports: [5554]),
        rec(53, 1, "launchd_sim", argv: ["launchd_sim", "/Users/t/Library/Developer/CoreSimulator/Devices/AAAA-BBBB/data/var/run/launchd_bootstrap.plist"]),
        rec(54, 53, "SpringBoard", mem: 900),
    ])
    let c = RunningClassifier(uid: 501, simulatorName: { $0 == "AAAA-BBBB" ? "iPhone 16" : nil })
    let byPid = Dictionary(uniqueKeysWithValues: c.classify(snap).map { ($0.root.pid, $0) })
    #expect(byPid[50]?.kind == .bundler && byPid[50]?.title == "Gradle daemon" && byPid[50]?.isBuilding == true)
    #expect(byPid[52]?.kind == .simulator && byPid[52]?.title == "Android — Pixel 8 API 35")
    #expect(byPid[53]?.title == "iPhone 16" && byPid[53]?.memory == 1000)
}

@Test func commandTitles() {
    func t(_ n: String, _ a: [String]) -> String { RunningClassifier.commandTitle(name: n, argv: a) }
    #expect(t("node", ["node", "/p/node_modules/next/dist/bin/next", "dev", "-p", "3000"]) == "next dev")
    #expect(t("node", ["node", "/p/node_modules/.bin/vite"]) == "vite")
    #expect(t("npm", ["npm", "run", "dev"]) == "npm run dev")
    #expect(t("python3", ["python3", "manage.py", "runserver"]) == "django runserver")
    #expect(t("python3", ["python3", "-m", "http.server", "8000"]) == "http.server")
    #expect(t("ruby", ["ruby", "bin/rails", "server"]) == "rails server")
    #expect(t("php", ["php", "artisan", "serve"]) == "artisan serve")
    #expect(t("myserver", ["./myserver", "--port", "8080"]) == "myserver")
    #expect(t("node", ["node", "/Users/t/dev/shop/server.js"]) == "shop server")
    #expect(t("Python", ["/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", "-m", "http.server", "8765"]) == "http.server")
    #expect(t("node", ["npm exec next dev --webpack", "", ""]) == "npm exec next dev")
    #expect(t("node", ["npm exec @playwright/mcp@latest", ""]) == "npm exec @playwright/mcp@latest")
    #expect(t("node", ["node /x/.bin/mcp-server-playwright"]) == "mcp-server-playwright")
}

@Test func stopperStopsATreeAndNeverTouchesStaleRows() async throws {
    // sh → two sleeps. All ours, harmless.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "/bin/sleep 300 & /bin/sleep 300 & wait"]
    try p.run()
    try await Task.sleep(for: .milliseconds(300))

    let table = ProcessTable()
    let snap = table.snapshot()
    let kids = snap.records.filter { $0.ppid == p.processIdentifier }
    let root = try #require(snap.records.first { $0.pid == p.processIdentifier })
    #expect(kids.count == 2)
    let ids = [root.identity] + kids.map(\.identity)

    // A row whose start time no longer matches must not be signalled.
    let stale = ProcessIdentity(pid: kids[0].pid, startSec: 1, startUsec: 1)
    let none = await ProcessStopper(grace: 0.3).stop([stale])
    #expect(none.stale == [stale] && none.stopped.isEmpty)
    #expect(ProcessTable.identity(of: kids[0].pid) == kids[0].identity)

    let result = await ProcessStopper(grace: 3).stop(ids)
    p.waitUntilExit()
    #expect(result.survivors.isEmpty && Set(result.stopped) == Set(ids))
    #expect(table.snapshot().records.filter { ids.map(\.pid).contains($0.pid) && ids.contains($0.identity) }.isEmpty)
}

private let agentA = ProcessIdentity(pid: 900, startSec: 5, startUsec: 0)
private let agentB = ProcessIdentity(pid: 901, startSec: 6, startUsec: 0)

private func item(_ kind: RunningKind, launcher: Launcher = .you, session: String? = nil, building: Bool = false,
                  cpuNs: UInt64 = 0, ports: [UInt16] = [], title: String = "x", owner: ProcessIdentity? = nil, orphan: Bool = false) -> RunningItem {
    RunningItem(kind: kind, title: title, project: ProjectRef(root: "/p", name: "p"),
                ports: ports.map { Listener(port: $0, address: "127.0.0.1", isWildcard: false, isLoopback: true) },
                processes: [.init(pid: 100, startSec: 1, startUsec: 0)], memory: 0, cpuNs: cpuNs, launcher: launcher,
                chain: [], sessionID: session, isOrphan: orphan, isBuilding: building, isSystem: false, cwd: "/p", command: "",
                agentProcess: owner)
}

@Test func activityTrackerMeasuresIdleFromFirstSight() {
    let t = ActivityTracker()
    let t0 = Date(timeIntervalSince1970: 1000)
    var a = t.update(items: [item(.devServer, cpuNs: 0, ports: [3000])], established: [:], now: t0)
    #expect(a.values.first?.idleSeconds(now: t0) == 0)
    // Quiet samples one minute apart: idle time accumulates.
    for i in 1...10 { a = t.update(items: [item(.devServer, cpuNs: UInt64(i) * 1000, ports: [3000])], established: [:], now: t0 + Double(i) * 60) }
    #expect(a.values.first?.idleSeconds(now: t0 + 600) == 600)
    // A connection makes it active again.
    a = t.update(items: [item(.devServer, cpuNs: 10_000, ports: [3000])], established: [3000: 2], now: t0 + 660)
    #expect(a.values.first?.connections == 2 && a.values.first?.idleSeconds(now: t0 + 660) == 0)
    // Real CPU use counts as activity: 5 s of CPU over 10 s = 50%.
    a = t.update(items: [item(.devServer, cpuNs: 5_000_010_000, ports: [3000])], established: [:], now: t0 + 670)
    #expect(abs((a.values.first?.cpuPercent ?? 0) - 50) < 0.1 && a.values.first?.idleSeconds(now: t0 + 670) == 0)
    // After a long gap (the Mac slept) nothing is known, so it is not "idle 9 hours".
    a = t.update(items: [item(.devServer, cpuNs: 5_000_010_000, ports: [3000])], established: [:], now: t0 + 670 + 9 * 3600)
    #expect(a.values.first?.idleSeconds(now: t0 + 670 + 9 * 3600) == 0)
    // A child exiting lowers the tree's CPU total: unknown, not idle.
    a = t.update(items: [item(.devServer, cpuNs: 100, ports: [3000])], established: [:], now: t0 + 700 + 9 * 3600)
    #expect(a.values.first?.idleSeconds(now: t0 + 700 + 9 * 3600) == 0)
    // Building is never idle.
    a = t.update(items: [item(.bundler, building: true, cpuNs: 100)], established: [:], now: t0 + 760 + 9 * 3600)
    #expect(a.values.first?.idleSeconds(now: t0 + 760 + 9 * 3600) == 0)
}

@Test func stopPolicyProtectsPinsDatabasesBuildsAndOtherPeoplesThings() {
    let server = item(.devServer, launcher: .claudeCode, session: "s1", owner: agentA)
    #expect(StopPolicy().allowsBulkStop(server))
    #expect(!StopPolicy(pinned: [server.pinKey]).allowsBulkStop(server))
    #expect(!StopPolicy(pinned: ["project:/p"]).allowsBulkStop(server))
    // Bulk actions never touch databases, agent sessions, builds, MCP servers or unrelated apps.
    for kind in [RunningKind.database, .agent, .mcp, .other, .container] { #expect(!StopPolicy().allowsBulkStop(item(kind))) }
    #expect(!StopPolicy().allowsBulkStop(item(.devServer, building: true)))
    #expect(StopPolicy().warning(for: item(.database)) != nil && StopPolicy().warning(for: server) == nil)

    let p = StopPolicy()
    #expect(p.allowsAgentStop(server, callerAgentProcess: agentA))
    #expect(!p.allowsAgentStop(server, callerAgentProcess: agentB))   // another session of the same agent
    #expect(!p.allowsAgentStop(server, callerAgentProcess: nil))      // caller unknown: fail closed
    #expect(!p.allowsAgentStop(item(.devServer, launcher: .claudeCode), callerAgentProcess: agentA)) // owner unknown: fail closed
    #expect(!p.allowsAgentStop(item(.devServer, launcher: .claudeCode, owner: agentA, orphan: true), callerAgentProcess: agentA))
    #expect(!p.allowsAgentStop(item(.database, launcher: .claudeCode, owner: agentA), callerAgentProcess: agentA))
    #expect(!p.allowsAgentStop(item(.mcp, launcher: .claudeCode, owner: agentA), callerAgentProcess: agentA))
}

@Test func nativeClaudeInstallIsAnAgentNotADevServer() {
    let snap = ProcessSnapshot(records: base + [
        rec(60, 12, "2.1.226", argv: ["claude"], path: "/Users/t/.local/share/claude/versions/2.1.226", cwd: "/Users/t/dev/shop"),
        rec(61, 60, "zsh", argv: ["zsh", "-c", "npm run dev"]),
        rec(62, 61, "node", argv: ["node", "/x/node_modules/.bin/vite"], cwd: "/Users/t/dev/shop", ports: [5173]),
    ])
    let items = classifier.classify(snap)
    let agent = items.first { $0.kind == .agent }
    let server = items.first { $0.kind == .devServer }
    #expect(agent?.root.pid == 60 && agent?.processes.count == 1)
    #expect(server?.root.pid == 62 && server?.launcher == .claudeCode && server?.agentProcess?.pid == 60)
}

@Test func stopNeverClimbsIntoEditorsShellsLoginsOrMultiplexers() {
    let snap = ProcessSnapshot(records: base + [
        rec(70, 12, "nvim", argv: ["nvim", "."]),
        rec(71, 70, "node", argv: ["node", "/x/tsserver.js"]),
        rec(72, 11, "nu"),                                              // an unusual login shell
        rec(73, 72, "node", argv: ["node", "server.js"], cwd: "/Users/t/dev/shop", ports: [3000]),
        rec(74, 1, "sshd-session", path: "/usr/libexec/sshd-session", uid: 0),
        rec(75, 74, "zsh"),
        rec(76, 75, "python3", argv: ["python3", "-m", "http.server"], ports: [8000]),
        rec(77, 12, "zellij"),
        rec(78, 77, "zsh"),
        rec(79, 78, "node", argv: ["node", "app.js"], cwd: "/Users/t/dev/shop", ports: [4000]),
        rec(80, 78, "nvim"),
    ])
    let roots = Dictionary(uniqueKeysWithValues: classifier.classify(snap).map { ($0.root.pid, $0.processes.map(\.pid)) })
    #expect(roots[71] == [71])   // not nvim
    #expect(roots[73] == [73])   // not the shell
    #expect(roots[76] == [76])   // not the SSH login
    #expect(roots[79] == [79])   // not zellij and its other panes
    #expect(roots[70] == nil && roots[72] == nil && roots[77] == nil)
}

@Test func inheritedMarkersBehindATerminalAreUnknownNotAgent() {
    let snap = ProcessSnapshot(records: base + [
        rec(85, 1, "tmux", argv: ["tmux", "new"], env: ["CLAUDECODE": "1"]),
        rec(86, 85, "zsh"),
        rec(87, 86, "node", argv: ["node", "server.js"], cwd: "/Users/t/dev/shop", env: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s1"], ports: [3000]),
    ])
    let i = classifier.classify(snap).first { $0.root.pid == 87 }
    #expect(i?.launcher == .unknown && i?.isOrphan == false && i?.agentProcess == nil)
}

@Test func nestedItemKeepsItsOwnPortsAndDaemonChildDoesNotRenameAServer() {
    let snap = ProcessSnapshot(records: base + [
        rec(90, 12, "npm", argv: ["npm", "run", "dev"], cwd: "/Users/t/dev/shop", mem: 100),
        rec(91, 90, "node", argv: ["node", "/x/node_modules/.bin/vite"], cwd: "/Users/t/dev/shop", ports: [5173], mem: 200),
        rec(92, 91, "esbuild", argv: ["esbuild", "--service=0.21", "--ping"], mem: 50),
        rec(93, 91, "postgres", ports: [5432], mem: 5000),
    ])
    let items = classifier.classify(snap)
    let dev = items.first { $0.root.pid == 90 }
    #expect(dev?.kind == .devServer && dev?.title == "npm run dev")
    #expect(dev?.ports.map(\.port) == [5173] && dev?.memory == 350 && dev?.processes.map(\.pid).contains(93) == false)
    #expect(items.first { $0.root.pid == 93 }?.kind == .database)
}

@Test func previewSimulatorUDIDIsFound() {
    let snap = ProcessSnapshot(records: base + [
        rec(95, 1, "launchd_sim", argv: ["launchd_sim", "/Users/t/Library/Developer/Xcode/UserData/Previews/Simulator Devices/PPPP-1/data/var/run/launchd_bootstrap.plist"]),
    ])
    #expect(classifier.classify(snap).first?.externalID == "PPPP-1")
}

@Test func stopperAsksTheRootFirstAndReportsHonestly() async throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "/bin/sleep 300 & /bin/sleep 300 & wait"]
    try p.run()
    try await Task.sleep(for: .milliseconds(300))
    let snap = ProcessTable().snapshot()
    let root = try #require(snap.records.first { $0.pid == p.processIdentifier })
    let kids = snap.records.filter { $0.ppid == p.processIdentifier }.map(\.identity)
    let r = await ProcessStopper(grace: 3).stop([root.identity] + kids)
    p.waitUntilExit()
    #expect(r.succeeded && r.survivors.isEmpty && r.failed.isEmpty && r.stopped.contains(root.identity))
    for k in kids { #expect(ProcessTable.identity(of: k.pid) != k) }
    // Nothing alive to stop: not reported as a success.
    let again = await ProcessStopper(grace: 0.3).stop([root.identity] + kids)
    #expect(!again.succeeded && again.stopped.isEmpty)
    #expect(await ProcessStopper(grace: 0.2).stop([.init(pid: 1, startSec: 0, startUsec: 0)]).failed.count == 1)
}

@Test func serverStartedByTheClaudeDesktopAppIsLabelledButNotAgentOwned() {
    let app = "/Applications/Claude.app/Contents"
    let snap = ProcessSnapshot(records: [
        rec(1, 0, "launchd", uid: 0),
        rec(10, 1, "Claude", path: "\(app)/MacOS/Claude"),
        rec(11, 10, "disclaimer", path: "\(app)/Helpers/disclaimer"),
        rec(12, 11, "node", argv: ["npm exec next dev", ""], cwd: "/Users/t/dev/shop", ports: [3000]),
    ])
    let i = classifier.classify(snap).first { $0.root.pid == 12 }
    #expect(i?.launcher == .claudeCode && i?.agentProcess == nil && i?.isOrphan == false)
    #expect(!StopPolicy().allowsAgentStop(i!, callerAgentProcess: ProcessIdentity(pid: 99, startSec: 1, startUsec: 0)))
}
