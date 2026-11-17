import Foundation
import Testing
@testable import MikkoCore

private let me = ProcessIdentity(pid: 9000, startSec: 1, startUsec: 0)
private let other = ProcessIdentity(pid: 9001, startSec: 2, startUsec: 0)

private func running(_ pid: Int32, kind: RunningKind = .devServer, launcher: Launcher, session: String? = nil, port: UInt16,
                     building: Bool = false, title: String = "vite", owner: ProcessIdentity? = nil) -> RunningItem {
    RunningItem(kind: kind, title: title, project: ProjectRef(root: "/p", name: "p"),
                ports: [Listener(port: port, address: "127.0.0.1", isWildcard: false, isLoopback: true)],
                processes: [.init(pid: pid, startSec: 1, startUsec: 0)], memory: 10 << 20, cpuNs: 0, launcher: launcher,
                chain: [], sessionID: session, isOrphan: false, isBuilding: building, isSystem: false, cwd: "/p", command: "",
                agentProcess: owner)
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped: [[ProcessIdentity]] = []
    private var _log: [String] = []
    func stop(_ ids: [ProcessIdentity]) { lock.lock(); _stopped.append(ids); lock.unlock() }
    func note(_ s: String) { lock.lock(); _log.append(s); lock.unlock() }
    var stopped: [[ProcessIdentity]] { lock.lock(); defer { lock.unlock() }; return _stopped }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
}

private func server(_ caller: MCPServer.Caller, items: [RunningItem], pinned: Set<String> = [], rec: Recorder) -> MCPServer {
    MCPServer(caller: caller, scan: { items }, pinned: { pinned },
              stop: { ids in rec.stop(ids); return StopResult(stopped: ids) },
              log: { tool, target, result in rec.note("\(tool)|\(target)|\(result)") })
}

private func callTool(_ s: MCPServer, _ name: String, _ args: [String: Any]) async -> (text: String, isError: Bool) {
    let reply = await s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])
    let result = reply?["result"] as? [String: Any]
    let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    return (text, (result?["isError"] as? Bool) ?? true)
}

@Test func mcpHandshakeAndToolList() async {
    let s = server(.init(agent: .claudeCode, sessionID: "s1", agentProcess: me), items: [], rec: Recorder())
    let initReply = await s.handle(["jsonrpc": "2.0", "id": "abc", "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
    #expect(((initReply?["result"] as? [String: Any])?["protocolVersion"] as? String) == "2025-03-26")
    #expect(initReply?["id"] as? String == "abc") // string ids are echoed as given
    let odd = await s.handle(["jsonrpc": "2.0", "id": 9, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
    #expect(((odd?["result"] as? [String: Any])?["protocolVersion"] as? String) == "2025-06-18")
    #expect(await s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    let list = await s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    #expect(names == ["list_running", "find_port", "suggest_free_port", "stop", "wait_for_port", "disk_status"])
    // No tool lets an agent clean the disk or delete sessions.
    #expect(names?.contains { $0.contains("clean") || $0.contains("delete") } == false)
    let unknown = await s.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
    #expect(((unknown?["error"] as? [String: Any])?["code"] as? Int) == -32601)
}

@Test func agentsStopOnlyWhatTheyStarted() async {
    let rec = Recorder()
    let mine = running(100, launcher: .claudeCode, session: "s1", port: 5173, owner: me)
    let items = [
        mine,
        running(200, launcher: .claudeCode, session: "other", port: 5174, owner: other),    // another Claude session
        running(300, launcher: .you, port: 3000, title: "next dev"),
        running(400, launcher: .codex, port: 8000, owner: other),
        running(500, kind: .database, launcher: .claudeCode, session: "s1", port: 5432, title: "postgres", owner: me),
        running(600, launcher: .claudeCode, session: "s1", port: 4000, building: true, owner: me),
        running(700, launcher: .claudeCode, session: "s1", port: 4100, title: "pinned-one", owner: me),
        running(800, launcher: .unknown, port: 9000),
        running(850, launcher: .claudeCode, port: 9100),                                     // Claude-labelled, owner unknown
        running(860, kind: .mcp, launcher: .claudeCode, port: 9200, owner: me),              // user-configured MCP server
        running(870, kind: .other, launcher: .claudeCode, port: 9300, owner: me),
    ]
    let pinnedKey = items[6].pinKey
    let s = server(.init(agent: .claudeCode, sessionID: "s1", agentProcess: me), items: items, pinned: [pinnedKey], rec: rec)

    let ok = await callTool(s, "stop", ["port": 5173])
    #expect(!ok.isError && rec.stopped == [mine.processes])
    let refusedPorts = [5174, 3000, 8000, 5432, 4000, 4100, 9000, 9100, 9200, 9300]
    for port in refusedPorts {
        let r = await callTool(s, "stop", ["port": port])
        #expect(r.isError && r.text.hasPrefix("Refused"), "port \(port) must be refused")
    }
    #expect(rec.stopped.count == 1)
    // Arguments that are not a real port never reach a process.
    for bad: Any in [true, 1.5, 0, -3, 70000, "5173"] { #expect(await callTool(s, "stop", ["port": bad]).isError) }
    #expect(await callTool(s, "find_port", ["port": 70000]).isError)
    #expect(await callTool(s, "wait_for_port", ["port": -1]).isError)
    #expect(rec.stopped.count == 1)
    // Every attempt, allowed or not, is in the action log (A-3): requested + stopped, then one per refusal.
    #expect(rec.log.count == 2 + refusedPorts.count && rec.log[0].hasSuffix("|requested") && rec.log[1].hasSuffix("|stopped"))
    #expect(rec.log[2].contains("refused") && rec.log[0].contains("pid 100"))

    // A caller mikko cannot place under a living agent process stops nothing, even with the right labels.
    let noProcess = server(.init(agent: .claudeCode, sessionID: "s1"), items: items, rec: rec)
    #expect(await callTool(noProcess, "stop", ["port": 5173]).isError)
    let anon = server(.init(agent: .unknown), items: items, rec: rec)
    #expect(await callTool(anon, "stop", ["port": 5173]).isError && rec.stopped.count == 1)

    let found = await callTool(s, "find_port", ["port": 3000])
    #expect(!found.isError && found.text.contains("next dev") && found.text.contains("\"started_by\":\"you\""))
    let listed = await callTool(s, "list_running", [:])
    #expect(listed.text.contains("postgres") && !listed.isError)
}

@Test func stopThatStopsNothingIsNotReportedAsSuccess() async {
    let rec = Recorder()
    let mine = running(100, launcher: .claudeCode, port: 5173, owner: me)
    let s = MCPServer(caller: .init(agent: .claudeCode, agentProcess: me), scan: { [mine] }, stop: { ids in StopResult(stale: ids) },
                      log: { _, _, r in rec.note(r) })
    let r = await callTool(s, "stop", ["port": 5173])
    #expect(r.isError && r.text.contains("\"stopped\":false") && rec.log.last == "nothing was stopped")
}

@Test func callerIsFoundByProcessAncestryNotEnvironment() {
    func r(_ pid: Int32, _ ppid: Int32, _ name: String, path: String? = nil) -> ProcRecord {
        ProcRecord(identity: .init(pid: pid, startSec: Int64(pid), startUsec: 0), ppid: ppid, uid: 501, name: name, path: path ?? "/bin/\(name)", argv: [name])
    }
    let records = [r(1, 0, "launchd"), r(10, 1, "Terminal"), r(20, 10, "zsh"),
                   r(30, 20, "2.1.226", path: "/Users/t/.local/share/claude/versions/2.1.226"), r(40, 30, "mikko"),
                   r(50, 20, "mikko")]
    let under = MCPServer.Caller.detect([:], records: records, pid: 40)
    #expect(under.agent == .claudeCode && under.agentProcess?.pid == 30)
    // Markers in the environment do not create an agent process.
    let spoofed = MCPServer.Caller.detect(["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x"], records: records, pid: 50)
    #expect(spoofed.agent == .claudeCode && spoofed.agentProcess == nil)
    #expect(MCPServer.Caller.detect(["PATH": "/bin"], records: records, pid: 50).agent == .unknown)
}

@Test func callerDetectionAndPorts() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(fd, 16)
    var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let port = UInt16(bigEndian: out.sin_port)
    #expect(Ports.isAccepting(port) && Ports.wait(for: port, timeout: 1))
    #expect(!Ports.wait(for: 1, timeout: 0.3))
    let free = try #require(Ports.suggestFree(from: port, taken: [port]))
    #expect(free > port)

    let app = try AppDatabase(db: .inMemory())
    try app.logAgentAction(agent: "claudeCode", sessionID: "s", tool: "stop", target: "vite (port 5173)", result: "stopped")
    #expect(try app.agentActions().first?.target == "vite (port 5173)")
}
