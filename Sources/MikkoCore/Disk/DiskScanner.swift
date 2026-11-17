import Foundation

public struct DiskItem: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var categoryID: String
    public var name: String
    public var path: String
    public var bytes: Int64
    public var modified: Date?
    public var risk: RiskLevel
    /// Optional extra context, e.g. what kind of artifact this is.
    public var detail: String?
    /// Files that belong to this item besides `path` (an Ollama model's own blobs). Re-checked
    /// at clean time; never anything shared with another item.
    public var extraPaths: [String] = []

    public init(categoryID: String, name: String, path: String, bytes: Int64, modified: Date?,
                risk: RiskLevel, detail: String? = nil, extraPaths: [String] = []) {
        self.categoryID = categoryID; self.name = name; self.path = path; self.bytes = bytes
        self.modified = modified; self.risk = risk; self.detail = detail; self.extraPaths = extraPaths
    }
}

public struct DiskCategoryResult: Sendable, Identifiable {
    public var category: DiskCategory
    public var items: [DiskItem]
    public var id: String { category.id }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// D-7: paths, projects or whole categories the user marked "Never clean".
public struct ExclusionList: Sendable, Codable, Equatable {
    public var paths: Set<String> = []
    public var categoryIDs: Set<String> = []
    public init(paths: Set<String> = [], categoryIDs: Set<String> = []) {
        self.paths = paths; self.categoryIDs = categoryIDs
    }

    public func excludes(path: String) -> Bool {
        guard !paths.isEmpty else { return false }
        // Compare resolved forms too, so "/var/x" and "/private/var/x" are the same folder.
        let candidates = Set([path, PathCanon.real(path)].compactMap { $0 })
        let entries = Set(paths.flatMap { [$0, PathCanon.real($0)].compactMap { $0 } })
        return candidates.contains { c in
            entries.contains { c == $0 || c.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }
}

public struct DiskScanner: Sendable {
    public var exclusions: ExclusionList
    /// Temp folders newer than this are assumed to belong to a session that may still be in use.
    public var agentTempMinAge: TimeInterval = 24 * 3600
    public init(exclusions: ExclusionList = .init()) { self.exclusions = exclusions }

    /// Item paths for a location, with category-specific safety filters applied.
    public func itemPaths(for location: DiskLocation, in category: DiskCategory) -> [String] {
        let paths = itemPaths(for: location).filter { !exclusions.excludes(path: $0) }
        guard category.id == DiskCatalog.agentTempID else { return paths }
        // Never offer the temp folder of a session that is running or was used recently.
        let live = Set(ClaudeSessions.live().map(\.sessionID))
        let cutoff = Date().addingTimeInterval(-agentTempMinAge)
        return paths.filter { path in
            guard !live.contains((path as NSString).lastPathComponent) else { return false }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return (modified ?? .now) < cutoff
        }
    }

    /// Item paths a location expands to. Missing locations yield nothing.
    public func itemPaths(for location: DiskLocation) -> [String] {
        let fm = FileManager.default
        switch location.mode {
        case .whole:
            return fm.fileExists(atPath: location.path) ? [location.path] : []
        case .children(let depth):
            var level = [location.path]
            for _ in 0..<max(depth, 1) {
                level = level.flatMap { dir -> [String] in
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                          let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
                    return names.filter { $0 != ".DS_Store" }.map { "\(dir)/\($0)" }
                }
            }
            return level
        case .ollamaModels:
            return OllamaModels.list(root: location.path).map(\.manifestPath)
        }
    }

    public func scan(_ category: DiskCategory) -> DiskCategoryResult {
        var items: [DiskItem] = []
        for location in category.locations {
            if case .ollamaModels = location.mode {
                for m in OllamaModels.list(root: location.path) where !exclusions.excludes(path: m.manifestPath) {
                    let bytes = m.uniqueBytes + OllamaModels.size(m.manifestPath)
                    guard bytes > 0 else { continue }
                    items.append(DiskItem(categoryID: category.id, name: "Ollama — \(m.name)", path: m.manifestPath, bytes: bytes,
                                          modified: m.modified, risk: category.risk,
                                          detail: m.sharedBytes > 0 ? "Another \(ByteFormat.string(m.sharedBytes)) is shared with other models and stays." : nil,
                                          extraPaths: m.uniqueBlobs))
                }
                continue
            }
            for path in itemPaths(for: location, in: category) {
                if Task.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                let bytes = DirectorySizer.allocatedSize(of: url)
                guard bytes > 0 else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                items.append(DiskItem(categoryID: category.id, name: Self.displayName(path, location: location),
                                      path: path, bytes: bytes, modified: modified, risk: category.risk))
            }
        }
        items.sort { $0.bytes > $1.bytes }
        return DiskCategoryResult(category: category, items: items)
    }

    /// D-1: results arrive category by category so the UI fills in progressively.
    public func scan(_ categories: [DiskCategory], concurrency: Int = 4) -> AsyncStream<DiskCategoryResult> {
        let active = categories.filter { !exclusions.categoryIDs.contains($0.id) }
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: DiskCategoryResult.self) { group in
                    var pending = active.makeIterator()
                    var running = 0
                    while running < concurrency, let c = pending.next() {
                        _ = group.addTaskUnlessCancelled { self.scan(c) }
                        running += 1
                    }
                    for await result in group {
                        if Task.isCancelled { break }
                        if !result.items.isEmpty { continuation.yield(result) }
                        if let c = pending.next() { _ = group.addTaskUnlessCancelled { self.scan(c) } }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func displayName(_ path: String, location: DiskLocation) -> String {
        let home = NSHomeDirectory()
        switch location.mode {
        case .whole, .ollamaModels:
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        case .children:
            let rel = path.dropFirst(location.path.count).drop { $0 == "/" }
            // Xcode appends a hash to DerivedData folders: "shop-abcdefghijklmnopqrstuvwxyzab".
            if location.path.hasSuffix("/DerivedData"), let dash = rel.lastIndex(of: "-"),
               rel.distance(from: dash, to: rel.endIndex) == 29 {
                return String(rel[..<dash])
            }
            return String(rel)
        }
    }
}

extension DiskCategory {
    /// D-3: the first of this category's tools that is running, given process names and bundle IDs.
    public func runningBlocker(among markers: Set<String>) -> String? {
        blockedBy.first(where: markers.contains)
    }
}
