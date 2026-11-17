import Foundation
import Testing
@testable import MikkoCore

private func tmp() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-sess-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func jsonl(_ objects: [[String: Any]], partial: String = "") -> Data {
    var d = Data()
    for o in objects { d.append(try! JSONSerialization.data(withJSONObject: o)); d.append(0x0A) }
    d.append(Data(partial.utf8))
    return d
}

private func assistant(_ id: String, _ req: String, blocks: [[String: Any]], usage: [String: Any], ts: String = "2026-11-10T10:00:05.000Z",
                       model: String = "claude-opus-5-5") -> [String: Any] {
    ["type": "assistant", "uuid": UUID().uuidString, "timestamp": ts, "requestId": req, "cwd": "/Users/t/dev/shop",
     "message": ["id": id, "model": model, "role": "assistant", "content": blocks, "usage": usage]]
}

private nonisolated(unsafe) let usageA: [String: Any] = ["input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 1000,
                                     "cache_creation_input_tokens": 300,
                                     "cache_creation": ["ephemeral_5m_input_tokens": 200, "ephemeral_1h_input_tokens": 100]]

private func claudeFixture() -> [[String: Any]] {
    [
        ["type": "ai-title", "aiTitle": "Fix port clash"],
        ["type": "user", "uuid": "u1", "timestamp": "2026-11-10T10:00:00.000Z", "cwd": "/Users/t/dev/shop", "gitBranch": "main",
         "message": ["role": "user", "content": "Port 3000 already in use — who holds it?"]],
        ["type": "api-request", "blob": String(repeating: "x", count: 5000)],
        // One API response split over three lines with identical usage: must count once.
        assistant("m1", "r1", blocks: [["type": "thinking", "thinking": "hmm"]], usage: usageA),
        assistant("m1", "r1", blocks: [["type": "text", "text": "Let me check with lsof."]], usage: usageA),
        assistant("m1", "r1", blocks: [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "lsof -i :3000"]]], usage: usageA),
        ["type": "user", "uuid": "u2", "timestamp": "2026-11-10T10:00:06.000Z",
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "node 4242", "is_error": true]]]],
        assistant("m2", "r2", blocks: [["type": "tool_use", "id": "t2", "name": "Edit", "input": ["file_path": "/Users/t/dev/shop/server.js"]]],
                  usage: ["input_tokens": 10, "output_tokens": 5], ts: "2026-11-11T09:00:00.000Z"),
        ["type": "user", "uuid": "u3", "timestamp": "2026-11-11T09:00:01.000Z", "toolUseResult": [
            "filePath": "/Users/t/dev/shop/server.js",
            "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-port 3000", "+port 3001"]]]],
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t2", "content": "ok"]]]],
        assistant("m3", "r3", blocks: [["type": "text", "text": "Done"]], usage: ["input_tokens": 1, "output_tokens": 1], model: "<synthetic>"),
        ["type": "brand-new-type-from-the-future", "x": 1],
    ]
}

@Test func claudeParserDedupesUsageAndExtractsWhatMatters() throws {
    let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("sess-1.jsonl").path
    try jsonl(claudeFixture(), partial: "{\"type\":\"user\",\"mess").write(to: URL(fileURLWithPath: path))
    let sub = dir.appendingPathComponent("agent-a.jsonl").path
    try jsonl([assistant("s1", "rs1", blocks: [], usage: ["input_tokens": 7, "output_tokens": 3], model: "claude-haiku-5-5")]).write(to: URL(fileURLWithPath: sub))

    let s = try #require(ClaudeParser.parse(path: path, subagentPaths: [sub]))
    #expect(s.id == "sess-1" && s.title == "Fix port clash" && s.cwd == "/Users/t/dev/shop" && s.gitBranch == "main")
    #expect(s.firstPrompt?.hasPrefix("Port 3000") == true && !s.hasErrors) // a failed tool call is not a session error
    #expect(s.messageCount == 3) // 1 prompt + 2 spoken replies; tool results and the half-written last line do not count
    #expect(s.filesChanged == ["/Users/t/dev/shop/server.js"])
    #expect(s.models == ["claude-haiku-5-5", "claude-opus-5-5"])
    let opus = s.usage.filter { $0.model == "claude-opus-5-5" }
    #expect(opus.count == 2) // two days
    let total = opus.reduce(TokenUsage()) { $0 + $1.usage }
    #expect(total == TokenUsage(input: 110, output: 55, cacheRead: 1000, cacheWrite5m: 200, cacheWrite1h: 100))
    #expect(s.usage.first { $0.model == "claude-haiku-5-5" }?.usage.input == 7) // subagent usage is added
    #expect(!s.usage.contains { $0.model == "<synthetic>" })
    #expect(Set(s.texts.map(\.kind)) == [.user, .assistant, .command, .file])
    #expect(s.texts.first { $0.kind == .command }?.text == "lsof -i :3000")

    let t = ClaudeParser.transcript(path: path)
    #expect(t.map(\.kind) == [.user, .assistant, .tool, .toolResult, .tool, .toolResult, .fileChange, .assistant])
    #expect(t.first { $0.kind == .fileChange }?.text.contains("+port 3001") == true)
    #expect(t.first { $0.kind == .toolResult }?.isError == true)
}

@Test func codexParserReadsUsageAndRateLimits() throws {
    let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("rollout-2026-11-12T08-00-00-11111111-2222-3333-4444-555555555555.jsonl").path
    func line(_ type: String, _ payload: [String: Any], _ ts: String = "2026-11-12T08:00:00.000Z") -> [String: Any] {
        ["timestamp": ts, "type": type, "payload": payload]
    }
    try jsonl([
        line("session_meta", ["id": "11111111-2222-3333-4444-555555555555", "cwd": "/Users/t/dev/api", "git": ["branch": "dev"]]),
        line("turn_context", ["model": "gpt-5.3-codex", "cwd": "/Users/t/dev/api"]),
        line("event_msg", ["type": "user_message", "message": "add a health endpoint"]),
        line("response_item", ["type": "function_call", "name": "shell", "arguments": "{\"command\":[\"rg\",\"health\"]}", "call_id": "c1"]),
        line("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": ["primary": ["used_percent": 10, "window_minutes": 300, "resets_at": 1_800_000_000]]]),
        line("event_msg", ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": 200],
                                                           "total_token_usage": ["input_tokens": 99999]],
                           "rate_limits": ["primary": ["used_percent": 42.5, "window_minutes": 300, "resets_at": 1_800_000_000],
                                           "secondary": ["used_percent": 81, "window_minutes": 10080, "resets_at": 1_800_500_000]]], "2026-11-12T08:05:00.000Z"),
        // Codex re-emits the same event: the total has not moved, so nothing is added.
        line("event_msg", ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": 200],
                                                           "total_token_usage": ["input_tokens": 99999]]], "2026-11-12T08:05:01.000Z"),
        // Real growth of the running total: +500 input (100 of it cached), +50 output.
        line("event_msg", ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 7, "cached_input_tokens": 7, "output_tokens": 7],
                                                           "total_token_usage": ["input_tokens": 100499, "cached_input_tokens": 100, "output_tokens": 50]]], "2026-11-12T08:05:30.000Z"),
        line("event_msg", ["type": "patch_apply_end", "changes": ["/Users/t/dev/api/health.go": ["type": "add", "unified_diff": "+ok"]]]),
        line("event_msg", ["type": "agent_message", "message": "Added /health."], "2026-11-12T08:06:00.000Z"),
    ]).write(to: URL(fileURLWithPath: path))

    let s = try #require(CodexParser.parse(path: path))
    #expect(s.id == "11111111-2222-3333-4444-555555555555" && s.agent == .codex && s.cwd == "/Users/t/dev/api" && s.gitBranch == "dev")
    #expect(s.messageCount == 2 && s.models == ["gpt-5.3-codex"] && s.filesChanged == ["/Users/t/dev/api/health.go"])
    // cached tokens are a subset of input; per-turn usage is used, never the cumulative total.
    #expect(s.usage.map(\.usage) == [TokenUsage(input: 600 + 400, output: 200 + 50, cacheRead: 400 + 100)])
    let limits = Dictionary(uniqueKeysWithValues: s.rateLimits.map { ($0.window, $0) })
    #expect(limits["5h"]?.usedPercent == 42.5 && limits["weekly"]?.usedPercent == 81 && limits["5h"]?.isExact == true)
    #expect(s.texts.first { $0.kind == .command }?.text == "rg health")
    #expect(CodexParser.transcript(path: path).map(\.kind) == [.user, .tool, .fileChange, .assistant])
}

@Test func pricingIsSpecificAndNeverGuessesUnknownModels() {
    let u = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
    let all: Double = 37.2 // 4 + 20 + 0.2 + 5 + 8
    #expect(abs((Pricing.cost(model: "claude-opus-5-5-20261001", usage: u) ?? 0) - all) < 1e-9)
    #expect(Pricing.cost(model: "claude-opus-5", usage: TokenUsage(input: 1_000_000)) == 5)      // not the 5.5 price
    #expect(Pricing.cost(model: "claude-fable-5-2", usage: TokenUsage(output: 1_000_000)) == 40)
    let codex: Double = 1.925
    #expect(abs((Pricing.cost(model: "gpt-5.3-codex", usage: TokenUsage(input: 1_000_000, cacheRead: 1_000_000)) ?? 0) - codex) < 1e-9)
    #expect(Pricing.cost(model: "some-new-model", usage: u) == nil)
    // A newer or different variant is unknown — never silently priced as its older sibling.
    for unknown in ["gpt-5-mini", "gpt-5.1-codex-mini", "gpt-5.6", "gpt-5.10", "claude-opus-5-6", "claude-fable-5-3", "claude-opus-5-5-fast"] {
        #expect(Pricing.price(for: unknown) == nil, "\(unknown) must be unpriced")
    }
    #expect(Pricing.price(for: "gpt-5.1-codex-max") != nil && Pricing.price(for: "claude-sonnet-4-5-20250929") != nil)
    #expect(Pricing.price(for: "claude-haiku-4-5-20251001") != nil && Pricing.price(for: "claude-opus-4-8[1m]") != nil)
}

@Test func indexerIsIncrementalAndSearchFindsMatches() throws {
    let home = try tmp(); defer { try? FileManager.default.removeItem(at: home) }
    let proj = home.appendingPathComponent(".claude/projects/-Users-t-dev-shop")
    try FileManager.default.createDirectory(at: proj.appendingPathComponent("sess-1/subagents"), withIntermediateDirectories: true)
    let path = proj.appendingPathComponent("sess-1.jsonl")
    try jsonl(claudeFixture()).write(to: path)
    try jsonl([assistant("s1", "rs1", blocks: [], usage: ["input_tokens": 1_000_000, "output_tokens": 0], model: "claude-haiku-4-5")])
        .write(to: proj.appendingPathComponent("sess-1/subagents/agent-a.jsonl"))

    let app = try AppDatabase(db: .inMemory())
    let indexer = SessionIndexer(home: home.path)
    #expect(indexer.index(into: app) == .init(found: 1, indexed: 1, unchanged: 0, failed: 0))
    #expect(indexer.index(into: app) == .init(found: 1, indexed: 0, unchanged: 1, failed: 0))

    let rows = try app.sessions()
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.title == "Fix port clash" && row.project == "shop" && row.messages == 3 && row.filesChanged == 1)
    // opus-5-5: 110 in, 55 out, 1000 read, 200 w5m, 100 w1h; haiku-4-5 subagent: 1M in = $1.
    let opusDollarsTimesMillion: Double = 110.0 * 4.0 + 55.0 * 20.0 + 1000.0 * 0.2 + 200.0 * 5.0 + 100.0 * 8.0
    let expected: Double = opusDollarsTimesMillion / 1_000_000.0 + 1.0
    // The subagent record has no stop reason (cut short), so the total is marked as a lower bound.
    #expect(abs(row.cost - expected) < 1e-9 && row.hasUnpriced)

    #expect(try app.search("already in").first?.snippet.contains("⟦already⟧") == true)
    #expect(Set(try app.search("lso").map(\.kind)) == [.command, .assistant]) // matches inside words
    #expect(try app.search("sof").isEmpty == false)                           // …including the middle of one
    #expect(try app.search("ls").isEmpty == false)                            // short words fall back to LIKE
    #expect(try app.search("lso", kind: .command).count == 1)
    #expect(try app.search("lsof", kind: .user).isEmpty)
    #expect(try app.search("server.js", kind: .file).count == 1)
    #expect(try app.search("\" OR 1=1 --").isEmpty)                     // hostile input is just text
    #expect(try app.sessions({ var f = SessionFilter(); f.onlyErrors = true; return f }()).isEmpty)
    #expect(try app.sessions({ var f = SessionFilter(); f.onlyFileChanges = true; return f }()).count == 1)
    #expect(try app.sessions({ var f = SessionFilter(); f.agent = .codex; return f }()).isEmpty)

    // Pin + note survive re-indexing after the transcript grows.
    try app.setPinned(true, path: row.path)
    try app.setNote("keep", path: row.path)
    var more = claudeFixture()
    more.append(["type": "user", "uuid": "u9", "timestamp": "2026-11-11T10:00:00.000Z", "message": ["role": "user", "content": "now add a zebra"]])
    try jsonl(more).write(to: path)
    #expect(indexer.index(into: app).indexed == 1)
    let again = try #require(try app.session(path: row.path))
    #expect(again.pinned && again.note == "keep" && again.messages == 4)
    #expect(try app.search("zebra").count == 1 && app.search("already in").count == 1) // old rows replaced, not duplicated
    #expect(SessionActions.resumeCommand(again) == "cd /Users/t/dev/shop && claude --resume sess-1")
    var hostile = again
    hostile.sessionID = "abc; touch /tmp/pwned"
    #expect(SessionActions.resumeCommand(hostile).hasSuffix("--resume 'abc; touch /tmp/pwned'"))

    // When the agent deletes a transcript, its text leaves the index too.
    try FileManager.default.removeItem(at: path)
    _ = indexer.index(into: app)
    #expect(try app.sessions().isEmpty && app.search("zebra").isEmpty && app.usageTotals(fromDay: "2000-01-01").cost == 0)
    #expect(AppDatabase.projectName(cwd: "/Users/t/dev/shop/.claude/worktrees/fix-1") == "shop")
}

@Test func exportMasksSecretsAndHonoursOptions() {
    let masked = SecretMasker.mask("""
    export ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz
    Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
    Authorization: Basic dXNlcjpodW50ZXIycGFzcw==
    x-api-key: zzz-very-private-value
    token ghp_abcdefghijklmnopqrstuvwxyz0123456789 and AKIAABCDEFGHIJKLMNOP
    postgres://admin:hunter2pass@db.local/app
    DB_PASSWORD='p@ss word 123'
    {"api_key": "live-value-9f8e7d", "password": "s3cret-thing"}
    curl -u alice:wonderland99 https://x.test/?key=AIzaSyA1234567890abcdefghijklmnopqrstuv
    stripe sk_live_abcdefghijklmnop1234 gitlab glpat-abcdefghijklmnopqrst
    ordinary text with port 3000 stays
    """)
    for secret in ["sk-ant-api03", "abcdefghijklmnopqrstuvwxyz012345", "dXNlcjpodW50", "zzz-very-private", "ghp_abc", "AKIAABCDEFGHIJKLMNOP",
                   "hunter2pass", "p@ss word", "live-value", "s3cret-thing", "wonderland99", "AIzaSy", "sk_live_abc", "glpat-abc"] {
        #expect(!masked.contains(secret), "\(secret) leaked")
    }
    #expect(masked.contains("ordinary text with port 3000 stays") && masked.contains("admin:") && masked.contains("@db.local"))

    // Ordinary code and prose that merely mention tokens or passwords must come through untouched.
    let code = """
    max_tokens: 16000,
    token: string;
    password: z.string().min(8),
    input_tokens: 123456
    let apiKey = settings.apiKey
    tokens = countTokens(text)
    func setPassword(_ password: String)
    risk-assessment-framework-for-users and task-management-system-rewrite-2026
    {"max_tokens": 4096, "input_tokens": 12}
    """
    #expect(SecretMasker.mask(code) == code)

    let row = SessionRow(sessionID: "s", agent: .claudeCode, path: "/x", cwd: nil, project: "shop", branch: nil, title: "T",
                         started: .now, ended: .now, messages: 2, models: [], cost: 0, hasUnpriced: false, tokens: 0,
                         hasErrors: false, filesChanged: 0, pinned: false, note: nil)
    let entries = [
        TranscriptEntry(line: 1, index: 0, kind: .user, title: "You", text: "use sk-ant-api03-abcdefghijklmnopqrstuvwxyz <b>", timestamp: nil, isError: false),
        TranscriptEntry(line: 2, index: 0, kind: .tool, title: "Bash", text: "ls", timestamp: nil, isError: false),
        TranscriptEntry(line: 3, index: 0, kind: .fileChange, title: "a.js", text: "+x", timestamp: nil, isError: false),
    ]
    let md = SessionExport.render(row, entries: entries, format: .markdown, options: .init(includeTools: false, includeDiffs: false))
    #expect(md.contains("## You") && !md.contains("sk-ant") && !md.contains("Bash") && !md.contains("a.js"))
    let raw = SessionExport.render(row, entries: entries, format: .markdown, options: .init(maskSecrets: false))
    #expect(raw.contains("sk-ant-api03") && raw.contains("```diff"))
    let tricky = [TranscriptEntry(line: 1, index: 0, kind: .toolResult, title: "Result", text: "a\n```\n<script>x</script>", timestamp: nil, isError: false)]
    #expect(SessionExport.render(row, entries: tricky, format: .markdown).contains("````\na\n```\n<script>x</script>\n````"))
    var twin = row
    twin.sessionID = "ffffffff-1"
    #expect(SessionExport.fileName(for: row, format: .markdown) != SessionExport.fileName(for: twin, format: .markdown))
    let html = SessionExport.render(row, entries: entries, format: .html)
    #expect(html.contains("&lt;b&gt;") && !html.contains("<b>"))
    let json = SessionExport.render(row, entries: entries, format: .json)
    #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
}

@Test func lineReaderHandlesLongAndPartialLines() throws {
    let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("f").path
    let long = String(repeating: "a", count: 3000)
    try Data("one\n\(long)\n\nhalf".utf8).write(to: URL(fileURLWithPath: path))
    var r = try #require(LineReader(path: path, chunk: 64))
    #expect(r.next() == Data("one".utf8) && r.next()?.count == 3000 && r.next() == Data())
    #expect(r.next() == nil)
    var r2 = try #require(LineReader(path: path, chunk: 64))
    var all: [Data] = []
    while let l = r2.next(includePartial: true) { all.append(l) }
    #expect(all.last == Data("half".utf8))
}

@Test func usageQueriesGroupAndRespectUnpricedModels() throws {
    let app = try AppDatabase(db: .inMemory())
    var a = ParsedSession(id: "a", agent: .claudeCode, path: "/a.jsonl", cwd: "/Users/t/dev/shop")
    a.startedAt = Date(timeIntervalSince1970: 1_800_000_000); a.endedAt = a.startedAt
    a.usage = [UsageBucket(model: "claude-opus-5-5", day: "2026-11-10", usage: TokenUsage(input: 1_000_000)),
               UsageBucket(model: "claude-opus-5-5", day: "2026-11-12", usage: TokenUsage(output: 1_000_000)),
               UsageBucket(model: "mystery-model", day: "2026-11-12", usage: TokenUsage(input: 500))]
    var b = ParsedSession(id: "b", agent: .codex, path: "/b.jsonl", cwd: "/Users/t/dev/api")
    b.startedAt = Date(timeIntervalSince1970: 1_800_000_500); b.endedAt = b.startedAt
    b.usage = [UsageBucket(model: "gpt-5.5", day: "2026-11-12", usage: TokenUsage(input: 1_000_000))]
    try app.upsert(a, fileSize: 1, fileMTime: 1)
    try app.upsert(b, fileSize: 1, fileMTime: 1)

    let all = try app.usageTotals(fromDay: "2026-11-01")
    #expect(all.cost == 4 + 20 + 5 && all.unpricedTokens == 500 && all.usage.input == 2_000_500)
    #expect(try app.usageTotals(fromDay: "2026-11-12").cost == 25)
    #expect(try app.usageTotals(fromDay: "2026-11-01", project: "api").cost == 5)
    #expect(try app.usage(by: .project, fromDay: "2026-11-01").map(\.key) == ["shop", "api"])
    #expect(try app.usage(by: .day, fromDay: "2026-11-01").map(\.key) == ["2026-11-10", "2026-11-12"])
    #expect(try app.usage(by: .model, fromDay: "2026-11-01").first { $0.key == "mystery-model" }?.unpricedTokens == 500)
    #expect(try app.topSessions(fromDay: "2026-11-01").map(\.sessionID) == ["a", "b"])
    // Within a later window only what was spent in that window counts: a = $20, b = $5.
    #expect(try app.topSessions(fromDay: "2026-11-12").map(\.cost) == [20, 5])
    #expect(try app.sessions().first { $0.sessionID == "a" }?.hasUnpriced == true)

    let march = ISO8601DateFormatter().date(from: "2026-03-17T12:00:00Z")!
    #expect(Budget(period: .month, limitUSD: 10).fromDay(now: march).hasSuffix("-03-01"))
}

@Test func forkedHistoryAndNestedSubagentsAreCountedOnce() throws {
    let home = try tmp(); defer { try? FileManager.default.removeItem(at: home) }
    let proj = home.appendingPathComponent(".claude/projects/-p")
    try FileManager.default.createDirectory(at: proj.appendingPathComponent("fork/subagents/workflows/wf_1"), withIntermediateDirectories: true)
    func line(_ id: String, session: String, out: Int) -> [String: Any] {
        ["type": "assistant", "sessionId": session, "timestamp": "2026-11-10T10:00:00.000Z", "requestId": "r-" + id,
         "message": ["id": id, "model": "claude-opus-5-5", "stop_reason": "end_turn", "content": [], "usage": ["input_tokens": 0, "output_tokens": out]]]
    }
    // "fork" starts with history copied from "orig" (still carrying orig's sessionId), then its own turn.
    try jsonl([line("m1", session: "orig", out: 1_000_000)]).write(to: proj.appendingPathComponent("orig.jsonl"))
    try jsonl([line("m1", session: "orig", out: 1_000_000), line("m2", session: "fork", out: 500_000)]).write(to: proj.appendingPathComponent("fork.jsonl"))
    try jsonl([line("w1", session: "fork", out: 250_000)]).write(to: proj.appendingPathComponent("fork/subagents/workflows/wf_1/agent-x.jsonl"))

    let app = try AppDatabase(db: .inMemory())
    #expect(SessionIndexer(home: home.path).index(into: app).indexed == 2)
    let cost = Dictionary(uniqueKeysWithValues: try app.sessions().map { ($0.sessionID, $0.cost) })
    #expect(cost["orig"] == 20)
    #expect(cost["fork"] == 15)                                   // 500k own + 250k workflow subagent, not the copied 1M
    #expect(try app.usageTotals(fromDay: "2000-01-01").cost == 35)
}

@Test func lineReaderIsLinearOnManyShortLines() throws {
    let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("big").path
    let line = String(repeating: "x", count: 199) + "\n"
    try Data(String(repeating: line, count: 100_000).utf8).write(to: URL(fileURLWithPath: path)) // 20 MB
    var r = try #require(LineReader(path: path))
    let start = Date()
    var n = 0
    while let l = r.next() { n += 1; if l.count != 199 { n = -1; break } }
    #expect(n == 100_000)
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func claudeSessionMapChecksTheProcessStartTime() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-sessmap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let agent = ProcessIdentity(pid: 4242, startSec: 1_700_000_000, startUsec: 0)
    try #"{"pid":4242,"sessionId":"abc","startedAt":1700000002000}"#.write(to: dir.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
    #expect(ClaudeSessionMap.sessionID(for: agent, directory: dir) == "abc")
    // Same pid, but the file belongs to a process that started an hour earlier: not ours.
    let recycled = ProcessIdentity(pid: 4242, startSec: 1_700_003_600, startUsec: 0)
    #expect(ClaudeSessionMap.sessionID(for: recycled, directory: dir) == nil)
}

@Test func haiku55LongPromptsUseTheHigherTierPerRequest() {
    let short = TokenUsage(input: 50_000, output: 1_000)
    let long = TokenUsage(input: 20_000, output: 1_000, cacheRead: 90_000)
    #expect(Pricing.billingModel("claude-haiku-5-5", short) == "claude-haiku-5-5")
    let tagged = Pricing.billingModel("claude-haiku-5-5", long)
    #expect(tagged != "claude-haiku-5-5")
    // 20k × $0.50 + 90k × $0.05 + 1k × $2.50 per million
    #expect(abs((Pricing.cost(model: tagged, usage: long) ?? 0) - 0.017) < 1e-9)
    #expect(Pricing.billingModel("claude-opus-5-5", long) == "claude-opus-5-5")
}

@Test func sessionCopiesMirrorOriginalsAndStayPrivate() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-arch-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: base) }
    let home = "\(base)/home", original = "\(home)/.claude/projects/shop/abc.jsonl"
    try FileManager.default.createDirectory(atPath: (original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try "{\"type\":\"user\"}\n".write(toFile: original, atomically: true, encoding: .utf8)
    let archive = SessionArchive(root: "\(base)/copies", home: home)
    #expect(archive.keep(original))
    let copy = try #require(archive.existingCopy(of: original))
    #expect(copy == "\(base)/copies/.claude/projects/shop/abc.jsonl")
    let perms = try FileManager.default.attributesOfItem(atPath: copy)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    // The original is deleted by the agent: the copy remains.
    try FileManager.default.removeItem(atPath: original)
    #expect(archive.existingCopy(of: original) != nil)
    #expect(archive.copyPath(for: "/etc/passwd") == nil)
}
