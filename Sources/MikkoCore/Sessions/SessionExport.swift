import Foundation

/// S-5: hides credentials before a transcript leaves the app.
public enum SecretMasker {
    /// (pattern, replacement). Value-shaped rules only: a word like "token" or "password" in
    /// ordinary code or prose is never enough on its own to mask what follows.
    static let rules: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "•••"),
        (#"\bsk-ant-[A-Za-z0-9_\-]{16,}"#, "•••"),
        (#"\bsk-(?:proj-)?[A-Za-z0-9_]{20,}"#, "•••"),
        (#"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#, "•••"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "•••"),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "•••"),
        (#"\bglpat-[A-Za-z0-9_\-]{16,}"#, "•••"),
        (#"\bnpm_[A-Za-z0-9]{30,}"#, "•••"),
        (#"\bAIza[0-9A-Za-z_\-]{30,}"#, "•••"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "•••"),
        (#"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#, "•••"),
        (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, "•••"),
        (#"(?i)(authorization:\s*(?:bearer|basic)\s+)[A-Za-z0-9_\-\.=+/]{8,}"#, "$1•••"),
        (#"(?i)\b(bearer\s+)[A-Za-z0-9_\-\.=]{20,}"#, "$1•••"),
        (#"(?i)(x-api-key:\s*)\S{8,}"#, "$1•••"),
        // Environment style: UPPER_CASE name, "=", then a quoted value (spaces allowed) or a bare one.
        (#"\b([A-Z][A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY)[A-Z0-9_]*=)(?:"[^"\n]*"|'[^'\n]*'|[^\s"']+)"#, "$1•••"),
        // JSON / YAML style: a quoted key and a quoted string value.
        (#"(?i)("[\w\-]*(?:secret|password|passwd|api[_\-]?key|access[_\-]?token|auth[_\-]?token|private[_\-]?key)[\w\-]*"\s*:\s*")[^"\n]{4,}(")"#, "$1•••$2"),
        (#"(?i)(://[^/\s:@]+:)[^@\s/]{3,}(@)"#, "$1•••$2"),
        (#"(?i)(\bcurl\b[^\n]*?\s-u\s+[^\s:]+:)\S+"#, "$1•••"),
        (#"(?i)([?&](?:key|token|access_token|api_key|apikey|secret)=)[^&\s"']{8,}"#, "$1•••"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func mask(_ text: String) -> String {
        var s = text
        for (re, template) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }
}

public enum SessionExport {
    public enum Format: String, Sendable, CaseIterable { case markdown, json, html
        public var fileExtension: String { self == .markdown ? "md" : rawValue }
    }

    public struct Options: Sendable {
        public var includeTools = true
        public var includeDiffs = true
        public var maskSecrets = true
        public init(includeTools: Bool = true, includeDiffs: Bool = true, maskSecrets: Bool = true) {
            self.includeTools = includeTools; self.includeDiffs = includeDiffs; self.maskSecrets = maskSecrets
        }
    }

    static func filtered(_ entries: [TranscriptEntry], _ o: Options) -> [TranscriptEntry] {
        entries.compactMap { e in
            if !o.includeTools, e.kind == .tool || e.kind == .toolResult { return nil }
            if !o.includeDiffs, e.kind == .fileChange { return nil }
            guard o.maskSecrets else { return e }
            var e = e
            e.text = SecretMasker.mask(e.text)
            e.title = SecretMasker.mask(e.title)
            return e
        }
    }

    /// A code fence longer than any run of backticks inside, so the content cannot close it early.
    static func fenced(_ text: String, language: String = "") -> String {
        var longest = 0, run = 0
        for ch in text { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    /// A file name for an export that never collides: day, title, short session id.
    public static func fileName(for session: SessionRow, format: Format) -> String {
        let safe = String(session.title.prefix(60).map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" })
            .trimmingCharacters(in: .whitespaces)
        let day = Timestamps.day(session.started)
        return "\(day) \(safe.isEmpty ? "session" : safe) \(session.sessionID.prefix(8)).\(format.fileExtension)"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func render(_ session: SessionRow, entries: [TranscriptEntry], format: Format, options: Options = .init()) -> String {
        let items = filtered(entries, options)
        let title = options.maskSecrets ? SecretMasker.mask(session.title) : session.title
        let date = session.started.formatted(date: .abbreviated, time: .shortened)
        let meta = "\(session.agent.displayName) · \(session.project) · \(date) · \(session.messages) messages"
        switch format {
        case .json:
            let obj: [String: Any] = [
                "id": session.sessionID, "agent": session.agent.rawValue, "project": session.project, "title": title,
                "started": ISO8601DateFormatter().string(from: session.started), "models": session.models,
                "apiEquivalentCostUSD": session.cost,
                "entries": items.map { e in
                    var o: [String: Any] = ["kind": e.kind.rawValue, "title": e.title, "text": e.text, "isError": e.isError]
                    if let t = e.timestamp { o["timestamp"] = ISO8601DateFormatter().string(from: t) }
                    return o
                },
            ]
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        case .markdown:
            var out = "# \(title)\n\n\(meta)\n"
            for e in items {
                switch e.kind {
                case .user: out += "\n## You\n\n\(e.text)\n"
                case .assistant: out += "\n## \(e.title)\n\n\(e.text)\n"
                case .tool: out += "\n**\(e.title)**\n\n\(fenced(e.text))\n"
                case .toolResult: out += "\n<details><summary>\(e.isError ? "Error" : "Result")</summary>\n\n\(fenced(e.text))\n\n</details>\n"
                case .fileChange: out += "\n**Changed `\(e.title)`**\n\n\(fenced(e.text, language: "diff"))\n"
                case .note: out += "\n> \(e.title) \(e.text)\n"
                }
            }
            return out
        case .html:
            var out = """
            <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
            <style>body{font:15px/1.5 -apple-system,sans-serif;max-width:860px;margin:2em auto;padding:0 1em}
            .user{background:#eef4ff;padding:.6em 1em;border-radius:8px}.meta{color:#666}
            pre{background:#f5f5f5;padding:.8em;border-radius:6px;overflow:auto;font-size:13px}
            .error pre{background:#fff0f0}h3{margin:1.4em 0 .3em;font-size:14px;color:#555}
            @media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee}.user{background:#243248}pre{background:#2a2a2c}.error pre{background:#40201f}}
            </style></head><body><h1>\(escape(title))</h1><p class="meta">\(escape(meta))</p>
            """
            for e in items {
                switch e.kind {
                case .user: out += "<h3>You</h3><div class=\"user\">\(escape(e.text).replacingOccurrences(of: "\n", with: "<br>"))</div>\n"
                case .assistant: out += "<h3>\(escape(e.title))</h3><div>\(escape(e.text).replacingOccurrences(of: "\n", with: "<br>"))</div>\n"
                case .tool: out += "<h3>\(escape(e.title))</h3><pre>\(escape(e.text))</pre>\n"
                case .toolResult: out += "<details class=\"\(e.isError ? "error" : "")\"><summary>\(e.isError ? "Error" : "Result")</summary><pre>\(escape(e.text))</pre></details>\n"
                case .fileChange: out += "<h3>Changed \(escape(e.title))</h3><pre>\(escape(e.text))</pre>\n"
                case .note: out += "<p class=\"meta\">\(escape(e.title)) \(escape(e.text))</p>\n"
                }
            }
            return out + "</body></html>\n"
        }
    }
}
