import Darwin
import Foundation

public enum Ports {
    /// true when something accepts TCP connections on localhost:port.
    public static func isAccepting(_ port: UInt16, timeoutMs: Int32 = 400) -> Bool {
        for (family, host) in [(AF_INET, "127.0.0.1"), (AF_INET6, "::1")] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            var rc: Int32
            if family == AF_INET {
                var a = sockaddr_in()
                a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
                inet_pton(AF_INET, host, &a.sin_addr)
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var a = sockaddr_in6()
                a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port.bigEndian
                inet_pton(AF_INET6, host, &a.sin6_addr)
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if rc == 0 { return true }
            guard errno == EINPROGRESS else { continue }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMs) > 0 else { continue }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err == 0 { return true }
        }
        return false
    }

    /// A-1 `wait`: polls until the port answers or time runs out.
    public static func wait(for port: UInt16, timeout: TimeInterval, interval: TimeInterval = 0.25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isAccepting(port) { return true }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline
        return false
    }

    static func canBind(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// The first port at or after `preferred` that nothing listens on.
    public static func suggestFree(from preferred: UInt16 = 3000, taken: Set<UInt16>) -> UInt16? {
        var p = max(preferred, 1024)
        while p < 65000 {
            if !taken.contains(p), canBind(p) { return p }
            p += 1
        }
        return nil
    }
}

public struct AgentAction: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var date: Date
    public var agent: String
    public var sessionID: String?
    public var tool: String
    public var target: String
    public var result: String
}

extension AppDatabase {
    static let agentLogMigration = """
    CREATE TABLE agent_actions(id INTEGER PRIMARY KEY, date REAL NOT NULL, agent TEXT NOT NULL, session TEXT,
        tool TEXT NOT NULL, target TEXT NOT NULL, result TEXT NOT NULL);
    """

    /// A-3: what agents did through MCP — who, when, what.
    public func logAgentAction(agent: String, sessionID: String?, tool: String, target: String, result: String, date: Date = .now) throws {
        try db.query("INSERT INTO agent_actions(date, agent, session, tool, target, result) VALUES (?,?,?,?,?,?)",
                     [.double(date.timeIntervalSince1970), .text(agent), sessionID.map(SQLValue.text) ?? .null,
                      .text(tool), .text(target), .text(result)])
    }

    public func agentActions(limit: Int = 300) throws -> [AgentAction] {
        try db.query("SELECT id, date, agent, session, tool, target, result FROM agent_actions ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).map { r in
            AgentAction(id: r[0].int ?? 0, date: Date(timeIntervalSince1970: r[1].double ?? 0), agent: r[2].text ?? "",
                        sessionID: r[3].text, tool: r[4].text ?? "", target: r[5].text ?? "", result: r[6].text ?? "")
        }
    }
}
