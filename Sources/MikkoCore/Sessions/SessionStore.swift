import Foundation

public struct SessionRow: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var sessionID: String
    public var agent: AgentTool
    public var path: String
    public var cwd: String?
    public var project: String
    public var branch: String?
    public var title: String
    public var started: Date
    public var ended: Date
    public var messages: Int
    public var models: [String]
    public var cost: Double
    /// The cost is a lower bound: a model has no known price, or the agent cut some usage records short.
    public var hasUnpriced: Bool
    public var tokens: Int64
    public var hasErrors: Bool
    public var filesChanged: Int
    public var pinned: Bool
    public var note: String?

    public var duration: TimeInterval { max(ended.timeIntervalSince(started), 0) }
    public var originalExists: Bool { FileManager.default.fileExists(atPath: path) }
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public var id: String { "\(path)#\(line)#\(kind.rawValue)" }
    public var path: String
    public var kind: SearchKind
    public var line: Int
    /// Matching text; the match is wrapped in ⟦ ⟧.
    public var snippet: String
}

public struct SessionFilter: Sendable {
    public var agent: AgentTool?
    public var project: String?
    public var from: Date?
    public var to: Date?
    public var onlyErrors = false
    public var onlyFileChanges = false
    public init() {}
}

extension AppDatabase {
    static let sessionMigration = """
    CREATE TABLE sessions(
        path TEXT PRIMARY KEY, id TEXT NOT NULL, agent TEXT NOT NULL, cwd TEXT, project TEXT NOT NULL, branch TEXT,
        title TEXT NOT NULL, started REAL NOT NULL, ended REAL NOT NULL, messages INTEGER NOT NULL, models TEXT NOT NULL,
        cost REAL NOT NULL, unpriced INTEGER NOT NULL, tokens INTEGER NOT NULL, has_errors INTEGER NOT NULL,
        files_changed INTEGER NOT NULL, file_size INTEGER NOT NULL, file_mtime REAL NOT NULL,
        text_first INTEGER, text_last INTEGER, pinned INTEGER NOT NULL DEFAULT 0, note TEXT);
    CREATE INDEX sessions_started ON sessions(started);
    CREATE TABLE session_usage(
        path TEXT NOT NULL, agent TEXT NOT NULL, project TEXT NOT NULL, model TEXT NOT NULL, day TEXT NOT NULL,
        input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_w5 INTEGER NOT NULL,
        cache_w1 INTEGER NOT NULL, cost REAL);
    CREATE INDEX session_usage_path ON session_usage(path);
    CREATE INDEX session_usage_day ON session_usage(day);
    CREATE VIRTUAL TABLE session_text USING fts5(text, path UNINDEXED, kind UNINDEXED, line UNINDEXED, tokenize='unicode61');
    CREATE TABLE rate_limits(provider TEXT NOT NULL, window TEXT NOT NULL, used REAL NOT NULL, resets REAL,
        observed REAL NOT NULL, exact INTEGER NOT NULL, PRIMARY KEY(provider, window));
    """

    /// "…/shop/.claude/worktrees/x" belongs to project "shop".
    public static func projectName(cwd: String?) -> String {
        guard var cwd, !cwd.isEmpty else { return "Unknown" }
        if let r = cwd.range(of: "/.claude/worktrees/") { cwd = String(cwd[..<r.lowerBound]) }
        return (cwd as NSString).lastPathComponent
    }

    /// (size, mtime) recorded for a transcript, to skip unchanged files on the next index run.
    public func indexedState() throws -> [String: (size: Int64, mtime: Double)] {
        var out: [String: (Int64, Double)] = [:]
        for r in try db.query("SELECT path, file_size, file_mtime FROM sessions") {
            if let p = r[0].text { out[p] = (r[1].int ?? 0, r[2].double ?? 0) }
        }
        return out
    }

    public func upsert(_ s: ParsedSession, fileSize: Int64, fileMTime: Double) throws {
        let project = Self.projectName(cwd: s.cwd)
        var cost = 0.0, unpriced = false, tokens: Int64 = 0
        for b in s.usage {
            tokens += b.usage.total
            if let c = Pricing.cost(model: b.model, usage: b.usage) { cost += c } else if b.usage.total > 0 { unpriced = true }
        }
        if s.usageIncomplete { unpriced = true } // the figure is a lower bound either way
        let started = s.startedAt ?? s.endedAt ?? Date(timeIntervalSince1970: fileMTime)
        try db.transaction {
            // Keep what the person added (pin, note) across re-indexing.
            let old = try db.query("SELECT text_first, text_last, pinned, note FROM sessions WHERE path = ?", [.text(s.path)]).first
            if let first = old?[0].int, let last = old?[1].int {
                try db.query("DELETE FROM session_text WHERE rowid BETWEEN ? AND ?", [.int(first), .int(last)])
            }
            try db.query("DELETE FROM session_usage WHERE path = ?", [.text(s.path)])

            var firstRow: Int64?, lastRow: Int64?
            for t in s.texts {
                try db.query("INSERT INTO session_text(text, path, kind, line) VALUES (?,?,?,?)",
                             [.text(t.text), .text(s.path), .text(t.kind.rawValue), .int(Int64(t.line))])
                let rowid = try db.query("SELECT last_insert_rowid()").first?.first?.int
                if firstRow == nil { firstRow = rowid }
                lastRow = rowid
            }
            for b in s.usage {
                try db.query("INSERT INTO session_usage VALUES (?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(s.path), .text(s.agent.rawValue), .text(project), .text(b.model), .text(b.day),
                    .int(b.usage.input), .int(b.usage.output), .int(b.usage.cacheRead), .int(b.usage.cacheWrite5m),
                    .int(b.usage.cacheWrite1h), Pricing.cost(model: b.model, usage: b.usage).map(SQLValue.double) ?? .null,
                ])
            }
            try db.query("""
                INSERT OR REPLACE INTO sessions(path, id, agent, cwd, project, branch, title, started, ended, messages, models, cost,
                    unpriced, tokens, has_errors, files_changed, file_size, file_mtime, text_first, text_last, pinned, note)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                .text(s.path), .text(s.id), .text(s.agent.rawValue), s.cwd.map(SQLValue.text) ?? .null, .text(project),
                s.gitBranch.map(SQLValue.text) ?? .null, .text(s.displayTitle), .double(started.timeIntervalSince1970),
                .double((s.endedAt ?? started).timeIntervalSince1970), .int(Int64(s.messageCount)),
                .text(s.models.joined(separator: ",")), .double(cost), .int(unpriced ? 1 : 0), .int(tokens),
                .int(s.hasErrors ? 1 : 0), .int(Int64(s.filesChanged.count)), .int(fileSize), .double(fileMTime),
                firstRow.map(SQLValue.int) ?? .null, lastRow.map(SQLValue.int) ?? .null,
                .int(old?[2].int ?? 0), old?[3] ?? .null,
            ])
            for l in s.rateLimits {
                // Keep only the newest observation per provider and window.
                try db.query("""
                    INSERT INTO rate_limits(provider, window, used, resets, observed, exact) VALUES (?,?,?,?,?,?)
                    ON CONFLICT(provider, window) DO UPDATE SET used = excluded.used, resets = excluded.resets,
                        observed = excluded.observed, exact = excluded.exact WHERE excluded.observed > rate_limits.observed
                    """, [.text(l.provider), .text(l.window), .double(l.usedPercent),
                          l.resetsAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                          .double(l.observedAt.timeIntervalSince1970), .int(l.isExact ? 1 : 0)])
            }
        }
    }

    static let sessionColumns = "id, agent, path, cwd, project, branch, title, started, ended, messages, models, cost, unpriced, tokens, has_errors, files_changed, pinned, note"

    static func sessionRow(_ r: [SQLValue]) -> SessionRow {
        SessionRow(sessionID: r[0].text ?? "", agent: AgentTool(rawValue: r[1].text ?? "") ?? .claudeCode, path: r[2].text ?? "",
                   cwd: r[3].text, project: r[4].text ?? "", branch: r[5].text, title: r[6].text ?? "",
                   started: Date(timeIntervalSince1970: r[7].double ?? 0), ended: Date(timeIntervalSince1970: r[8].double ?? 0),
                   messages: Int(r[9].int ?? 0), models: (r[10].text ?? "").split(separator: ",").map(String.init),
                   cost: r[11].double ?? 0, hasUnpriced: r[12].int == 1, tokens: r[13].int ?? 0, hasErrors: r[14].int == 1,
                   filesChanged: Int(r[15].int ?? 0), pinned: r[16].int == 1, note: r[17].text)
    }

    public func sessions(_ f: SessionFilter = .init(), limit: Int = 20_000) throws -> [SessionRow] {
        var clauses: [String] = [], params: [SQLValue] = []
        if let a = f.agent { clauses.append("agent = ?"); params.append(.text(a.rawValue)) }
        if let p = f.project { clauses.append("project = ?"); params.append(.text(p)) }
        if let d = f.from { clauses.append("ended >= ?"); params.append(.double(d.timeIntervalSince1970)) }
        if let d = f.to { clauses.append("started <= ?"); params.append(.double(d.timeIntervalSince1970)) }
        if f.onlyErrors { clauses.append("has_errors = 1") }
        if f.onlyFileChanges { clauses.append("files_changed > 0") }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        params.append(.int(Int64(limit)))
        return try db.query("SELECT \(Self.sessionColumns) FROM sessions \(whereSQL) ORDER BY pinned DESC, started DESC LIMIT ?", params)
            .map(Self.sessionRow)
    }

    public func session(path: String) throws -> SessionRow? {
        try db.query("SELECT \(Self.sessionColumns) FROM sessions WHERE path = ?", [.text(path)]).first.map(Self.sessionRow)
    }

    public func session(id: String) throws -> SessionRow? {
        try db.query("SELECT \(Self.sessionColumns) FROM sessions WHERE id = ? ORDER BY started DESC LIMIT 1", [.text(id)]).first.map(Self.sessionRow)
    }

    /// Removes a session and all its indexed text and usage.
    public func removeSession(path: String) throws {
        try db.transaction {
            if let r = try db.query("SELECT text_first, text_last FROM sessions WHERE path = ?", [.text(path)]).first,
               let first = r[0].int, let last = r[1].int {
                try db.query("DELETE FROM session_text WHERE rowid BETWEEN ? AND ?", [.int(first), .int(last)])
            }
            try db.query("DELETE FROM session_usage WHERE path = ?", [.text(path)])
            try db.query("DELETE FROM sessions WHERE path = ?", [.text(path)])
        }
    }

    public func projects() throws -> [String] {
        try db.query("SELECT DISTINCT project FROM sessions ORDER BY project COLLATE NOCASE").compactMap { $0[0].text }
    }

    public func setPinned(_ pinned: Bool, path: String) throws {
        try db.query("UPDATE sessions SET pinned = ? WHERE path = ?", [.int(pinned ? 1 : 0), .text(path)])
    }

    public func setNote(_ note: String?, path: String) throws {
        try db.query("UPDATE sessions SET note = ? WHERE path = ?", [note.map(SQLValue.text) ?? .null, .text(path)])
    }

    /// Turns what a person typed into a safe FTS5 query: every word must match, the last as a prefix.
    public static func ftsQuery(_ input: String) -> String? {
        let words = input.split(whereSeparator: { $0.isWhitespace }).map { $0.replacingOccurrences(of: "\"", with: "\"\"") }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in "\"\(w)\"" + (i == words.count - 1 ? "*" : "") }.joined(separator: " ")
    }

    /// S-3: full-text search across every indexed session.
    public func search(_ input: String, kind: SearchKind? = nil, limit: Int = 200) throws -> [SearchHit] {
        guard let q = Self.ftsQuery(input) else { return [] }
        var sql = "SELECT path, kind, line, snippet(session_text, 0, '⟦', '⟧', '…', 14) FROM session_text WHERE session_text MATCH ?"
        var params: [SQLValue] = [.text(q)]
        if let kind { sql += " AND kind = ?"; params.append(.text(kind.rawValue)) }
        sql += " ORDER BY rank LIMIT ?"
        params.append(.int(Int64(limit)))
        return try db.query(sql, params).map { r in
            SearchHit(path: r[0].text ?? "", kind: SearchKind(rawValue: r[1].text ?? "") ?? .user,
                      line: Int(r[2].int ?? Int64(r[2].text ?? "") ?? 0), snippet: r[3].text ?? "")
        }
    }

    public func rateLimits() throws -> [RateLimitWindow] {
        try db.query("SELECT provider, window, used, resets, observed, exact FROM rate_limits ORDER BY provider, window").map { r in
            RateLimitWindow(provider: r[0].text ?? "", window: r[1].text ?? "", usedPercent: r[2].double ?? 0,
                            resetsAt: r[3].double.map(Date.init(timeIntervalSince1970:)),
                            observedAt: Date(timeIntervalSince1970: r[4].double ?? 0), isExact: r[5].int == 1)
        }
    }
}

/// Finds transcripts on disk and keeps the index current. Read-only towards the originals (S-1).
public struct SessionIndexer: Sendable {
    public struct Candidate: Sendable {
        public var path: String
        public var agent: AgentTool
        public var subagents: [String]
        public var size: Int64
        public var mtime: Double
    }

    public var home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    static func stat(_ path: String) -> (size: Int64, mtime: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ((a[.size] as? NSNumber)?.int64Value ?? 0, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    public func discover() -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        let projects = "\(home)/.claude/projects"
        for proj in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let dir = "\(projects)/\(proj)"
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".jsonl") {
                let path = "\(dir)/\(file)"
                guard let st = Self.stat(path) else { continue }
                // Subagents, including those of workflows nested deeper (subagents/workflows/wf_*/…).
                let subDir = "\(dir)/\(String(file.dropLast(6)))/subagents"
                var subs: [String] = []
                if let e = fm.enumerator(atPath: subDir) {
                    for case let rel as String in e where rel.hasSuffix(".jsonl") { subs.append("\(subDir)/\(rel)") }
                }
                subs.sort()
                // Subagent files count towards "changed", since their usage belongs to this session.
                let subStats = subs.compactMap(Self.stat)
                out.append(Candidate(path: path, agent: .claudeCode, subagents: subs,
                                     size: st.size + subStats.reduce(0) { $0 + $1.size },
                                     mtime: max(st.mtime, subStats.map(\.mtime).max() ?? 0)))
            }
        }
        for root in ["\(home)/.codex/sessions", "\(home)/.codex/archived_sessions"] {
            guard let e = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in e where rel.hasSuffix(".jsonl") && (rel as NSString).lastPathComponent.hasPrefix("rollout-") {
                let path = "\(root)/\(rel)"
                if let st = Self.stat(path) { out.append(Candidate(path: path, agent: .codex, subagents: [], size: st.size, mtime: st.mtime)) }
            }
        }
        return out
    }

    public struct Summary: Sendable, Equatable {
        public var found = 0
        public var indexed = 0
        public var unchanged = 0
        public var failed = 0
    }

    /// Indexes new and changed transcripts. Safe to call often: unchanged files cost one `stat`.
    @discardableResult
    public func index(into app: AppDatabase, progress: (@Sendable (Int, Int) -> Void)? = nil) -> Summary {
        let candidates = discover()
        let known = (try? app.indexedState()) ?? [:]
        let todo = candidates.filter { c in
            guard let k = known[c.path] else { return true }
            return k.size != c.size || abs(k.mtime - c.mtime) > 0.5
        }
        var summary = Summary(found: candidates.count, unchanged: candidates.count - todo.count)
        for (i, c) in todo.enumerated() {
            if Task.isCancelled { break }
            progress?(i, todo.count)
            let parsed = c.agent == .claudeCode ? ClaudeParser.parse(path: c.path, subagentPaths: c.subagents) : CodexParser.parse(path: c.path)
            if let parsed, (try? app.upsert(parsed, fileSize: c.size, fileMTime: c.mtime)) != nil { summary.indexed += 1 } else { summary.failed += 1 }
        }
        progress?(todo.count, todo.count)
        // Keeping text of transcripts the agent has deleted is an opt-in feature (S-6) that is not
        // built yet, so for now the index never outlives the original.
        if !Task.isCancelled {
            let present = Set(candidates.map(\.path))
            for path in known.keys where !present.contains(path) && !FileManager.default.fileExists(atPath: path) {
                try? app.removeSession(path: path)
            }
        }
        return summary
    }
}

public enum SessionActions {
    /// S-4: the command that continues a session, to run in its project folder.
    public static func resumeCommand(_ s: SessionRow) -> String {
        let cd = s.cwd.flatMap { $0.isEmpty ? nil : "cd \(shellQuote($0)) && " } ?? ""
        switch s.agent {
        // The id comes from a file name or file content, so it is quoted like any other outside text.
        case .claudeCode: return "\(cd)claude --resume \(shellQuote(s.sessionID))"
        case .codex: return "\(cd)codex resume \(shellQuote(s.sessionID))"
        }
    }

    static func shellQuote(_ s: String) -> String {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func transcript(_ s: SessionRow) -> [TranscriptEntry] {
        s.agent == .claudeCode ? ClaudeParser.transcript(path: s.path) : CodexParser.transcript(path: s.path)
    }
}
