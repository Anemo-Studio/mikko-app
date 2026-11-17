import Foundation

/// A regenerable build/dependency folder inside a project (D-4).
public struct ArtifactRule: Sendable {
    public var name: String
    public var kind: String
    /// At least one of these must sit next to the folder for it to count.
    public var siblingMarkers: [String]
    /// Or this file must exist inside the folder.
    public var insideMarker: String?
    public var risk: RiskLevel

    public static let standard: [ArtifactRule] = {
        let js = ["package.json"]
        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"]
        func r(_ n: String, _ k: String, _ m: [String], inside: String? = nil, risk: RiskLevel = .safe) -> ArtifactRule {
            ArtifactRule(name: n, kind: k, siblingMarkers: m, insideMarker: inside, risk: risk)
        }
        return [
            r("node_modules", "Node dependencies", js),
            r(".next", "Next.js build", js), r(".nuxt", "Nuxt build", js), r(".turbo", "Turborepo cache", js),
            r(".svelte-kit", "SvelteKit build", js), r(".parcel-cache", "Parcel cache", js),
            r(".angular", "Angular cache", js), r(".expo", "Expo cache", js),
            r("dist", "Build output", js),
            r("build", "Build output", js + gradle + ["pubspec.yaml"]),
            r("target", "Rust/Maven build", ["Cargo.toml", "pom.xml"]),
            r("Pods", "CocoaPods dependencies", ["Podfile"]),
            r(".gradle", "Gradle project cache", gradle),
            r(".build", "SwiftPM build", ["Package.swift"]),
            r(".dart_tool", "Dart tool cache", ["pubspec.yaml"]),
            r("venv", "Python virtual environment", [], inside: "pyvenv.cfg", risk: .caution),
            r(".venv", "Python virtual environment", [], inside: "pyvenv.cfg", risk: .caution),
        ]
    }()
}

public struct ProjectArtifacts: Sendable, Identifiable {
    public var id: String { root }
    public var root: String
    public var name: String
    /// Latest change to the project's own files (not its artifacts).
    public var lastModified: Date?
    public var branch: String?
    /// The root is a git checkout. Artifacts outside git are never pre-selected.
    public var hasGit: Bool
    /// `.git` is a file: a linked worktree, typically created by an agent.
    public var isWorktree: Bool
    /// Only determined for worktrees. nil = unknown.
    public var hasUncommittedChanges: Bool?
    public var artifacts: [DiskItem]

    public var bytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }

    public func isActive(withinDays days: Int, now: Date = .now) -> Bool {
        guard let lastModified else { return true } // unknown → treat as active, the safe side
        return now.timeIntervalSince(lastModified) < Double(days) * 86_400
    }
}

public struct ProjectScanner: Sendable {
    public static let categoryID = "projects.artifacts"
    /// Names that are also used for hand-written source or committed output.
    public static let ambiguousNames: Set<String> = ["build", "dist", "target", "Pods"]

    public var rules: [ArtifactRule]
    public var maxDepth: Int
    public var exclusions: ExclusionList

    public init(rules: [ArtifactRule] = ArtifactRule.standard, maxDepth: Int = 6, exclusions: ExclusionList = .init()) {
        self.rules = rules; self.maxDepth = maxDepth; self.exclusions = exclusions
    }

    private static let skipNames: Set<String> = ["Library", "Applications", ".Trash", ".git", ".hg", ".svn"]

    /// The rule a folder satisfies right now, judged from the folder itself and its siblings.
    public static func matchingRule(forArtifactAt path: String, rules: [ArtifactRule] = ArtifactRule.standard) -> ArtifactRule? {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let rule = rules.first(where: { $0.name == name }) else { return nil }
        if let inside = rule.insideMarker, FileManager.default.fileExists(atPath: "\(path)/\(inside)") { return rule }
        return rule.siblingMarkers.contains { FileManager.default.fileExists(atPath: "\(dir)/\($0)") } ? rule : nil
    }

    /// Canonical folders with any folder nested inside another removed.
    static func normalizedFolders(_ folders: [String]) -> [String] {
        let real = Array(Set(folders.compactMap(PathCanon.real))).sorted()
        return real.filter { f in !real.contains { $0 != f && f.hasPrefix($0 + "/") } }
    }

    public func scan(folders: [String]) -> [ProjectArtifacts] {
        let fm = FileManager.default
        var byRoot: [String: [DiskItem]] = [:]
        var gitRoots = Set<String>()
        var queue: [(path: String, depth: Int, projectRoot: String?)] = Self.normalizedFolders(folders).map { ($0, 0, nil) }

        while let (dir, depth, inherited) = queue.popLast() {
            if Task.isCancelled { return [] }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let hasGit = names.contains(".git")
            let projectRoot = hasGit ? dir : inherited
            if hasGit { gitRoots.insert(dir) }
            let insideDotClaude = (dir as NSString).lastPathComponent == ".claude"

            for name in names {
                // Inside ".claude" only agent worktrees are projects; the rest is the agent's own data.
                if insideDotClaude, name != "worktrees" { continue }
                let path = "\(dir)/\(name)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                // Never follow symlinks out of the tree.
                if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { continue }
                if exclusions.excludes(path: path) { continue }

                if var rule = Self.matchingRule(forArtifactAt: path, rules: rules) {
                    var kind = rule.kind
                    if Self.ambiguousNames.contains(name) {
                        // "build" or "dist" may be hand-written or committed. Only git can tell.
                        let ignored = projectRoot.flatMap { GitInfo.isIgnored(path: path, root: $0) }
                        if ignored != true {
                            rule.risk = max(rule.risk, .caution)
                            kind += ignored == false ? " — tracked by git, may contain source" : " — could not confirm it is generated"
                        }
                    }
                    let url = URL(fileURLWithPath: path)
                    let bytes = DirectorySizer.allocatedSize(of: url)
                    guard bytes > 0, !Task.isCancelled else { continue }
                    let root = projectRoot ?? dir
                    let rel = path.dropFirst(root.count).drop { $0 == "/" }
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    byRoot[root, default: []].append(DiskItem(
                        categoryID: Self.categoryID, name: String(rel), path: path, bytes: bytes,
                        modified: modified, risk: rule.risk, detail: kind))
                    continue // never descend into an artifact
                }
                if Self.skipNames.contains(name) || (name.hasPrefix(".") && name != ".claude") { continue }
                if depth + 1 <= maxDepth { queue.append((path, depth + 1, projectRoot)) }
            }
        }

        let artifactNames = Set(rules.map(\.name))
        return byRoot.map { root, items in
            let git = GitInfo.read(root: root)
            return ProjectArtifacts(
                root: root, name: URL(fileURLWithPath: root).lastPathComponent,
                lastModified: Self.lastSourceChange(root: root, artifactNames: artifactNames),
                branch: git.branch, hasGit: gitRoots.contains(root), isWorktree: git.isWorktree,
                hasUncommittedChanges: git.isWorktree ? GitInfo.hasUncommittedChanges(root: root) : nil,
                artifacts: items.sorted { $0.bytes > $1.bytes })
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Newest change to the project's own files: git's bookkeeping plus a bounded walk of
    /// source files (top-level mtimes alone miss edits to nested files).
    static func lastSourceChange(root: String, artifactNames: Set<String>, maxEntries: Int = 6000, maxDepth: Int = 5) -> Date? {
        let fm = FileManager.default
        func mtime(_ p: String) -> Date? { (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date }
        var newest: Date?
        func consider(_ d: Date?) { if let d, d > (newest ?? .distantPast) { newest = d } }

        if let gitDir = GitInfo.gitDir(root: root) {
            for f in ["index", "HEAD", "logs/HEAD", "ORIG_HEAD"] { consider(mtime("\(gitDir)/\(f)")) }
        }
        var stack: [(String, Int)] = [(root, 0)]
        var seen = 0
        while let (dir, depth) = stack.popLast(), seen < maxEntries {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where !artifactNames.contains(name) && name != ".DS_Store" && name != ".git" {
                seen += 1
                let path = "\(dir)/\(name)"
                guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                consider(attrs[.modificationDate] as? Date)
                if attrs[.type] as? FileAttributeType == .typeDirectory, depth < maxDepth, !name.hasPrefix(".") {
                    stack.append((path, depth + 1))
                }
            }
        }
        return newest
    }
}

public enum GitInfo {
    /// The real git directory: `.git` itself, or what a worktree's `.git` file points to.
    public static func gitDir(root: String) -> String? {
        let dotGit = "\(root)/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : "\(root)/\(target)"
    }

    public static func read(root: String) -> (branch: String?, isWorktree: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: "\(root)/.git", isDirectory: &isDir) else { return (nil, false) }
        // A linked worktree's gitdir lives under ".git/worktrees/"; a submodule's does not.
        let dir = gitDir(root: root)
        let isWorktree = !isDir.boolValue && (dir?.contains("/worktrees/") ?? true)
        guard let dir, let head = try? String(contentsOfFile: "\(dir)/HEAD", encoding: .utf8) else { return (nil, isWorktree) }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        return (trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : String(trimmed.prefix(7)), isWorktree)
    }

    static var gitPath: String? {
        // /usr/bin/git is a shim that opens an install dialog when no developer tools exist.
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") { return "/Library/Developer/CommandLineTools/usr/bin/git" }
        if fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git") { return "/Applications/Xcode.app/Contents/Developer/usr/bin/git" }
        return ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first(where: fm.fileExists)
    }

    /// Runs git read-only: no index refresh, no repo-configured fsmonitor command, bounded time.
    public static func run(_ args: [String], root: String, timeout: TimeInterval = 5) -> (status: Int32, output: Data)? {
        guard let git = gitPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", root] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationReason == .exit else { return nil }
        return (p.terminationStatus, data)
    }

    /// nil when git could not be run — callers must treat unknown as "may have changes".
    public static func hasUncommittedChanges(root: String) -> Bool? {
        guard let r = run(["status", "--porcelain"], root: root), r.status == 0 else { return nil }
        return !r.output.isEmpty
    }

    /// true = ignored by git (generated), false = tracked or untracked-but-not-ignored, nil = unknown.
    public static func isIgnored(path: String, root: String) -> Bool? {
        guard let r = run(["check-ignore", "-q", path], root: root) else { return nil }
        return r.status == 0 ? true : r.status == 1 ? false : nil
    }
}
