import Foundation
import Testing
@testable import MikkoCore

private func make(_ root: URL, _ files: [String]) throws {
    for f in files {
        let u = root.appendingPathComponent(f)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: u)
    }
}

@Test func findsArtifactsOnlyNextToTheirMarkers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-proj-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: dir) }
    try make(dir, [
        "shop/.git/HEAD", "shop/package.json", "shop/node_modules/a/index.js", "shop/.next/cache/x",
        "shop/apps/web/package.json", "shop/apps/web/node_modules/b/index.js",
        "shop/src/build/keep.txt",                 // "build" without a marker: source, must be ignored
        "shop/node_modules/a/node_modules/c/x.js", // nested inside an artifact: not a separate item
        "notes/dist/essay.txt",                    // "dist" without package.json: not an artifact
        "api/.venv/pyvenv.cfg", "api/.venv/lib/x.py", "api/main.py",
        "rusty/Cargo.toml", "rusty/target/debug/bin",
    ])
    try "ref: refs/heads/feature/x\n".write(to: dir.appendingPathComponent("shop/.git/HEAD"), atomically: true, encoding: .utf8)

    let projects = ProjectScanner().scan(folders: [dir.path])
    let byName = Dictionary(uniqueKeysWithValues: projects.map { ($0.name, $0) })
    #expect(Set(byName.keys) == ["shop", "api", "rusty"])
    #expect(Set(byName["shop"]!.artifacts.map(\.name)) == ["node_modules", ".next", "apps/web/node_modules"])
    #expect(byName["shop"]!.branch == "feature/x" && byName["shop"]!.isWorktree == false)
    #expect(byName["api"]!.artifacts.map(\.risk) == [.caution])
    // "target" outside git cannot be confirmed as generated → Caution, never pre-selected.
    #expect(byName["rusty"]!.artifacts.first?.detail?.hasPrefix("Rust/Maven build") == true)
    #expect(byName["rusty"]!.artifacts.first?.risk == .caution)
    #expect(byName["shop"]!.isActive(withinDays: 14))
    #expect(!byName["shop"]!.isActive(withinDays: 14, now: .now.addingTimeInterval(30 * 86_400)))

    #expect(byName["shop"]!.hasGit && !byName["api"]!.hasGit)
    // Overlapping folders must not produce duplicates.
    let twice = ProjectScanner().scan(folders: [dir.path, dir.path + "/shop"])
    #expect(twice.count == 3 && twice.first { $0.name == "shop" }!.artifacts.count == 3)

    let ex = ExclusionList(paths: [dir.path + "/shop"])
    #expect(Set(ProjectScanner(exclusions: ex).scan(folders: [dir.path]).map(\.name)) == ["api", "rusty"])
}

@Test func detectsWorktreeAndBranch() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-wt-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: dir) }
    try make(dir, ["main/.git/worktrees/wt/HEAD", "wt/file"])
    try "ref: refs/heads/claude/fix\n".write(to: dir.appendingPathComponent("main/.git/worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
    try "gitdir: \(dir.path)/main/.git/worktrees/wt\n".write(to: dir.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
    let info = GitInfo.read(root: dir.path + "/wt")
    #expect(info.isWorktree && info.branch == "claude/fix")
}

@Test func cleanHistoryIsRecordedNewestFirst() throws {
    let app = try AppDatabase(db: .inMemory())
    func item(_ n: String, _ b: Int64) -> DiskItem { DiskItem(categoryID: "c", name: n, path: "/x/\(n)", bytes: b, modified: nil, risk: .safe) }
    try app.recordCleaned([item("a", 10)], categoryTitle: { _ in "Xcode" }, date: Date(timeIntervalSince1970: 100))
    try app.recordCleaned([item("b", 20)], categoryTitle: { _ in "Node" }, automatic: true, date: Date(timeIntervalSince1970: 200))
    let h = try app.cleanHistory()
    #expect(h.map(\.name) == ["b", "a"] && h[0].automatic && h[0].bytes == 20 && h[1].category == "Xcode")
}

@Test func ambiguousFoldersAreSafeOnlyWhenGitIgnoresThem() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-amb-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: dir) }
    try make(dir, ["gen/package.json", "gen/dist/out.js", "gen/build/icon.icns", "gen/.claude/local/node_modules/x/i.js",
                   "gen/.claude/local/package.json", "nogit/package.json", "nogit/dist/x.js"])
    try "dist/\n".write(to: dir.appendingPathComponent("gen/.gitignore"), atomically: true, encoding: .utf8)
    #expect(GitInfo.run(["init", "-q"], root: dir.path + "/gen")?.status == 0)

    let projects = Dictionary(uniqueKeysWithValues: ProjectScanner().scan(folders: [dir.path]).map { ($0.name, $0) })
    let gen = Dictionary(uniqueKeysWithValues: projects["gen"]!.artifacts.map { ($0.name, $0) })
    #expect(gen["dist"]?.risk == .safe)         // ignored → generated
    #expect(gen["build"]?.risk == .caution)     // not ignored → may be source (electron-builder resources)
    #expect(gen[".claude/local/node_modules"] == nil) // agent's own install is not a project artifact
    #expect(projects["nogit"]!.artifacts.first?.risk == .caution && projects["nogit"]!.hasGit == false)
}

@Test func nestedEditsCountAsProjectActivity() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-act-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: dir) }
    try make(dir, ["p/package.json", "p/src/deep/a.ts", "p/node_modules/x/i.js"])
    let old = Date().addingTimeInterval(-40 * 86_400)
    for f in ["p", "p/package.json", "p/src", "p/src/deep", "p/src/deep/a.ts", "p/node_modules"] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path + "/" + f)
    }
    let names = Set(ArtifactRule.standard.map(\.name))
    #expect(abs(ProjectScanner.lastSourceChange(root: dir.path + "/p", artifactNames: names)!.timeIntervalSince(old)) < 2)
    // An in-place edit deep in the tree changes only that file's mtime.
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path + "/p/src/deep/a.ts")
    #expect(ProjectScanner.lastSourceChange(root: dir.path + "/p", artifactNames: names)!.timeIntervalSinceNow > -60)
}
