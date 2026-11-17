import AppKit
import MikkoCore
import Observation

struct CleanSummary {
    var bytesMoved: Int64
    var count: Int
    var failures: [CleanOutcome.Failure]
    var blocked: [String] = []
    var trashEmptied = false
}

@Observable
final class DiskModel {
    private(set) var results: [DiskCategoryResult] = []
    private(set) var projects: [ProjectArtifacts] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var isCleaning = false
    var selection: Set<String> = []
    /// Items the person unticked: a rescan must not tick them again.
    private var userDeselected: Set<String> = []
    var lastClean: CleanSummary?
    var trashMessage: String?
    /// Process names and bundle IDs of running tools, supplied by the Running module.
    var toolMarkers: () -> Set<String> = { [] }
    /// Project roots that have something running in them right now (D-4).
    var busyRoots: () -> Set<String> = { [] }
    private(set) var history: [CleanHistoryEntry] = []

    var exclusions: ExclusionList { didSet { saveExclusions() } }
    var projectFolders: [String] { didSet { UserDefaults.standard.set(projectFolders, forKey: "projectFolders") } }
    var activeDays: Int {
        let d = UserDefaults.standard.integer(forKey: "activeProjectDays")
        return d > 0 ? d : 14
    }

    private let catalog = DiskCatalog.standard()
    private let database: AppDatabase?
    private var scanTask: Task<Void, Never>?

    init() {
        exclusions = (UserDefaults.standard.data(forKey: "exclusions"))
            .flatMap { try? JSONDecoder().decode(ExclusionList.self, from: $0) } ?? .init()
        projectFolders = UserDefaults.standard.stringArray(forKey: "projectFolders") ?? []
        do { database = try AppDatabase.openDefault() } catch {
            database = nil
            NSLog("mikko: history database unavailable: %@", String(describing: error))
        }
        history = (try? database?.cleanHistory()) ?? []
    }

    private func saveExclusions() {
        if let data = try? JSONEncoder().encode(exclusions) { UserDefaults.standard.set(data, forKey: "exclusions") }
    }

    func categoryTitle(_ id: String) -> String {
        catalog.first { $0.id == id }.map { "\($0.group) — \($0.title)" } ?? id
    }

    // MARK: Derived

    var allItems: [DiskItem] { results.flatMap(\.items) + projects.flatMap(\.artifacts) }
    var reclaimable: Int64 { allItems.reduce(0) { $0 + $1.bytes } }
    var safeReclaimable: Int64 { bytes(for: .safe) }
    var selectedItems: [DiskItem] { allItems.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func bytes(for risk: RiskLevel) -> Int64 {
        results.filter { $0.category.risk == risk }.reduce(0) { $0 + $1.bytes }
            + projects.flatMap(\.artifacts).filter { self.risk(of: $0) == risk }.reduce(0) { $0 + $1.bytes }
    }

    /// A dirty (or unknown-state) agent worktree makes its artifacts Risky (D-4).
    func risk(of item: DiskItem) -> RiskLevel {
        if let p = projects.first(where: { $0.artifacts.contains(item) }), p.isWorktree, p.hasUncommittedChanges != false {
            return .risky
        }
        return item.risk
    }

    /// D-3: a running tool that makes cleaning this category unsafe right now.
    func blocker(for category: DiskCategory) -> String? {
        guard !category.blockedBy.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.bundleIdentifier.map(category.blockedBy.contains) ?? false }) {
            return app.localizedName ?? app.bundleIdentifier
        }
        return category.runningBlocker(among: toolMarkers())
    }

    func isBusy(_ project: ProjectArtifacts) -> Bool {
        busyRoots().contains { $0 == project.root || $0.hasPrefix(project.root + "/") || project.root.hasPrefix($0 + "/") }
    }

    /// Pre-selected only when clearly safe: a git project, untouched for a while, nothing running in it.
    func preselects(_ project: ProjectArtifacts) -> Bool {
        project.hasGit && !project.isActive(withinDays: activeDays) && !isBusy(project)
    }

    // MARK: Scan

    func scan() {
        scanTask?.cancel()
        isScanning = true
        results = []
        projects = []
        selection = []
        lastClean = nil
        let exclusions = exclusions, folders = projectFolders, catalog = catalog
        scanTask = Task {
            // A child task: cancelling the scan cancels the project walk too.
            async let found = Self.scanProjects(folders: folders, exclusions: exclusions)
            for await result in DiskScanner(exclusions: exclusions).scan(catalog) {
                if Task.isCancelled { return }
                insert(result)
            }
            let projects = await found
            if Task.isCancelled { return }
            self.projects = projects
            for p in projects where preselects(p) {
                for a in p.artifacts where risk(of: a).selectedByDefault && !userDeselected.contains(a.id) {
                    selection.insert(a.id)
                }
            }
            isScanning = false
            hasScanned = true
        }
    }

    @concurrent
    private nonisolated static func scanProjects(folders: [String], exclusions: ExclusionList) async -> [ProjectArtifacts] {
        ProjectScanner(exclusions: exclusions).scan(folders: folders)
    }

    private func insert(_ result: DiskCategoryResult) {
        let idx = results.firstIndex { $0.bytes < result.bytes } ?? results.endIndex
        results.insert(result, at: idx)
        if result.category.risk.selectedByDefault, blocker(for: result.category) == nil {
            selection.formUnion(result.items.map(\.id).filter { !userDeselected.contains($0) })
        }
    }

    // MARK: Selection

    func toggle(_ items: [DiskItem]) {
        let ids = Set(items.map(\.id))
        if ids.isSubset(of: selection) {
            selection.subtract(ids)
            userDeselected.formUnion(ids)
        } else {
            selection.formUnion(ids)
            userDeselected.subtract(ids)
        }
    }

    func select(_ ids: [String]) { selection.formUnion(ids); userDeselected.subtract(ids) }
    func deselect(_ ids: [String]) { selection.subtract(ids); userDeselected.formUnion(ids) }

    func neverClean(categoryID: String) {
        exclusions.categoryIDs.insert(categoryID)
        let gone = Set(results.first { $0.id == categoryID }?.items.map(\.id) ?? [])
        selection.subtract(gone)
        results.removeAll { $0.id == categoryID }
    }

    func removeProjectFolder(_ folder: String) {
        projectFolders.removeAll { $0 == folder }
        let gone = projects.filter { $0.root == folder || $0.root.hasPrefix(folder + "/") }
        selection.subtract(gone.flatMap { $0.artifacts.map(\.id) })
        projects.removeAll { p in gone.contains { $0.root == p.root } }
    }

    func neverClean(path: String) {
        exclusions.paths.insert(path)
        selection = selection.filter { !exclusions.excludes(path: $0) }
        results = results.compactMap { r in
            var r = r
            r.items.removeAll { exclusions.excludes(path: $0.path) }
            return r.items.isEmpty ? nil : r
        }
        projects = projects.compactMap { p in
            var p = p
            p.artifacts.removeAll { exclusions.excludes(path: $0.path) }
            return p.artifacts.isEmpty ? nil : p
        }
    }

    // MARK: Clean

    /// `includeRisky: false` leaves Risky items selected but untouched (D-3: they need their own yes).
    func cleanSelected(includeRisky: Bool) {
        guard !isCleaning else { return }
        // Re-check running tools now, not at scan time.
        var blocked: [String] = []
        let blockedCategories = Set(results.compactMap { r -> String? in
            guard let b = blocker(for: r.category) else { return nil }
            if r.items.contains(where: { selection.contains($0.id) }) { blocked.append("\(r.category.title) (\(b) is running)") }
            return r.id
        })
        let busyArtifacts = Set(projects.filter(isBusy).flatMap { $0.artifacts.map(\.id) })
        let items = selectedItems.filter {
            !blockedCategories.contains($0.categoryID) && !busyArtifacts.contains($0.id)
                && (includeRisky || risk(of: $0) != .risky)
        }
        if selectedItems.contains(where: { busyArtifacts.contains($0.id) }) { blocked.append("projects with something still running") }
        guard !items.isEmpty else {
            lastClean = CleanSummary(bytesMoved: 0, count: 0, failures: [], blocked: blocked)
            return
        }
        isCleaning = true
        let catalog = catalog, exclusions = exclusions
        let titles = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, "\($0.group) — \($0.title)") })
        let projectNames = Dictionary(projects.flatMap { p in p.artifacts.map { ($0.id, p.name) } }, uniquingKeysWith: { a, _ in a })
        let database = database
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                // The cleaner re-derives what is allowed from the disk as it is right now.
                DiskCleaner(categories: catalog, exclusions: exclusions).clean(items)
            }.value
            try? database?.recordCleaned(outcome.cleaned) {
                titles[$0.categoryID] ?? "Project — \(projectNames[$0.id] ?? "artifacts")"
            }
            history = (try? database?.cleanHistory()) ?? history

            let gone = Set((outcome.cleaned + outcome.skipped).map(\.id))
            selection.subtract(gone)
            results = results.compactMap { r in
                var r = r
                r.items.removeAll { gone.contains($0.id) }
                return r.items.isEmpty ? nil : r
            }
            projects = projects.compactMap { p in
                var p = p
                p.artifacts.removeAll { gone.contains($0.id) }
                return p.artifacts.isEmpty ? nil : p
            }
            lastClean = CleanSummary(bytesMoved: outcome.bytesMoved, count: outcome.cleaned.count,
                                     failures: outcome.failures, blocked: blocked)
            isCleaning = false
        }
    }

    /// Asks Finder to empty the whole Trash. Irreversible, so the view confirms first.
    func emptyTrash() {
        trashMessage = nil
        Task {
            let ok = await Task.detached { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "tell application \"Finder\" to empty trash"]
                p.standardError = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }.value
            if ok {
                lastClean?.trashEmptied = true
            } else {
                trashMessage = "The Trash could not be emptied. Allow mikko to control Finder in System Settings › Privacy & Security › Automation, or empty it from Finder."
            }
        }
    }
}
