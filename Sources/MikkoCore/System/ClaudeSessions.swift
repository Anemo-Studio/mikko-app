import Foundation

/// What Claude Code itself records about sessions that are running right now.
public enum ClaudeSessions {
    public struct Live: Sendable, Equatable {
        public var pid: Int32
        public var sessionID: String
        public var cwd: String?
    }

    /// Reads `~/.claude/sessions/<pid>.json` and keeps entries whose process is still alive.
    public static func live(home: String = NSHomeDirectory(),
                            isAlive: (Int32) -> Bool = { ProcessTable.identity(of: $0) != nil }) -> [Live] {
        let dir = "\(home)/.claude/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(name)"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, let id = obj["sessionId"] as? String,
                  isAlive(pid) else { return nil }
            return Live(pid: pid, sessionID: id, cwd: obj["cwd"] as? String)
        }
    }
}
