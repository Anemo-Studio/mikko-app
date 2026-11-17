import Foundation

/// A-2: a small MCP server over stdio. Agents can look, and stop only what they started.
public final class MCPServer: @unchecked Sendable {
    public struct Caller: Sendable {
        public var agent: Launcher
        public var sessionID: String?
        /// The agent process this server runs under, found by walking up from our own pid.
        public var agentProcess: ProcessIdentity?

        public init(agent: Launcher, sessionID: String? = nil, agentProcess: ProcessIdentity? = nil) {
            self.agent = agent; self.sessionID = sessionID; self.agentProcess = agentProcess
        }

        /// Who is calling. The process ancestry decides; environment markers only fill in
        /// the label and session id when no agent ancestor is found.
        public static func detect(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                  records: [ProcRecord]? = nil, pid: Int32 = getpid()) -> Caller {
            let records = records ?? ProcessTable().snapshot().records
            let byPid = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            var cur = byPid[pid]
            var hops = 0
            while hops < 32, let c = cur, let parent = byPid[c.ppid], parent.pid != c.pid, parent.pid > 1 {
                hops += 1
                if let kind = AgentKind.detect(parent) {
                    return Caller(agent: kind.launcher, sessionID: env["CLAUDE_CODE_SESSION_ID"] ?? env["CODEX_THREAD_ID"], agentProcess: parent.identity)
                }
                cur = parent
            }
            if env["CLAUDECODE"] == "1" { return Caller(agent: .claudeCode, sessionID: env["CLAUDE_CODE_SESSION_ID"]) }
            if env["CODEX_THREAD_ID"] != nil || env["CODEX_SANDBOX"] != nil { return Caller(agent: .codex, sessionID: env["CODEX_THREAD_ID"]) }
            if env["CURSOR_AGENT"] == "1" { return Caller(agent: .cursor) }
            return Caller(agent: .unknown)
        }
    }

    public var caller: Caller
    public var scan: @Sendable () -> [RunningItem]
    public var pinned: @Sendable () -> Set<String>
    public var stop: @Sendable ([ProcessIdentity]) async -> StopResult
    public var diskStatus: @Sendable () async -> [String: Any]
    public var log: @Sendable (_ tool: String, _ target: String, _ result: String) -> Void

    public init(caller: Caller = .detect(),
                scan: @escaping @Sendable () -> [RunningItem],
                pinned: @escaping @Sendable () -> Set<String> = { [] },
                stop: @escaping @Sendable ([ProcessIdentity]) async -> StopResult = { await ProcessStopper().stop($0) },
                diskStatus: @escaping @Sendable () async -> [String: Any] = { [:] },
                log: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in }) {
        self.caller = caller; self.scan = scan; self.pinned = pinned; self.stop = stop; self.diskStatus = diskStatus; self.log = log
    }

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        tool("list_running", "Everything running on this Mac that a developer or agent started: dev servers, bundlers, agents, simulators, databases, MCP servers. Check this before starting another server or emulator.", [:]),
        tool("find_port", "Who holds a TCP port, and who started it.", ["port": ["type": "integer"]], required: ["port"]),
        tool("suggest_free_port", "The next free TCP port at or after `preferred` (default 3000).", ["preferred": ["type": "integer"]]),
        tool("stop", "Stop something YOU started in this session, by port or pid. The whole process tree is stopped. Refused for anything started by a person or another agent, and for databases, pinned items and running builds.",
             ["port": ["type": "integer"], "pid": ["type": "integer"]]),
        tool("wait_for_port", "Wait until a server answers on a port. Returns whether it came up.",
             ["port": ["type": "integer"], "timeout_seconds": ["type": "number"]], required: ["port"]),
        tool("disk_status", "Free disk space and how much developer-tool data could be reclaimed. Read-only; agents cannot clean.", [:]),
    ]

    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    static func describe(_ i: RunningItem) -> [String: Any] {
        var o: [String: Any] = [
            "title": i.title, "kind": i.kind.rawValue, "pid": Int(i.root.pid), "ports": i.ports.map { Int($0.port) },
            "memory_mb": Int(i.memory / 1_048_576), "started_by": i.launcher.rawValue,
            "running_for_seconds": Int(Date().timeIntervalSince(i.startedAt)), "building": i.isBuilding,
            "exposed_to_lan": i.exposedToLAN,
        ]
        if let p = i.project { o["project"] = p.name }
        if let s = i.sessionID { o["session_id"] = s }
        return o
    }

    /// Why this caller may not stop this item, or nil if it may.
    public func refusal(for item: RunningItem) -> String? {
        let policy = StopPolicy(pinned: pinned())
        if !caller.agent.isAgent { return "mikko could not tell which agent is calling, so it will not stop anything." }
        if policy.isPinned(item) { return "It is pinned by the user." }
        if item.kind == .database { return "It is a database; only the user can stop those." }
        if item.kind == .agent { return "It is an agent session." }
        if item.kind == .mcp { return "It is an MCP server the user configured, not something you started." }
        if item.isBuilding { return "A build is in progress." }
        if ![.devServer, .bundler, .simulator].contains(item.kind) { return "It is not a dev server, bundler or simulator." }
        if item.launcher != caller.agent { return "It was not started by you (\(item.launcher.label))." }
        if caller.agentProcess == nil { return "mikko could not find the agent process this server runs under, so it cannot confirm what you started." }
        if !policy.allowsAgentStop(item, callerAgentProcess: caller.agentProcess) { return "It was started by a different session, or its session has ended." }
        return nil
    }

    /// A whole number in 1…65535, or nil. Booleans, fractions and out-of-range values are rejected.
    static func port(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d == d.rounded(), d >= 1, d <= 65535 else { return nil }
        return Int(d)
    }

    static func pid(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d == d.rounded(), d > 1, d < 10_000_000 else { return nil }
        return Int(d)
    }

    func call(_ name: String, _ args: [String: Any]) async -> (result: Any, isError: Bool) {
        let badPort = "port must be a whole number from 1 to 65535"
        switch name {
        case "list_running":
            return (["items": scan().filter { !$0.isSystem && $0.kind != .other }.map(Self.describe)], false)
        case "find_port":
            guard let port = Self.port(args["port"]) else { return (badPort, true) }
            let item = scan().first { $0.ports.contains { Int($0.port) == port } }
            return (item.map { ["in_use": true, "holder": Self.describe($0)] as [String: Any] } ?? ["in_use": Ports.isAccepting(UInt16(port))], false)
        case "suggest_free_port":
            if args["preferred"] != nil, Self.port(args["preferred"]) == nil { return ("preferred " + badPort.dropFirst(5), true) }
            let taken = Set(scan().flatMap { $0.ports.map(\.port) })
            guard let free = Ports.suggestFree(from: UInt16(Self.port(args["preferred"]) ?? 3000), taken: taken) else { return ("no free port found", true) }
            return (["port": Int(free)], false)
        case "wait_for_port":
            guard let port = Self.port(args["port"]) else { return (badPort, true) }
            let timeout = min(max((args["timeout_seconds"] as? NSNumber)?.doubleValue ?? 30, 0), 120)
            let up = await Task.detached { Ports.wait(for: UInt16(port), timeout: timeout) }.value
            return (["ready": up], false)
        case "disk_status":
            return (await diskStatus(), false)
        case "stop":
            let port = Self.port(args["port"]), pid = Self.pid(args["pid"])
            guard port != nil || pid != nil else { return ("Give a port (1–65535) or a pid.", true) }
            let items = scan()
            let label = port.map { "port \($0)" } ?? "pid \(pid!)"
            let target: RunningItem? = port.flatMap { p in items.first { $0.ports.contains { Int($0.port) == p } } }
                ?? pid.flatMap { p in items.first { $0.processes.contains { Int($0.pid) == p } } }
            guard let target else {
                log("stop", label, "nothing found")
                return ("Nothing mikko manages is using \(label).", true)
            }
            let name = "\(target.title) (\(label), pid \(target.root.pid))"
            if let why = refusal(for: target) {
                log("stop", name, "refused: \(why)")
                return ("Refused. \(why)", true)
            }
            log("stop", name, "requested")
            let r = await stop(target.processes)
            let outcome = r.succeeded ? "stopped" : r.stopped.isEmpty ? "nothing was stopped" : "\(r.survivors.count + r.failed.count) processes did not exit"
            log("stop", name, outcome)
            return (["stopped": r.succeeded, "title": target.title, "processes_stopped": r.stopped.count,
                     "still_running": r.survivors.count + r.failed.count], !r.succeeded)
        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    /// Handles one JSON-RPC message; returns the reply, or nil for notifications.
    public func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil } // notification
        func ok(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            let asked = (message["params"] as? [String: Any])?["protocolVersion"] as? String
            let version = asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            return ok(["protocolVersion": version, "capabilities": ["tools": [:] as [String: Any]],
                       "serverInfo": ["name": "mikko", "version": "0.1.0"],
                       "instructions": "Use list_running before starting a dev server or emulator, and stop what you started when you are done."])
        case "ping": return ok([:] as [String: Any])
        case "tools/list": return ok(["tools": Self.tools])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let (result, isError) = await call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            let text: String
            if let s = result as? String { text = s } else {
                let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8)
                text = String(decoding: data, as: UTF8.self)
            }
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    /// Serves newline-delimited JSON-RPC on stdin/stdout until stdin closes. Each request runs in
    /// its own task, so a long `wait_for_port` does not hold up a ping; writes are serialised.
    public func runStdio() async {
        let writeLock = NSLock()
        @Sendable func send(_ reply: [String: Any]) {
            guard let out = try? JSONSerialization.data(withJSONObject: reply) else { return }
            writeLock.lock(); defer { writeLock.unlock() }
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        await withTaskGroup(of: Void.self) { group in
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                    continue
                }
                let box = MessageBox(message)
                group.addTask { [self] in
                    if let reply = await handle(box.value) { send(reply) }
                }
            }
        }
    }
}

/// Carries one decoded JSON message into a task; it is never mutated.
private struct MessageBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
