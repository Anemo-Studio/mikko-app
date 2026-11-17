import Foundation
import Testing
@testable import MikkoCore

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u.resolvingSymlinksInPath()
}

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Test func sizerCountsTreeAndHardLinksOnce() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir.appendingPathComponent("a/one.bin"), bytes: 100_000)
    let single = DirectorySizer.allocatedSize(of: dir)
    #expect(single >= 100_000 && single < 200_000)
    try FileManager.default.linkItem(at: dir.appendingPathComponent("a/one.bin"), to: dir.appendingPathComponent("a/link.bin"))
    #expect(DirectorySizer.allocatedSize(of: dir) == single)
    #expect(DirectorySizer.allocatedSize(of: dir.appendingPathComponent("missing")) == 0)
}

@Test func scannerSplitsChildrenAndHonoursExclusions() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir.appendingPathComponent("DerivedData/shop-abcdefghijklmnopqrstuvwxyzab/x"), bytes: 50_000)
    try write(dir.appendingPathComponent("DerivedData/blog-abcdefghijklmnopqrstuvwxyzab/x"), bytes: 10_000)
    let cat = DiskCategory(id: "t", group: "G", title: "T", risk: .safe, whatYouLose: "",
                           locations: [DiskLocation(dir.path + "/DerivedData", .children(depth: 1)),
                                       DiskLocation(dir.path + "/absent")])
    let all = DiskScanner().scan(cat)
    #expect(all.items.map(\.name) == ["shop", "blog"])
    let ex = ExclusionList(paths: [dir.path + "/DerivedData/shop-abcdefghijklmnopqrstuvwxyzab"])
    #expect(DiskScanner(exclusions: ex).scan(cat).items.map(\.name) == ["blog"])
}

@Test func scanStreamSkipsEmptyAndExcludedCategories() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir.appendingPathComponent("a/x"), bytes: 10_000)
    try write(dir.appendingPathComponent("b/x"), bytes: 10_000)
    func cat(_ id: String) -> DiskCategory {
        DiskCategory(id: id, group: "G", title: id, risk: .safe, whatYouLose: "", locations: [DiskLocation(dir.path + "/" + id)])
    }
    var ids: [String] = []
    for await r in DiskScanner(exclusions: .init(categoryIDs: ["b"])).scan([cat("a"), cat("b"), cat("missing")]) { ids.append(r.id) }
    #expect(ids == ["a"])
}

@Test func cleanerOnlyRemovesExactScannerPaths() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("cache")
    try write(root.appendingPathComponent("item/x"), bytes: 1000)
    try write(root.appendingPathComponent("item/inner/y"), bytes: 1000)
    try write(root.appendingPathComponent("keep/x"), bytes: 1000)
    try write(dir.appendingPathComponent("cache2/x"), bytes: 10)
    try write(dir.appendingPathComponent("outside/secret"), bytes: 10)
    try FileManager.default.createSymbolicLink(atPath: root.path + "/link", withDestinationPath: dir.path + "/outside")
    let removed = Box()
    let cat = DiskCategory(id: "t", group: "G", title: "T", risk: .safe, whatYouLose: "",
                           locations: [DiskLocation(root.path, .children(depth: 1))])
    var cleaner = DiskCleaner(categories: [cat], exclusions: .init(paths: [root.path + "/keep"]))
    cleaner.remove = { url in removed.add(url.lastPathComponent) }
    func item(_ p: String, cat: String = "t") -> DiskItem { DiskItem(categoryID: cat, name: p, path: p, bytes: 1, modified: nil, risk: .safe) }

    #expect(cleaner.refusal(for: item(root.path + "/item")) == nil)
    #expect(cleaner.refusal(for: item(root.path)) != nil)                 // the location itself, not an item
    #expect(cleaner.refusal(for: item(root.path + "/item/inner")) != nil) // deeper than an item
    #expect(cleaner.refusal(for: item(dir.path + "/cache2")) != nil)      // sibling with a shared prefix
    #expect(cleaner.refusal(for: item(root.path + "/../outside")) != nil)
    #expect(cleaner.refusal(for: item(root.path + "/link")) != nil)       // symlink pointing out of the root
    #expect(cleaner.refusal(for: item(root.path + "/keep")) != nil)       // Never clean
    #expect(cleaner.refusal(for: item(NSHomeDirectory())) != nil)
    #expect(cleaner.refusal(for: item("/")) != nil)
    #expect(DiskCleaner(categories: [cat], exclusions: .init(categoryIDs: ["t"])).refusal(for: item(root.path + "/item")) != nil)

    let out = cleaner.clean([item(root.path + "/item"), item(dir.path + "/outside"), item(root.path + "/gone")])
    #expect(out.cleaned.count == 1 && out.failures.count == 1 && out.skipped.count == 1)
    #expect(removed.values == ["item"])
}

@Test func cleanerRechecksProjectArtifactsAtCleanTime() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir.appendingPathComponent("app/package.json"), bytes: 10)
    try write(dir.appendingPathComponent("app/node_modules/a/x"), bytes: 100)
    try write(dir.appendingPathComponent("docs/node_modules/x"), bytes: 100) // no package.json beside it
    try write(dir.appendingPathComponent("app/src/x"), bytes: 100)
    let cleaner = DiskCleaner(allowedPaths: [], artifactRules: ArtifactRule.standard, remove: { _ in })
    func art(_ p: String) -> DiskItem { DiskItem(categoryID: ProjectScanner.categoryID, name: p, path: dir.path + p, bytes: 1, modified: nil, risk: .safe) }
    #expect(cleaner.refusal(for: art("/app/node_modules")) == nil)
    #expect(cleaner.refusal(for: art("/docs/node_modules")) != nil)
    #expect(cleaner.refusal(for: art("/app/src")) != nil)
    #expect(cleaner.refusal(for: art("/app")) != nil)
}

@Test func agentTempSkipsRecentSessionFolders() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir.appendingPathComponent("proj/old-session/x"), bytes: 5000)
    try write(dir.appendingPathComponent("proj/new-session/x"), bytes: 5000)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)],
                                          ofItemAtPath: dir.path + "/proj/old-session")
    let cat = DiskCategory(id: DiskCatalog.agentTempID, group: "AI", title: "t", risk: .caution, whatYouLose: "",
                           locations: [DiskLocation(dir.path, .children(depth: 2))])
    #expect(DiskScanner().scan(cat).items.map(\.name) == ["proj/old-session"])
}

@Test func runningToolsBlockTheirCaches() {
    let cats = DiskCatalog.standard(home: "/Users/t", uid: 501, environment: [:])
    let derived = cats.first { $0.id == "xcode.deriveddata" }!
    #expect(derived.runningBlocker(among: ["zsh", "xcodebuild"]) == "xcodebuild")
    #expect(derived.runningBlocker(among: ["com.apple.iphonesimulator"]) != nil)
    #expect(derived.runningBlocker(among: ["node"]) == nil)
    #expect(cats.first { $0.id == "android.gradle" }!.runningBlocker(among: ["GradleDaemon"]) != nil)
    let snap = ProcessSnapshot(records: [
        ProcRecord(identity: .init(pid: 5, startSec: 1, startUsec: 0), ppid: 1, uid: 501, name: "node", argv: ["npm install", ""]),
        ProcRecord(identity: .init(pid: 6, startSec: 1, startUsec: 0), ppid: 1, uid: 501, name: "java", argv: ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]),
        ProcRecord(identity: .init(pid: 7, startSec: 1, startUsec: 0), ppid: 1, uid: 0, name: "cargo"),
    ])
    #expect(snap.toolMarkers(uid: 501).isSuperset(of: ["node", "npm", "java", "GradleDaemon"]))
    #expect(!snap.toolMarkers(uid: 501).contains("cargo"))
}

@Test func catalogIsWellFormed() {
    let cats = DiskCatalog.standard(home: "/Users/t", uid: 501, environment: [:])
    #expect(Set(cats.map(\.id)).count == cats.count)
    for c in cats {
        #expect(!c.whatYouLose.isEmpty && !c.locations.isEmpty)
        for l in c.locations { #expect(l.path.hasPrefix("/Users/t/") || l.path.hasPrefix("/private/tmp/claude-501")) }
        // Anything that is not plainly regenerable must not be pre-selected.
        if c.risk == .safe { #expect(!["pypoetry\"", ".m2", "JetBrains", "vm_bundles", "pkgs"].contains { n in c.locations.contains { $0.path.hasSuffix(n) } }) }
    }
    // The catalog must never offer agent session transcripts for cleaning.
    #expect(!cats.flatMap(\.locations).contains { $0.path.contains(".claude/projects") || $0.path.contains(".codex/sessions") })
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Test func ollamaModelsAreRowsAndSharedBlobsAreNeverRemoved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-ollama-\(UUID().uuidString)/models").path
    defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(root)/blobs", withIntermediateDirectories: true)
    func blob(_ c: Character, _ size: Int) -> String {
        let hex = String(repeating: c, count: 64)
        fm.createFile(atPath: "\(root)/blobs/sha256-\(hex)", contents: Data(count: size))
        return "sha256:\(hex)"
    }
    let base = blob("a", 40_000), small = blob("b", 8_000), other = blob("c", 8_000)
    func manifest(_ rel: String, _ layers: [String]) throws {
        let path = "\(root)/manifests/registry.ollama.ai/\(rel)"
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let json: [String: Any] = ["layers": layers.map { ["digest": $0] }]
        fm.createFile(atPath: path, contents: try JSONSerialization.data(withJSONObject: json))
    }
    try manifest("library/llama3.2/latest", [base, small])
    try manifest("me/coder/7b", [base, other])

    let models = OllamaModels.list(root: root)
    #expect(Set(models.map(\.name)) == ["llama3.2:latest", "me/coder:7b"])
    let llama = try #require(models.first { $0.name == "llama3.2:latest" })
    #expect(llama.uniqueBlobs == ["\(root)/blobs/sha256-\(String(repeating: "b", count: 64))"])
    #expect(llama.sharedBytes > 0)

    let category = DiskCategory(id: "models.local", group: "Local models", title: "Models", risk: .caution, whatYouLose: "x",
                                locations: [DiskLocation(root, .ollamaModels)])
    let item = try #require(DiskScanner().scan(category).items.first { $0.name.hasSuffix("llama3.2:latest") })
    let box = Box()
    let cleaner = DiskCleaner(allowedPaths: Set(DiskScanner().itemPaths(for: category.locations[0])), remove: { box.add($0.path) })
    let outcome = cleaner.clean([item])
    let removed = box.values
    #expect(outcome.cleaned.count == 1)
    #expect(removed.contains(llama.manifestPath))
    #expect(removed.contains { $0.hasSuffix(String(repeating: "b", count: 64)) })
    #expect(!removed.contains { $0.hasSuffix(String(repeating: "a", count: 64)) }) // shared base stays
}
