import Foundation

/// Parses Codex rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
public enum CodexParser {
    static func text(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let t = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return t.isEmpty ? nil : t
    }

    static func command(fromArguments args: Any?) -> String? {
        guard let s = args as? String, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let c = o["command"] as? [String] { return c.joined(separator: " ") }
        return (o["command"] as? String) ?? (o["cmd"] as? String)
    }

    public static func parse(path: String) -> ParsedSession? {
        guard var reader = LineReader(path: path) else { return nil }
        defer { reader.close() }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var s = ParsedSession(id: String(name.suffix(36)), agent: .codex, path: path)
        var model = "unknown"
        var models = Set<String>()
        var buckets: [String: UsageBucket] = [:]
        var files = Set<String>()
        var latestLimits: [String: RateLimitWindow] = [:]
        var previousTotal: [String: Int64]?
        var lineNo = 0

        while let line = reader.next() {
            lineNo += 1
            guard line.count <= ClaudeParser.maxLineBytes,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String, let payload = obj["payload"] as? [String: Any] else { continue }
            let ts = Timestamps.parse(obj["timestamp"])
            if let ts {
                if s.startedAt == nil || ts < s.startedAt! { s.startedAt = ts }
                if s.endedAt == nil || ts > s.endedAt! { s.endedAt = ts }
            }
            switch type {
            case "session_meta":
                if let id = payload["id"] as? String { s.id = id }
                s.cwd = payload["cwd"] as? String ?? s.cwd
                s.gitBranch = (payload["git"] as? [String: Any])?["branch"] as? String ?? s.gitBranch
            case "turn_context":
                if let m = payload["model"] as? String { model = m; models.insert(m) }
                s.cwd = payload["cwd"] as? String ?? s.cwd
            case "event_msg":
                switch payload["type"] as? String {
                case "user_message":
                    guard let t = payload["message"] as? String, !t.isEmpty else { break }
                    s.messageCount += 1
                    if s.firstPrompt == nil { s.firstPrompt = ClaudeParser.clip(t) }
                    s.texts.append(SearchableText(kind: .user, line: lineNo, text: ClaudeParser.clip(t)))
                case "agent_message":
                    guard let t = payload["message"] as? String, !t.isEmpty else { break }
                    s.messageCount += 1
                    s.texts.append(SearchableText(kind: .assistant, line: lineNo, text: ClaudeParser.clip(t)))
                case "token_count":
                    if let info = payload["info"] as? [String: Any] {
                        // Codex repeats this event without new usage. Only growth of the running total
                        // counts; the per-turn figure is used just for the very first event.
                        let keys = ["input_tokens", "cached_input_tokens", "output_tokens"]
                        func numbers(_ any: Any?) -> [String: Int64]? {
                            guard let d = any as? [String: Any] else { return nil }
                            return Dictionary(uniqueKeysWithValues: keys.map { ($0, (d[$0] as? NSNumber)?.int64Value ?? 0) })
                        }
                        var delta: [String: Int64]?
                        if let total = numbers(info["total_token_usage"]) {
                            if let prev = previousTotal {
                                delta = Dictionary(uniqueKeysWithValues: keys.map { ($0, max(total[$0]! - prev[$0]!, 0)) })
                            } else {
                                delta = numbers(info["last_token_usage"]) ?? total
                            }
                            previousTotal = total
                        } else {
                            delta = numbers(info["last_token_usage"])
                        }
                        if let d = delta, d.values.contains(where: { $0 > 0 }) {
                            // cached_input_tokens is a subset of input_tokens.
                            let cached = d["cached_input_tokens"]!
                            let u = TokenUsage(input: max(d["input_tokens"]! - cached, 0), output: d["output_tokens"]!, cacheRead: cached)
                            let day = Timestamps.day(ts ?? .now)
                            buckets["\(model)|\(day)", default: UsageBucket(model: model, day: day, usage: TokenUsage())].usage += u
                        }
                    }
                    // An observation without a time cannot be ranked against others, so it is ignored.
                    if let limits = payload["rate_limits"] as? [String: Any], let ts {
                        for (key, label) in [("primary", "5h"), ("secondary", "weekly")] {
                            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                            let minutes = (w["window_minutes"] as? NSNumber)?.intValue
                            let window = minutes.map { $0 <= 600 ? "5h" : "weekly" } ?? label
                            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                            latestLimits[window] = RateLimitWindow(provider: "Codex", window: window, usedPercent: used,
                                                                   resetsAt: resets, observedAt: ts, isExact: true)
                        }
                    }
                case "patch_apply_end":
                    for file in ((payload["changes"] as? [String: Any]) ?? [:]).keys where files.insert(file).inserted {
                        s.texts.append(SearchableText(kind: .file, line: lineNo, text: file))
                    }
                case "turn_aborted", "error", "stream_error": s.hasErrors = true
                default: break
                }
            case "response_item":
                if (payload["type"] as? String) == "function_call", let cmd = command(fromArguments: payload["arguments"]) {
                    s.texts.append(SearchableText(kind: .command, line: lineNo, text: ClaudeParser.clip(cmd)))
                }
            default: break
            }
        }
        s.usage = buckets.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
        s.models = models.sorted()
        s.filesChanged = files.sorted()
        s.rateLimits = Array(latestLimits.values)
        return s.startedAt == nil ? nil : s
    }

    public static func transcript(path: String) -> [TranscriptEntry] {
        guard var reader = LineReader(path: path) else { return [] }
        defer { reader.close() }
        var out: [TranscriptEntry] = []
        var lineNo = 0
        while let line = reader.next() {
            lineNo += 1
            guard line.count <= ClaudeParser.maxLineBytes,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String, let payload = obj["payload"] as? [String: Any] else { continue }
            let ts = Timestamps.parse(obj["timestamp"])
            func add(_ kind: TranscriptEntry.Kind, _ title: String, _ text: String, error: Bool = false) {
                out.append(TranscriptEntry(line: lineNo, index: 0, kind: kind, title: title, text: text, timestamp: ts, isError: error))
            }
            let ptype = payload["type"] as? String
            if type == "event_msg" {
                switch ptype {
                case "user_message": if let t = payload["message"] as? String { add(.user, "You", t) }
                case "agent_message": if let t = payload["message"] as? String { add(.assistant, "Codex", t) }
                case "patch_apply_end":
                    for (file, change) in (payload["changes"] as? [String: Any]) ?? [:] {
                        add(.fileChange, file, String((((change as? [String: Any])?["unified_diff"] as? String) ?? "").prefix(40_000)))
                    }
                case "turn_aborted": add(.note, "Turn aborted", "", error: true)
                default: break
                }
            } else if type == "response_item" {
                if ptype == "function_call" {
                    add(.tool, payload["name"] as? String ?? "Tool", command(fromArguments: payload["arguments"]) ?? "")
                } else if ptype == "function_call_output" {
                    let text = (payload["output"] as? String) ?? text(payload["output"]) ?? ""
                    add(.toolResult, "Result", String(text.prefix(20_000)))
                }
            }
        }
        return out
    }
}
