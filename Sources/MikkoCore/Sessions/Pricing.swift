import Foundation

/// List prices in USD per million tokens (U-3). Bundled, so nothing is fetched.
/// Source: provider pricing pages, checked 2026-11-15.
public struct ModelPrice: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
}

public enum Pricing {
    public static let asOf = "2026-11-15"

    /// Matched by substring, most specific first.
    static let table: [(match: String, price: ModelPrice)] = [
        ("fable-5-2", .init(input: 8, output: 40, cacheRead: 0.20, cacheWrite5m: 10, cacheWrite1h: 16)),
        ("fable-5-1", .init(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.5, cacheWrite1h: 20)),
        ("fable-5", .init(input: 10, output: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: 20)),
        ("opus-5-5", .init(input: 4, output: 20, cacheRead: 0.20, cacheWrite5m: 5, cacheWrite1h: 8)),
        ("opus-5", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("opus-4-8", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("opus-4-7", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("opus-4-6", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("opus-4-5", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("sonnet-5-5", .init(input: 2, output: 10, cacheRead: 0.10, cacheWrite5m: 2.5, cacheWrite1h: 4)),
        ("sonnet-5", .init(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.5, cacheWrite1h: 4)),
        ("sonnet-4-6", .init(input: 3, output: 15, cacheRead: 0.30, cacheWrite5m: 3.75, cacheWrite1h: 6)),
        ("sonnet-4-5", .init(input: 3, output: 15, cacheRead: 0.30, cacheWrite5m: 3.75, cacheWrite1h: 6)),
        ("sonnet-4", .init(input: 3, output: 15, cacheRead: 0.30, cacheWrite5m: 3.75, cacheWrite1h: 6)),
        // Haiku 5.5 has a higher tier above 100k prompt tokens; the lower tier is used here.
        ("haiku-5-5", .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.20)),
        ("haiku-4-5", .init(input: 1, output: 5, cacheRead: 0.10, cacheWrite5m: 1.25, cacheWrite1h: 2)),
        ("gpt-5.6-sol", .init(input: 4, output: 20, cacheRead: 0.40, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.6-terra", .init(input: 2, output: 12, cacheRead: 0.20, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.6-luna", .init(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.5", .init(input: 5, output: 30, cacheRead: 0.50, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.4", .init(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.3", .init(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.2", .init(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.1", .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5", .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 0, cacheWrite1h: 0)),
    ]

    /// What may follow a table entry in a real model id: a Codex variant, a date stamp, a bracket
    /// suffix. Anything else ("-mini", "-fast", a newer version digit) is a different, unknown model.
    nonisolated(unsafe) static let allowedSuffix = try! NSRegularExpression(pattern: #"^(-codex(-max)?)?(-\d{8})?(@\d{8})?(\[.*\])?$"#)

    public static func price(for model: String) -> ModelPrice? {
        let m = model.lowercased()
        for entry in table {
            guard let r = m.range(of: entry.match) else { continue }
            let rest = String(m[r.upperBound...])
            if allowedSuffix.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil { return entry.price }
        }
        return nil
    }

    /// API-equivalent cost at list price. nil = unknown model: shown as "unpriced", never as $0.
    public static func cost(model: String, usage u: TokenUsage) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(u.input) * p.input + Double(u.output) * p.output + Double(u.cacheRead) * p.cacheRead
            + Double(u.cacheWrite5m) * p.cacheWrite5m + Double(u.cacheWrite1h) * p.cacheWrite1h) / 1_000_000
    }
}
