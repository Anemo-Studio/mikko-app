import Foundation
import MikkoCore

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

func diskCommand(json: Bool) async {
    let start = Date()
    var results: [DiskCategoryResult] = []
    for await r in DiskScanner().scan(DiskCatalog.standard()) { results.append(r) }
    results.sort { $0.bytes > $1.bytes }
    var byRisk: [RiskLevel: Int64] = [:]
    for r in results { byRisk[r.category.risk, default: 0] += r.bytes }
    let total = results.reduce(0) { $0 + $1.bytes }

    if json {
        let obj: [String: Any] = [
            "free": DiskSpace.current()?.free ?? 0,
            "total": DiskSpace.current()?.total ?? 0,
            "reclaimable": total,
            "byRisk": Dictionary(uniqueKeysWithValues: byRisk.map { ($0.key.label.lowercased(), $0.value) }),
            "categories": results.map { ["id": $0.id, "group": $0.category.group, "title": $0.category.title,
                                         "risk": $0.category.risk.label.lowercased(), "bytes": $0.bytes, "items": $0.items.count] },
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    if let d = DiskSpace.current() {
        print("Free: \(ByteFormat.string(d.free)) of \(ByteFormat.string(d.total))")
    }
    let parts = RiskLevel.allCases.map { "\($0.label) \(ByteFormat.string(byRisk[$0] ?? 0))" }.joined(separator: " · ")
    print("Reclaimable: \(ByteFormat.string(total)) (\(parts))\n")
    for r in results {
        print("\(pad(ByteFormat.string(r.bytes), 10)) \(pad(r.category.risk.label, 8)) \(r.category.group) — \(r.category.title)")
    }
    print(String(format: "\nScanned in %.1fs. Read-only: nothing was changed.", Date().timeIntervalSince(start)))
}

func itemJSON(_ i: RunningItem) -> [String: Any] {
    var o: [String: Any] = [
        "id": i.id, "kind": i.kind.rawValue, "title": i.title, "pid": i.root.pid, "pids": i.processes.map(\.pid),
        "ports": i.ports.map { ["port": Int($0.port), "address": $0.address, "exposedToLAN": $0.exposedToLAN] },
        "memoryBytes": i.memory, "startedAt": ISO8601DateFormatter().string(from: i.startedAt),
        "startedBy": i.launcher.rawValue, "chain": i.chain, "orphan": i.isOrphan, "building": i.isBuilding,
    ]
    if let p = i.project { o["project"] = p.name; o["projectRoot"] = p.root }
    if let b = i.project?.branch { o["branch"] = b }
    if let s = i.sessionID { o["sessionId"] = s }
    return o
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func statusCommand(json: Bool, portsOnly: Bool, showSystem: Bool) {
    let items = RunningScanner().scan().items
        .filter { showSystem || !$0.isSystem }
        .filter { !portsOnly || !$0.ports.isEmpty }
    if json { printJSON(items.map(itemJSON)); return }
    if items.isEmpty { print("Nothing left running."); return }
    if portsOnly {
        for i in items.sorted(by: { ($0.primaryPort ?? 0) < ($1.primaryPort ?? 0) }) {
            for l in i.ports {
                let lan = l.exposedToLAN ? "  ⚠ exposed to LAN" : ""
                print("\(pad(String(l.port), 7))\(pad(i.title + (i.project.map { " (\($0.name))" } ?? ""), 38)) pid \(pad(String(i.root.pid), 7)) \(i.launcher.label)\(lan)")
            }
        }
        return
    }
    let mem = MemoryStatus.current()
    print("Memory: \(ByteFormat.string(Int64(mem.used))) of \(ByteFormat.string(Int64(mem.total))) used · pressure \(mem.pressure.label) · swap \(ByteFormat.string(Int64(mem.swapUsed)))\n")
    for kind in RunningKind.allCases {
        let group = items.filter { $0.kind == kind }.sorted { $0.memory > $1.memory }
        guard !group.isEmpty else { continue }
        print("\(kind.title) — \(group.count), \(ByteFormat.string(Int64(group.reduce(0) { $0 + $1.memory })))")
        for i in group {
            let name = i.title + (i.project.map { " (\($0.name))" } ?? "")
            let port = i.primaryPort.map { ":\($0)" } ?? ""
            var flags: [String] = []
            if i.isOrphan { flags.append("orphan") }
            if i.isBuilding { flags.append("building") }
            if i.exposedToLAN { flags.append("LAN") }
            print("  \(pad(name, 40)) \(pad(port, 7)) \(pad(ByteFormat.string(Int64(i.memory)), 10)) \(pad(DurationFormat.short(Date().timeIntervalSince(i.startedAt)), 5)) \(pad(i.launcher.label, 24)) \(flags.joined(separator: ","))")
        }
        print("")
    }
}

func sessionsCommand(_ args: [String]) {
    guard let app = try? AppDatabase.openDefault() else { print("mikko: cannot open the local database"); exit(1) }
    let start = Date()
    let summary = SessionIndexer().index(into: app)
    if args.first == "search", args.count > 1 {
        let hits = (try? app.search(args.dropFirst().joined(separator: " "), limit: 20)) ?? []
        for h in hits {
            let title = (try? app.session(path: h.path))?.title ?? h.path
            print("[\(h.kind.rawValue)] \(title.prefix(60))\n    \(h.snippet.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        }
        if hits.isEmpty { print("No matches.") }
        return
    }
    let rows = (try? app.sessions(limit: 15)) ?? []
    print("Sessions: \(summary.found) found, \(summary.indexed) indexed now, \(summary.unchanged) unchanged, \(summary.failed) skipped (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)\n")
    for r in rows {
        let cost = String(format: "$%.2f", r.cost) + (r.hasUnpriced ? "+" : "")
        print("\(pad(r.started.formatted(date: .numeric, time: .shortened), 18)) \(pad(r.agent.displayName, 12)) \(pad(String(r.project.prefix(18)), 19)) \(pad(cost, 9)) \(r.title.prefix(60))")
    }
}

/// Pins are set in the app; the CLI and MCP server read them from the app's preferences.
func appPins() -> Set<String> {
    Set(UserDefaults(suiteName: "app.mikko.Mikko")?.stringArray(forKey: "pinnedRunning") ?? [])
}

func stopCommand(_ args: [String]) async {
    guard let n = args.first(where: { !$0.hasPrefix("-") }).flatMap({ Int($0) }) else {
        print("Usage: mikko stop <port|pid> [--yes] [--force]"); exit(2)
    }
    let items = RunningScanner().scan().items
    guard let item = items.first(where: { $0.ports.contains { Int($0.port) == n } })
            ?? items.first(where: { $0.processes.contains { Int($0.pid) == n } }) else {
        print("Nothing mikko manages is using \(n)."); exit(1)
    }
    let policy = StopPolicy(pinned: appPins())
    let name = item.title + (item.project.map { " (\($0.name))" } ?? "")
    // P-8: when an agent runs this command, the agent rules apply and --yes cannot override them.
    let caller = MCPServer.Caller.detect()
    if caller.agent.isAgent {
        let db = try? AppDatabase.openDefault()
        let guardrail = MCPServer(caller: caller, scan: { items }, pinned: { appPins() })
        let target = "\(name) (pid \(item.root.pid))"
        if let why = guardrail.refusal(for: item) {
            try? db?.logAgentAction(agent: caller.agent.rawValue, sessionID: caller.sessionID, tool: "cli stop", target: target, result: "refused: \(why)")
            print("Refused. \(why)"); exit(1)
        }
        try? db?.logAgentAction(agent: caller.agent.rawValue, sessionID: caller.sessionID, tool: "cli stop", target: target, result: "requested")
    } else {
        if policy.isPinned(item), !args.contains("--yes") { print("\(name) is pinned. Add --yes to stop it anyway."); exit(1) }
        if let warning = policy.warning(for: item), !args.contains("--yes") { print("\(name): \(warning)\nAdd --yes to stop it anyway."); exit(1) }
    }
    let stopper = ProcessStopper(grace: item.kind == .database ? 10 : 5)
    var result = await stopper.stop(item.processes)
    var stopped = result.stopped.count
    if !result.survivors.isEmpty, args.contains("--force"), !caller.agent.isAgent {
        result = await stopper.forceStop(result.survivors)
        stopped += result.stopped.count
    }
    if result.survivors.isEmpty, result.failed.isEmpty, stopped > 0 {
        print("Stopped \(name): \(stopped) process\(stopped == 1 ? "" : "es").")
    } else if stopped == 0, result.survivors.isEmpty {
        print("\(name) was already gone or could not be signalled."); exit(1)
    } else {
        print("\(name) did not stop: \(result.survivors.count + result.failed.count) still running. Add --force to end it."); exit(1)
    }
}

func mcpCommand() async {
    let db = try? AppDatabase.openDefault()
    let scanner = RunningScanner()
    let caller = MCPServer.Caller.detect()
    let server = MCPServer(
        caller: caller,
        scan: { scanner.scan().items },
        pinned: { appPins() },
        diskStatus: {
            var safe: Int64 = 0, total: Int64 = 0
            for await r in DiskScanner().scan(DiskCatalog.standard()) {
                total += r.bytes
                if r.category.risk == .safe { safe += r.bytes }
            }
            let d = DiskSpace.current()
            return ["free_bytes": d?.free ?? 0, "total_bytes": d?.total ?? 0, "reclaimable_bytes": total, "safely_reclaimable_bytes": safe,
                    "note": "Cleaning is done by the user in the mikko app."]
        },
        log: { tool, target, result in
            try? db?.logAgentAction(agent: caller.agent.rawValue, sessionID: caller.sessionID, tool: tool, target: target, result: result)
        })
    await server.runStdio()
}

/// C-1, C-2: containers on every engine found, and what they take on disk. Read-only.
func containersCommand(json: Bool) {
    let engines = DockerClient.discover()
    guard !engines.isEmpty else { print("No container engine is running (Docker Desktop, OrbStack, Colima, Rancher or Podman)."); return }
    var out: [[String: Any]] = []
    for engine in engines {
        do {
            let list = try engine.containers()
            let df = try? engine.diskUsage()
            if json {
                out.append(["engine": engine.runtimeName,
                            "containers": list.map { ["name": $0.name, "image": $0.image, "running": $0.isRunning, "status": $0.status,
                                                      "ports": $0.ports.map(Int.init), "compose": $0.composeProject ?? NSNull()] as [String: Any] },
                            "disk": df.map { ["images": $0.imagesBytes, "unused_images": $0.unusedImagesBytes, "stopped_containers": $0.stoppedContainersBytes,
                                              "build_cache": $0.buildCacheBytes, "volumes": $0.volumesBytes,
                                              "unused_volumes": $0.unusedVolumes.map(\.name)] as [String: Any] } ?? NSNull()])
                continue
            }
            print("\(engine.runtimeName) — \(list.filter(\.isRunning).count) running, \(list.filter { !$0.isRunning }.count) stopped")
            for c in list.sorted(by: { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }) {
                let ports = c.ports.isEmpty ? "" : "  :" + c.ports.map(String.init).joined(separator: ",")
                print("  \(c.isRunning ? "●" : "○") \(pad(c.name, 34)) \(pad(c.composeProject ?? "", 14)) \(c.status)\(ports)")
            }
            if let df {
                print("  Disk: images \(ByteFormat.string(df.imagesBytes)) (unused \(ByteFormat.string(df.unusedImagesBytes))), " +
                      "stopped containers \(ByteFormat.string(df.stoppedContainersBytes)), build cache \(ByteFormat.string(df.buildCacheBytes)), " +
                      "volumes \(ByteFormat.string(df.volumesBytes)) (\(df.unusedVolumes.count) unused)")
            }
        } catch {
            if json { out.append(["engine": engine.runtimeName, "error": "\(error)"]) } else { print("\(engine.runtimeName): \(error)") }
        }
    }
    if json, let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "disk":
    await diskCommand(json: args.contains("--json"))
case "stop":
    await stopCommand(Array(args.dropFirst()))
case "wait":
    guard args.count > 1, let port = UInt16(args[1]) else { print("Usage: mikko wait <port> [--timeout <seconds>]"); exit(2) }
    let timeout = args.firstIndex(of: "--timeout").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 60
    if Ports.wait(for: port, timeout: timeout) { print("Port \(port) is answering.") } else { print("Port \(port) did not answer within \(Int(timeout))s."); exit(1) }
case "mcp":
    await mcpCommand()
case "containers":
    containersCommand(json: args.contains("--json"))
case "sessions":
    sessionsCommand(Array(args.dropFirst()))
case "status":
    statusCommand(json: args.contains("--json"), portsOnly: false, showSystem: args.contains("--all"))
case "ports":
    statusCommand(json: args.contains("--json"), portsOnly: true, showSystem: args.contains("--all"))
default:
    print("""
    mikko — see what you and your agents left running

    Usage:
      mikko status [--json] [--all]   everything running, grouped, with memory
      mikko ports  [--json] [--all]   who holds which port and who started it
      mikko stop <port|pid> [--yes] [--force]   stop the whole process tree
      mikko wait <port> [--timeout <s>]         wait until a port answers
      mikko disk   [--json]           reclaimable disk space (read-only)
      mikko containers [--json]       containers on every engine, and their disk use (read-only)
      mikko mcp                       run as an MCP server for agents (stdio)
      mikko sessions                  recent agent sessions with API-equivalent cost
      mikko sessions search <text>    search every session
    """)
}
