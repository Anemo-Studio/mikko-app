import Foundation

/// Parses Claude Code transcripts (`~/.claude/projects/<slug>/<sessionId>.jsonl`).
/// Lenient by design: unknown line types and malformed lines are skipped, never fatal.
public enum ClaudeParser {
    static let skipMarkers: [Data] = ["\"type\":\"api-request", "\"type\":\"file-history-", "\"type\":\"queue-operation\""].map { Data($0.utf8) }
    static let maxLineBytes = 8 << 20
    static let maxTextLength = 6000

    static func object(_ line: Data) -> [String: Any]? {
        guard line.count > 2, line.count <= maxLineBytes else { return nil }
        // Cheap pre-filter: the bulky line types are never needed.
        let head = line.prefix(4096)
        if skipMarkers.contains(where: { head.range(of: $0) != nil }) { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func clip(_ s: String) -> String { s.count > maxTextLength ? String(s.prefix(maxTextLength)) : s }

    /// Plain text typed by the person: string content or `text` blocks, never tool results.
    static func userText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static let noiseTags = ["<command-", "<local-command", "<system-reminder", "<task-notification", "<user-prompt-submit-hook",
                            "<bash-", "<ide_", "<agent-message", "<tools-used", "<session-", "<teammate-message"]

    /// Harness-injected text, not something the person typed. Pasted HTML or JSX starting with "<" is kept.
    static func isNoise(_ text: String) -> Bool {
        noiseTags.contains(where: text.hasPrefix) || text.hasPrefix("Caveat:") || text.hasPrefix("[Request interrupted")
    }

    public static func parse(path: String, subagentPaths: [String] = []) -> ParsedSession? {
        guard var reader = LineReader(path: path) else { return nil }
        defer { reader.close() }
        var s = ParsedSession(id: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, agent: .claudeCode, path: path)
        var usage = UsageCollector()
        var files = Set<String>()
        var models = Set<String>()
        var lineNo = 0

        while let line = reader.next() {
            lineNo += 1
            guard let obj = object(line), let type = obj["type"] as? String else { continue }
            switch type {
            case "custom-title": s.title = (obj["customTitle"] as? String) ?? s.title
            case "ai-title": if s.title == nil { s.title = obj["aiTitle"] as? String }
            case "user", "assistant":
                let ts = Timestamps.parse(obj["timestamp"])
                if let ts {
                    if s.startedAt == nil || ts < s.startedAt! { s.startedAt = ts }
                    if s.endedAt == nil || ts > s.endedAt! { s.endedAt = ts }
                }
                if s.cwd == nil { s.cwd = obj["cwd"] as? String }
                if let b = obj["gitBranch"] as? String, !b.isEmpty { s.gitBranch = b }
                guard let message = obj["message"] as? [String: Any] else { continue }
                if type == "user" {
                    if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { continue }
                    guard let text = userText(message["content"]), !text.isEmpty, !isNoise(text) else { continue }
                    s.messageCount += 1
                    if s.firstPrompt == nil { s.firstPrompt = clip(text) }
                    s.texts.append(SearchableText(kind: .user, line: lineNo, text: clip(text)))
                } else {
                    if obj["isApiErrorMessage"] as? Bool == true { s.hasErrors = true }
                    let model = message["model"] as? String ?? ""
                    if !model.isEmpty, model != "<synthetic>" { models.insert(model) }
                    // A forked or resumed session copies the earlier session's lines in, each still carrying
                    // the original sessionId. Their usage belongs to that session, not this one.
                    if (obj["sessionId"] as? String).map({ $0 == s.id }) ?? true {
                        usage.add(message: message, requestID: obj["requestId"] as? String, model: model, at: ts)
                    }
                    var spoke = false
                    for block in (message["content"] as? [[String: Any]]) ?? [] {
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String, !t.isEmpty {
                                spoke = true
                                s.texts.append(SearchableText(kind: .assistant, line: lineNo, text: clip(t)))
                            }
                        case "tool_use":
                            let input = block["input"] as? [String: Any] ?? [:]
                            if let cmd = input["command"] as? String {
                                s.texts.append(SearchableText(kind: .command, line: lineNo, text: clip(cmd)))
                            }
                            if let file = (input["file_path"] as? String) ?? (input["notebook_path"] as? String),
                               ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(block["name"] as? String ?? "") {
                                if files.insert(file).inserted { s.texts.append(SearchableText(kind: .file, line: lineNo, text: file)) }
                            }
                        default: break
                        }
                    }
                    if spoke { s.messageCount += 1 }
                }
            default: continue
            }
        }
        // Subagents record their own usage in separate files; it belongs to the parent session.
        for sub in subagentPaths { collectUsage(path: sub, sessionID: s.id, into: &usage, models: &models) }
        s.usage = usage.buckets()
        s.usageIncomplete = usage.hasTruncatedRecords
        s.models = models.sorted()
        s.filesChanged = files.sorted()
        return s.startedAt == nil && s.texts.isEmpty ? nil : s
    }

    static func collectUsage(path: String, sessionID: String, into usage: inout UsageCollector, models: inout Set<String>) {
        guard var reader = LineReader(path: path) else { return }
        defer { reader.close() }
        while let line = reader.next() {
            guard let obj = object(line), (obj["type"] as? String) == "assistant", let message = obj["message"] as? [String: Any] else { continue }
            guard (obj["sessionId"] as? String).map({ $0 == sessionID }) ?? true else { continue }
            let model = message["model"] as? String ?? ""
            if !model.isEmpty, model != "<synthetic>" { models.insert(model) }
            usage.add(message: message, requestID: obj["requestId"] as? String, model: model, at: Timestamps.parse(obj["timestamp"]), isSubagent: true)
        }
    }

    /// One API response is written as several lines (one per content block) that repeat the
    /// same usage. Counting each would overstate cost several-fold, so the last one wins.
    struct UsageCollector {
        private var byRequest: [String: (model: String, day: String, usage: TokenUsage)] = [:]
        private var truncated = Set<String>()
        private var anonymous = 0

        /// Some Claude Code versions end a subagent's record before the final token count is written
        /// (no stop reason, placeholder output tokens). Those requests are under-counted.
        var hasTruncatedRecords: Bool { !truncated.isEmpty }

        mutating func add(message: [String: Any], requestID: String?, model: String, at: Date?, isSubagent: Bool = false) {
            guard model != "<synthetic>", !model.isEmpty, let u = message["usage"] as? [String: Any] else { return }
            func n(_ k: String) -> Int64 { (u[k] as? NSNumber)?.int64Value ?? 0 }
            let creation = u["cache_creation"] as? [String: Any]
            let w5 = (creation?["ephemeral_5m_input_tokens"] as? NSNumber)?.int64Value
            let w1 = (creation?["ephemeral_1h_input_tokens"] as? NSNumber)?.int64Value
            let usage = TokenUsage(input: n("input_tokens"), output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"),
                                   cacheWrite5m: w5 ?? (w1 == nil ? n("cache_creation_input_tokens") : 0), cacheWrite1h: w1 ?? 0)
            var key = "\(message["id"] as? String ?? "")|\(requestID ?? "")"
            if key == "|" { anonymous += 1; key = "anon-\(anonymous)" }
            byRequest[key] = (model, Timestamps.day(at ?? .now), usage)
            if isSubagent {
                if message["stop_reason"] is String { truncated.remove(key) } else { truncated.insert(key) }
            }
        }

        func buckets() -> [UsageBucket] {
            var out: [String: UsageBucket] = [:]
            for v in byRequest.values {
                let k = "\(v.model)|\(v.day)"
                out[k, default: UsageBucket(model: v.model, day: v.day, usage: TokenUsage())].usage += v.usage
            }
            return out.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
        }
    }

    // MARK: Timeline (S-2)

    public static func transcript(path: String) -> [TranscriptEntry] {
        guard var reader = LineReader(path: path) else { return [] }
        defer { reader.close() }
        var out: [TranscriptEntry] = []
        var lineNo = 0
        while let line = reader.next(includePartial: false) {
            lineNo += 1
            guard let obj = object(line), let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            let ts = Timestamps.parse(obj["timestamp"])
            var idx = 0
            func add(_ kind: TranscriptEntry.Kind, _ title: String, _ text: String, error: Bool = false) {
                out.append(TranscriptEntry(line: lineNo, index: idx, kind: kind, title: title, text: text, timestamp: ts, isError: error))
                idx += 1
            }
            if type == "user" {
                if obj["isMeta"] as? Bool == true { continue }
                if obj["isCompactSummary"] as? Bool == true { add(.note, "Conversation compacted", ""); continue }
                if let text = userText(message["content"]), !text.isEmpty, !isNoise(text) { add(.user, "You", text) }
                for block in (message["content"] as? [[String: Any]]) ?? [] where (block["type"] as? String) == "tool_result" {
                    let text: String = (block["content"] as? String)
                        ?? ((block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "")
                    add(.toolResult, "Result", String(text.prefix(20_000)), error: block["is_error"] as? Bool == true)
                }
                if let r = obj["toolUseResult"] as? [String: Any], let file = r["filePath"] as? String,
                   let patch = r["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
                    let diff = patch.map { h -> String in
                        let header = "@@ -\(h["oldStart"] ?? 0),\(h["oldLines"] ?? 0) +\(h["newStart"] ?? 0),\(h["newLines"] ?? 0) @@"
                        return ([header] + ((h["lines"] as? [String]) ?? [])).joined(separator: "\n")
                    }.joined(separator: "\n")
                    add(.fileChange, file, String(diff.prefix(40_000)))
                }
            } else {
                for block in (message["content"] as? [[String: Any]]) ?? [] {
                    switch block["type"] as? String {
                    case "text": if let t = block["text"] as? String, !t.isEmpty { add(.assistant, "Claude", t) }
                    case "tool_use":
                        let input = block["input"] as? [String: Any] ?? [:]
                        let name = block["name"] as? String ?? "Tool"
                        let summary = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["pattern"] as? String)
                            ?? (input["description"] as? String) ?? (input["url"] as? String) ?? ""
                        add(.tool, name, String(summary.prefix(4000)))
                    default: break
                    }
                }
                if obj["isApiErrorMessage"] as? Bool == true { add(.note, "API error", (obj["error"] as? String) ?? "", error: true) }
            }
        }
        return out
    }
}
