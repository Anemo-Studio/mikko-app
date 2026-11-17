import Foundation

public struct UsageSlice: Sendable, Identifiable, Equatable {
    public var id: String { key }
    public var key: String
    public var cost: Double
    public var tokens: Int64
    /// Tokens on models without a known price are not in `cost`.
    public var unpricedTokens: Int64
}

public struct UsageTotals: Sendable, Equatable {
    public var usage = TokenUsage()
    public var cost = 0.0
    public var unpricedTokens: Int64 = 0
    public init(usage: TokenUsage = TokenUsage(), cost: Double = 0, unpricedTokens: Int64 = 0) {
        self.usage = usage; self.cost = cost; self.unpricedTokens = unpricedTokens
    }
}

extension AppDatabase {
    /// `fromDay`/`toDay` are local "yyyy-MM-dd" strings, inclusive.
    public func usageTotals(fromDay: String, toDay: String = "9999-12-31", project: String? = nil, agent: AgentTool? = nil) throws -> UsageTotals {
        var sql = """
            SELECT COALESCE(SUM(input),0), COALESCE(SUM(output),0), COALESCE(SUM(cache_read),0), COALESCE(SUM(cache_w5),0),
                   COALESCE(SUM(cache_w1),0), COALESCE(SUM(cost),0),
                   COALESCE(SUM(CASE WHEN cost IS NULL THEN input+output+cache_read+cache_w5+cache_w1 ELSE 0 END),0)
            FROM session_usage WHERE day >= ? AND day <= ?
            """
        var params: [SQLValue] = [.text(fromDay), .text(toDay)]
        if let project { sql += " AND project = ?"; params.append(.text(project)) }
        if let agent { sql += " AND agent = ?"; params.append(.text(agent.rawValue)) }
        guard let r = try db.query(sql, params).first else { return UsageTotals() }
        return UsageTotals(usage: TokenUsage(input: r[0].int ?? 0, output: r[1].int ?? 0, cacheRead: r[2].int ?? 0,
                                             cacheWrite5m: r[3].int ?? 0, cacheWrite1h: r[4].int ?? 0),
                           cost: r[5].double ?? 0, unpricedTokens: r[6].int ?? 0)
    }

    public enum UsageDimension: String, Sendable { case model, project, day, agent }

    public func usage(by dimension: UsageDimension, fromDay: String, toDay: String = "9999-12-31") throws -> [UsageSlice] {
        let col = dimension.rawValue
        let order = dimension == .day ? "\(col) ASC" : "2 DESC"
        return try db.query("""
            SELECT \(col), COALESCE(SUM(cost),0), SUM(input+output+cache_read+cache_w5+cache_w1),
                   COALESCE(SUM(CASE WHEN cost IS NULL THEN input+output+cache_read+cache_w5+cache_w1 ELSE 0 END),0)
            FROM session_usage WHERE day >= ? AND day <= ? GROUP BY \(col) ORDER BY \(order)
            """, [.text(fromDay), .text(toDay)]).map { r in
            UsageSlice(key: r[0].text ?? "", cost: r[1].double ?? 0, tokens: r[2].int ?? 0, unpricedTokens: r[3].int ?? 0)
        }
    }

    /// U-5: sessions that cost the most within the window — what was spent since `fromDay`,
    /// not a long session's lifetime total. The returned rows carry the in-window cost.
    public func topSessions(fromDay: String, limit: Int = 10) throws -> [SessionRow] {
        let spent = try db.query("""
            SELECT path, COALESCE(SUM(cost),0) FROM session_usage WHERE day >= ? GROUP BY path ORDER BY 2 DESC LIMIT ?
            """, [.text(fromDay), .int(Int64(limit))])
        return try spent.compactMap { r in
            guard let path = r[0].text, var row = try session(path: path) else { return nil }
            row.cost = r[1].double ?? 0
            return row
        }
    }
}

public enum UsageDays {
    public static func day(_ date: Date) -> String { Timestamps.day(date) }
    /// The local day `n` days before today (0 = today).
    public static func daysAgo(_ n: Int, now: Date = .now) -> String {
        Timestamps.day(Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now)
    }
}

/// U-4: a spending limit and whether it has been crossed.
public struct Budget: Sendable, Codable, Equatable, Identifiable {
    public enum Period: String, Sendable, Codable, CaseIterable { case day, month }
    public var id: String { "\(project ?? "*")|\(period.rawValue)" }
    /// nil = all projects.
    public var project: String?
    public var period: Period
    public var limitUSD: Double
    public init(project: String? = nil, period: Period, limitUSD: Double) { self.project = project; self.period = period; self.limitUSD = limitUSD }

    public func fromDay(now: Date = .now) -> String {
        switch period {
        case .day: return Timestamps.day(now)
        case .month:
            let c = Calendar.current.dateComponents([.year, .month], from: now)
            return String(format: "%04d-%02d-01", c.year ?? 0, c.month ?? 0)
        }
    }
}
