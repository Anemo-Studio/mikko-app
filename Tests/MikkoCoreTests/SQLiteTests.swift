import Testing
@testable import MikkoCore

@Test func sqliteRoundTripAndMigrations() throws {
    let db = try SQLiteDatabase.inMemory()
    let m = ["CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, size REAL)", "ALTER TABLE t ADD COLUMN extra TEXT"]
    try db.migrate(m)
    try db.migrate(m) // idempotent
    try db.query("INSERT INTO t(name, size, extra) VALUES (?, ?, ?)", [.text("a'b"), .double(1.5), .null])
    let rows = try db.query("SELECT name, size, extra FROM t")
    #expect(rows == [[.text("a'b"), .double(1.5), .null]])
}

@Test func sqliteTransactionRollsBack() throws {
    let db = try SQLiteDatabase.inMemory()
    try db.execute("CREATE TABLE t(x)")
    #expect(throws: SQLiteError.self) {
        try db.transaction {
            try db.query("INSERT INTO t VALUES (1)")
            try db.execute("INSERT INTO nope VALUES (1)")
        }
    }
    #expect(try db.query("SELECT count(*) FROM t").first?.first == .int(0))
}

@Test func systemSQLiteHasFTS5() throws {
    let db = try SQLiteDatabase.inMemory()
    try db.execute("CREATE VIRTUAL TABLE f USING fts5(body)")
    try db.query("INSERT INTO f VALUES (?)", [.text("port 3000 already in use")])
    #expect(try db.query("SELECT count(*) FROM f WHERE f MATCH ?", [.text("already")]).first?.first == .int(1))
}

@Test func nestedTransactionFailureKeepsOuterWork() throws {
    let db = try SQLiteDatabase.inMemory()
    try db.execute("CREATE TABLE t(x)")
    try db.transaction {
        try db.query("INSERT INTO t VALUES (1)")
        try? db.transaction {
            try db.query("INSERT INTO t VALUES (2)")
            try db.execute("INSERT INTO nope VALUES (1)")
        }
        try db.query("INSERT INTO t VALUES (3)")
    }
    #expect(try db.query("SELECT x FROM t ORDER BY x").map { $0[0] } == [.int(1), .int(3)])
}

@Test func openingAnUnusablePathThrowsCleanly() {
    #expect(throws: SQLiteError.self) { _ = try SQLiteDatabase(path: "/nonexistent-dir/x/y.sqlite") }
}
