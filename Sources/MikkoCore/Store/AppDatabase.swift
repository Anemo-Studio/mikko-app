import Foundation

/// The single local database (spec §12): history, later the session index. No account, no sync.
public struct AppDatabase: Sendable {
    public let db: SQLiteDatabase

    static let migrations = [
        """
        CREATE TABLE clean_history(
            id INTEGER PRIMARY KEY,
            date REAL NOT NULL,
            category TEXT NOT NULL,
            name TEXT NOT NULL,
            path TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            automatic INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX clean_history_date ON clean_history(date);
        """,
        sessionMigration,
        agentLogMigration,
        // Usage accounting changed (forks, Codex repeats, nested subagents): re-read every transcript once.
        "UPDATE sessions SET file_size = -1;",
        // Haiku 5.5 long prompts are now priced at their own tier: re-read every transcript once.
        "UPDATE sessions SET file_size = -1;",
        // Search inside words: the text index moves to the trigram tokenizer and is rebuilt once.
        """
        DROP TABLE session_text;
        CREATE VIRTUAL TABLE session_text USING fts5(text, path UNINDEXED, kind UNINDEXED, line UNINDEXED, tokenize='trigram');
        UPDATE sessions SET file_size = -1, text_first = NULL, text_last = NULL;
        """,
    ]

    public init(db: SQLiteDatabase) throws {
        self.db = db
        try db.migrate(Self.migrations)
    }

    public static func openDefault() throws -> AppDatabase {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true).appendingPathComponent("mikko")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("mikko.sqlite").path
        let app = try AppDatabase(db: SQLiteDatabase(path: path))
        // The index holds transcript text: readable by the owner only, like the transcripts themselves.
        for suffix in ["", "-wal", "-shm"] { chmod(path + suffix, 0o600) }
        return app
    }
}

public struct CleanHistoryEntry: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var date: Date
    public var category: String
    public var name: String
    public var path: String
    public var bytes: Int64
    public var automatic: Bool
}

extension AppDatabase {
    /// D-3: every clean is recorded — date, what, how much.
    public func recordCleaned(_ items: [DiskItem], categoryTitle: (DiskItem) -> String, automatic: Bool = false,
                              date: Date = .now) throws {
        try db.transaction {
            for item in items {
                try db.query(
                    "INSERT INTO clean_history(date, category, name, path, bytes, automatic) VALUES (?,?,?,?,?,?)",
                    [.double(date.timeIntervalSince1970), .text(categoryTitle(item)), .text(item.name),
                     .text(item.path), .int(item.bytes), .int(automatic ? 1 : 0)])
            }
        }
    }

    public func cleanHistory(limit: Int = 500) throws -> [CleanHistoryEntry] {
        try db.query("SELECT id, date, category, name, path, bytes, automatic FROM clean_history ORDER BY date DESC, id DESC LIMIT ?",
                     [.int(Int64(limit))]).map { r in
            CleanHistoryEntry(id: r[0].int ?? 0, date: Date(timeIntervalSince1970: r[1].double ?? 0),
                              category: r[2].text ?? "", name: r[3].text ?? "", path: r[4].text ?? "",
                              bytes: r[5].int ?? 0, automatic: r[6].int == 1)
        }
    }
}
