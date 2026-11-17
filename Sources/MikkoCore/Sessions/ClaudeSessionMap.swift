import Foundation

/// Which Claude Code session a running agent process belongs to.
/// Claude Code writes `~/.claude/sessions/<pid>.json` with the session id and the moment
/// it started; the start time is checked so a recycled pid never points at an old session.
public enum ClaudeSessionMap {
    public static func sessionID(for agent: ProcessIdentity,
                                 directory: URL = FileManager.default.homeDirectoryForCurrentUser
                                     .appendingPathComponent(".claude/sessions")) -> String? {
        let file = directory.appendingPathComponent("\(agent.pid).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["sessionId"] as? String, !id.isEmpty else { return nil }
        if let ms = json["startedAt"] as? Double {
            // The file is written shortly after the process starts; a minute covers slow starts.
            let started = Date(timeIntervalSince1970: ms / 1000)
            guard started >= agent.startDate.addingTimeInterval(-5), started <= agent.startDate.addingTimeInterval(60) else { return nil }
        }
        return id
    }
}
