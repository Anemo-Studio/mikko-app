import Foundation

/// Cursor keeps chat history in its own SQLite database (`state.vscdb`, table `cursorDiskKV`):
/// one `composerData:<id>` record per conversation with the ordered message ids, and one
/// `bubbleId:<composer>:<bubble>` record per message. Read strictly read-only, and only those
/// two key families — never account or auth keys. Cursor keeps spend server-side, so these
/// sessions carry no cost (spec §14.4).
public enum CursorParser {
    public static func databasePath(home: String = NSHomeDirectory()) -> String {
        "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    /// A session's path in mikko's index: the database file plus the conversation id.
    public static func sessionPath(database: String, composerID: String) -> String { "\(database)#\(composerID)" }

    public static func split(_ path: String) -> (database: String, composerID: String)? {
        guard let r = path.range(of: ".vscdb#", options: .backwards) else { return nil }
        let id = String(path[r.upperBound...])
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return (String(path[..<r.upperBound].dropLast()), id)
    }

    public struct Candidate: Sendable {
        public var path: String
        public var messageCount: Int64
        public var updated: Double
    }

    /// Conversations with at least one message. Uses SQLite's JSON functions so large records
    /// are never loaded whole.
    public static func candidates(home: String = NSHomeDirectory()) -> [Candidate] {
        let dbPath = databasePath(home: home)
        guard FileManager.default.fileExists(atPath: dbPath), let db = try? SQLiteDatabase(readOnly: dbPath) else { return [] }
        let sql = """
            SELECT substr(key, 14), json_array_length(value, '$.fullConversationHeadersOnly'),
                   coalesce(json_extract(value, '$.lastUpdatedAt'), json_extract(value, '$.createdAt'))
            FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;' AND json_valid(value)
            """
        return ((try? db.query(sql)) ?? []).compactMap { r in
            guard let id = r[0].text, let n = r[1].int, n > 0 else { return nil }
            let ms = r[2].double ?? r[2].int.map(Double.init) ?? 0
            return Candidate(path: sessionPath(database: dbPath, composerID: id), messageCount: n, updated: ms / 1000)
        }
    }

    /// composer id → project folder, from Cursor's per-workspace state.
    public static func workspaceFolders(home: String = NSHomeDirectory()) -> [String: String] {
        let root = "\(home)/Library/Application Support/Cursor/User/workspaceStorage"
        var out: [String: String] = [:]
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            guard let data = FileManager.default.contents(atPath: "\(root)/\(dir)/workspace.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = (json["folder"] as? String).flatMap(URL.init(string:)), folder.isFileURL,
                  let db = try? SQLiteDatabase(readOnly: "\(root)/\(dir)/state.vscdb"),
                  let raw = try? db.query("SELECT value FROM ItemTable WHERE key = 'composer.composerData'").first?[0].text,
                  let state = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            for c in (state["allComposers"] as? [[String: Any]]) ?? [] {
                if let id = c["composerId"] as? String { out[id] = folder.path }
            }
        }
        return out
    }

    struct Message {
        var kind: TranscriptEntry.Kind
        var text: String
        var tool: String?
    }

    static func messages(path: String) -> (composer: [String: Any], messages: [Message])? {
        guard let (dbPath, id) = split(path), let db = try? SQLiteDatabase(readOnly: dbPath),
              let raw = try? db.query("SELECT value FROM cursorDiskKV WHERE key = ?", [.text("composerData:\(id)")]).first?[0].text,
              let composer = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        let headers = (composer["fullConversationHeadersOnly"] as? [[String: Any]]) ?? []
        let rows = (try? db.query("SELECT key, value FROM cursorDiskKV WHERE key >= ? AND key < ?",
                                  [.text("bubbleId:\(id):"), .text("bubbleId:\(id);")])) ?? []
        var bubbles: [String: [String: Any]] = [:]
        for r in rows {
            guard let key = r[0].text, let value = r[1].text,
                  let b = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { continue }
            bubbles[String(key.split(separator: ":").last ?? "")] = b
        }
        var out: [Message] = []
        for h in headers {
            guard let bid = h["bubbleId"] as? String, let b = bubbles[bid] else { continue }
            let type = (b["type"] as? Int) ?? (h["type"] as? Int) ?? 0
            let text = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if type == 1 {
                if !text.isEmpty { out.append(Message(kind: .user, text: text)) }
            } else {
                if let tool = b["toolFormerData"] as? [String: Any], let name = tool["name"] as? String {
                    let detail = (tool["rawArgs"] as? String) ?? (tool["params"] as? String) ?? ""
                    out.append(Message(kind: .tool, text: String(detail.prefix(4000)), tool: name))
                }
                if !text.isEmpty { out.append(Message(kind: .assistant, text: text)) }
            }
        }
        return (composer, out)
    }

    public static func parse(path: String, folders: [String: String] = [:]) -> ParsedSession? {
        guard let (_, id) = split(path), let (composer, messages) = messages(path: path) else { return nil }
        func date(_ key: String) -> Date? { (composer[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        var s = ParsedSession(id: id, agent: .cursor, path: path)
        s.cwd = folders[id]
        s.title = (composer["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        s.firstPrompt = messages.first { $0.kind == .user }?.text
        s.startedAt = date("createdAt")
        s.endedAt = date("lastUpdatedAt") ?? s.startedAt
        s.messageCount = messages.filter { $0.kind != .tool }.count
        for (i, m) in messages.enumerated() {
            switch m.kind {
            case .user: s.texts.append(SearchableText(kind: .user, line: i, text: m.text))
            case .assistant: s.texts.append(SearchableText(kind: .assistant, line: i, text: m.text))
            case .tool: if !m.text.isEmpty { s.texts.append(SearchableText(kind: .command, line: i, text: m.text)) }
            default: break
            }
        }
        return s
    }

    public static func transcript(path: String) -> [TranscriptEntry] {
        guard let (_, messages) = messages(path: path) else { return [] }
        return messages.enumerated().map { i, m in
            TranscriptEntry(line: i, index: 0, kind: m.kind,
                            title: m.kind == .user ? "You" : m.kind == .tool ? (m.tool ?? "Tool") : "Cursor",
                            text: m.text, timestamp: nil, isError: false)
        }
    }
}
