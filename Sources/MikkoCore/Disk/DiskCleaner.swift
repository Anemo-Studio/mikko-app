import Foundation

public struct CleanOutcome: Sendable {
    public struct Failure: Sendable {
        public var item: DiskItem
        public var reason: String
        public init(item: DiskItem, reason: String) { self.item = item; self.reason = reason }
    }
    public var cleaned: [DiskItem] = []
    public var failures: [Failure] = []
    /// Rows whose files were already gone: nothing was done, the row should simply disappear.
    public var skipped: [DiskItem] = []
    public var bytesMoved: Int64 { cleaned.reduce(0) { $0 + $1.bytes } }
}

public enum PathCanon {
    /// Fully resolved path of something that exists, or nil.
    public static func real(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    public static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }
}

/// Moves reviewed items to the Trash (P-3). At the moment of the action each
/// item must still be exactly a path the scanner would produce right now:
/// a current catalog item, or a folder that still matches a project-artifact rule.
public struct DiskCleaner: Sendable {
    public var allowedPaths: Set<String>
    public var artifactRules: [ArtifactRule]
    public var exclusions: ExclusionList
    public var remove: @Sendable (URL) throws -> Void

    public init(allowedPaths: Set<String>, artifactRules: [ArtifactRule] = [], exclusions: ExclusionList = .init(),
                remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        // A symlink is never an item: resolving it would whitelist whatever it points at.
        self.allowedPaths = Set(allowedPaths.filter { !PathCanon.isSymlink($0) }.compactMap(PathCanon.real))
        self.artifactRules = artifactRules
        self.exclusions = exclusions
        self.remove = remove
    }

    /// Re-derives the allowed set from the catalog as it is on disk now.
    public init(categories: [DiskCategory], artifactRules: [ArtifactRule] = ArtifactRule.standard,
                exclusions: ExclusionList = .init()) {
        let scanner = DiskScanner(exclusions: exclusions)
        let paths = categories.filter { !exclusions.categoryIDs.contains($0.id) }
            .flatMap { c in c.locations.flatMap { scanner.itemPaths(for: $0, in: c) } }
        self.init(allowedPaths: Set(paths), artifactRules: artifactRules, exclusions: exclusions)
    }

    static let protectedNames: Set<String> = [".git", ".ssh", "Documents", "Desktop", "Downloads", "Library", "src"]

    /// Returns nil when the item may be removed, otherwise the reason it may not.
    public func refusal(for item: DiskItem) -> String? {
        guard let p = PathCanon.real(item.path) else { return "No longer exists" }
        if PathCanon.isSymlink(item.path) { return "Is a link to another location" }
        let home = PathCanon.real(NSHomeDirectory()) ?? NSHomeDirectory()
        let comps = p.split(separator: "/")
        if p == home || home.hasPrefix(p + "/") || comps.count < 3 { return "Too close to the home or root folder" }
        if let last = comps.last, Self.protectedNames.contains(String(last)) || last.hasPrefix(".env") {
            return "Protected name"
        }
        if exclusions.categoryIDs.contains(item.categoryID) { return "Category marked Never clean" }
        if exclusions.excludes(path: item.path) || exclusions.excludes(path: p) { return "Marked Never clean" }
        if item.categoryID == ProjectScanner.categoryID {
            guard ProjectScanner.matchingRule(forArtifactAt: p, rules: artifactRules) != nil else {
                return "No longer looks like a build or dependency folder"
            }
        } else if !allowedPaths.contains(p) {
            return "Outside known developer-tool locations"
        }
        return nil
    }

    /// The item's extra paths that are still its own: for an Ollama manifest, the blobs no other
    /// manifest references at this moment. Anything that cannot be confirmed is left alone.
    func currentlyUniqueExtras(of item: DiskItem) -> [String] {
        let manifests = "/manifests/"
        guard let r = item.path.range(of: manifests) else { return [] }
        let root = String(item.path[..<r.lowerBound])
        guard let model = OllamaModels.list(root: root).first(where: { $0.manifestPath == item.path }) else { return [] }
        let stillUnique = Set(model.uniqueBlobs)
        return item.extraPaths.filter { stillUnique.contains($0) && $0.hasPrefix(root + "/blobs/sha256-") && !PathCanon.isSymlink($0) }
    }

    public func clean(_ items: [DiskItem]) -> CleanOutcome {
        var outcome = CleanOutcome()
        for item in items {
            guard FileManager.default.fileExists(atPath: item.path) else {
                outcome.skipped.append(item)
                continue
            }
            if let reason = refusal(for: item) {
                outcome.failures.append(.init(item: item, reason: reason))
                continue
            }
            do {
                // Extra files (an Ollama model's blobs) go only if, right now, nothing else uses them.
                let extras = item.extraPaths.isEmpty ? [] : currentlyUniqueExtras(of: item)
                try remove(URL(fileURLWithPath: item.path))
                for e in extras { try? remove(URL(fileURLWithPath: e)) }
                outcome.cleaned.append(item)
            } catch {
                outcome.failures.append(.init(item: item, reason: error.localizedDescription))
            }
        }
        return outcome
    }
}
