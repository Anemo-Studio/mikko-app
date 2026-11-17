import Foundation

public enum AgentTool: String, Sendable, Codable, CaseIterable {
    case claudeCode, codex, cursor
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// Token counts for one model. Cache fields are separate because they are priced differently.
public struct TokenUsage: Sendable, Equatable, Codable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite5m: Int64 = 0
    public var cacheWrite1h: Int64 = 0
    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
    }
    public var total: Int64 { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                   cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }
    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

/// Usage bucketed by model and local day, so Usage can chart it without re-reading transcripts.
public struct UsageBucket: Sendable, Equatable {
    public var model: String
    public var day: String // yyyy-MM-dd, local time
    public var usage: TokenUsage
}

public enum SearchKind: String, Sendable, CaseIterable {
    case user, assistant, command, file
}

public struct SearchableText: Sendable, Equatable {
    public var kind: SearchKind
    public var line: Int
    public var text: String
}

public struct RateLimitWindow: Sendable, Equatable {
    public var provider: String
    public var window: String   // "5h", "weekly"
    public var usedPercent: Double
    public var resetsAt: Date?
    public var observedAt: Date
    /// true when the figure comes from the provider itself, false when mikko estimated it (U-1).
    public var isExact: Bool
}

/// Everything mikko keeps about one session. The transcript itself stays where the agent wrote it.
public struct ParsedSession: Sendable {
    public var id: String
    public var agent: AgentTool
    public var path: String
    public var cwd: String?
    public var gitBranch: String?
    public var title: String?
    public var firstPrompt: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var messageCount = 0
    public var models: [String] = []
    public var usage: [UsageBucket] = []
    public var hasErrors = false
    public var filesChanged: [String] = []
    public var texts: [SearchableText] = []
    public var rateLimits: [RateLimitWindow] = []
    /// Some usage records were cut short by the agent, so the real cost is higher than computed.
    public var usageIncomplete = false

    public var displayTitle: String {
        let t = title ?? firstPrompt ?? "Untitled session"
        let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

public struct TranscriptEntry: Sendable, Identifiable {
    public enum Kind: String, Sendable { case user, assistant, tool, toolResult, fileChange, note }
    public var id: Int { line * 100 + index }
    public var line: Int
    public var index: Int
    public var kind: Kind
    public var title: String
    public var text: String
    public var timestamp: Date?
    public var isError: Bool
}

enum Timestamps {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
    static let lock = NSLock()

    static func parse(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Reads a file line by line without loading it whole; lines can be many MB.
/// Linear time: a read offset walks the buffer, and each byte is scanned for a newline once.
public struct LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var offset = 0     // start of the next line within `buffer`
    private var scanned = 0    // bytes after `offset` already known to hold no newline
    private var eof = false
    private let chunk: Int

    public init?(path: String, chunk: Int = 1 << 20) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        handle = h
        self.chunk = chunk
    }

    /// Next complete line (without the newline). A trailing partial line — a write in
    /// progress — is returned only if `includePartial` is set.
    public mutating func next(includePartial: Bool = false) -> Data? {
        while true {
            let start = offset + scanned
            let found: Int? = buffer.withUnsafeBytes { raw -> Int? in
                guard start < raw.count, let base = raw.baseAddress else { return nil }
                guard let hit = memchr(base + start, 0x0A, raw.count - start) else { return nil }
                return UnsafeRawPointer(hit) - base
            }
            if let nl = found {
                let line = buffer.subdata(in: offset..<nl)
                offset = nl + 1
                scanned = 0
                return line
            }
            scanned = buffer.count - offset
            if eof {
                guard includePartial, scanned > 0 else { return nil }
                let line = buffer.subdata(in: offset..<buffer.count)
                offset = buffer.count
                scanned = 0
                return line
            }
            // Drop what has been consumed before growing, so memory stays near one line + one chunk.
            if offset > 0 {
                buffer.removeSubrange(0..<offset)
                offset = 0
            }
            let more: Data? = autoreleasepool { try? handle.read(upToCount: chunk) }
            if let more, !more.isEmpty { buffer.append(more) } else { eof = true }
        }
    }

    public func close() { try? handle.close() }
}
