import AppKit
import MikkoCore
import Observation

@Observable
final class SessionsModel {
    private(set) var rows: [SessionRow] = []
    private(set) var projects: [String] = []
    private(set) var hits: [SearchHit] = []
    private(set) var isIndexing = false
    private(set) var indexProgress: (done: Int, total: Int) = (0, 0)
    private(set) var transcript: [TranscriptEntry] = []
    private(set) var isLoadingTranscript = false
    var filter = SessionFilter() { didSet { reload() } }
    var searchText = "" { didSet { runSearch() } }
    var searchKind: SearchKind? { didSet { runSearch() } }
    var selection: String? { didSet { if selection != oldValue { loadTranscript() } } }
    /// Transcript line to scroll to after opening a search hit.
    var jumpToLine: Int?

    let database: AppDatabase?
    private var searchTask: Task<Void, Never>?
    private var lastIndexed: Date?
    var exportMessage: String?

    init() { database = try? AppDatabase.openDefault() }

    var selected: SessionRow? { selection.flatMap { p in rows.first { $0.path == p } ?? (try? database?.session(path: p)) } }

    func reload() {
        guard let database else { return }
        rows = (try? database.sessions(filter)) ?? []
        projects = (try? database.projects()) ?? []
    }

    /// Indexes new and changed transcripts in the background. Originals are only ever read.
    func index(force: Bool = false) {
        // Unchanged transcripts cost one stat each, so re-checking whenever the screen appears is cheap.
        guard let database, !isIndexing, force || lastIndexed.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
        lastIndexed = .now
        isIndexing = true
        reload()
        Task {
            let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
                Task { @MainActor in self?.indexProgress = (done, total) }
            }
            _ = await Task.detached(priority: .utility) {
                SessionIndexer().index(into: database, progress: report)
            }.value
            isIndexing = false
            reload()
            runSearch()
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard let database, text.count >= 2 else { hits = []; return }
        let kind = searchKind
        searchTask = Task {
            // Wait for a pause in typing, so only the query the person settles on is run.
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { (try? database.search(text, kind: kind)) ?? [] }.value
            if !Task.isCancelled { hits = found }
        }
    }

    /// Selects a session by its agent's session id. False when it is not indexed (yet).
    @discardableResult
    func show(sessionID: String) -> Bool {
        guard let row = rows.first(where: { $0.sessionID == sessionID }) ?? (try? database?.session(id: sessionID)) else { return false }
        selection = row.path
        return true
    }

    func open(_ hit: SearchHit) {
        jumpToLine = hit.line
        selection = hit.path
    }

    private func loadTranscript() {
        transcript = []
        isLoadingTranscript = false
        guard let row = selected else { return }
        isLoadingTranscript = true
        let path = row.path
        Task {
            let entries = await Task.detached(priority: .userInitiated) { SessionActions.transcript(row) }.value
            guard selection == path else { return }
            transcript = entries
            isLoadingTranscript = false
        }
    }

    func title(for path: String) -> String { rows.first { $0.path == path }?.title ?? ((try? database?.session(path: path))?.title ?? "Session") }

    func togglePin(_ row: SessionRow) {
        try? database?.setPinned(!row.pinned, path: row.path)
        reload()
    }

    func setNote(_ note: String, for row: SessionRow) {
        try? database?.setNote(note.isEmpty ? nil : note, path: row.path)
        reload()
    }

    func copyResume(_ row: SessionRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SessionActions.resumeCommand(row), forType: .string)
    }

    /// Opens Terminal in the project folder with the resume command typed in.
    func resumeInTerminal(_ row: SessionRow) {
        let command = SessionActions.resumeCommand(row).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        Task.detached {
            _ = Subprocess.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to activate",
                                                        "-e", "tell application \"Terminal\" to do script \"\(command)\""], timeout: 20)
        }
    }

    func export(_ rows: [SessionRow], format: SessionExport.Format, options: SessionExport.Options) {
        guard !rows.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(rows.count) exported session\(rows.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        exportMessage = nil
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
                var failures: [String] = []
                for row in rows {
                    guard row.originalExists || row.readsFromCopy else { failures.append("\(row.title.prefix(40)): the transcript no longer exists"); continue }
                    let text = SessionExport.render(row, entries: SessionActions.transcript(row), format: format, options: options)
                    // Never replace a file that is already there.
                    var url = dir.appendingPathComponent(SessionExport.fileName(for: row, format: format))
                    var n = 2
                    while FileManager.default.fileExists(atPath: url.path) {
                        let base = SessionExport.fileName(for: row, format: format)
                        url = dir.appendingPathComponent("\((base as NSString).deletingPathExtension) \(n).\(format.fileExtension)")
                        n += 1
                    }
                    do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { failures.append("\(row.title.prefix(40)): \(error.localizedDescription)") }
                }
                return failures
            }.value
            if failures.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
            else { exportMessage = "Not exported — " + failures.joined(separator: "; ") }
        }
    }
}

extension RateLimitWindow {
    var rowID: String { "\(provider)|\(window)" }
}

@Observable
final class UsageModel {
    private(set) var today = UsageTotals()
    private(set) var week = UsageTotals()
    private(set) var month = UsageTotals()
    private(set) var byDay: [UsageSlice] = []
    private(set) var byModel: [UsageSlice] = []
    private(set) var byProject: [UsageSlice] = []
    private(set) var byAgentWeek: [UsageSlice] = []
    private(set) var claudeWeek = UsageTotals()
    private(set) var top: [SessionRow] = []
    private(set) var limits: [RateLimitWindow] = []
    private(set) var budgetSpend: [String: Double] = [:]
    var budgets: [Budget] { didSet { save(); reload() } }

    private let database: AppDatabase?

    init(database: AppDatabase?) {
        self.database = database
        budgets = UserDefaults.standard.data(forKey: "budgets").flatMap { try? JSONDecoder().decode([Budget].self, from: $0) } ?? []
    }

    private func save() { if let d = try? JSONEncoder().encode(budgets) { UserDefaults.standard.set(d, forKey: "budgets") } }

    func reload() {
        guard let db = database else { return }
        today = (try? db.usageTotals(fromDay: UsageDays.daysAgo(0))) ?? .init()
        week = (try? db.usageTotals(fromDay: UsageDays.daysAgo(6))) ?? .init()
        month = (try? db.usageTotals(fromDay: UsageDays.daysAgo(29))) ?? .init()
        byDay = (try? db.usage(by: .day, fromDay: UsageDays.daysAgo(29))) ?? []
        byModel = (try? db.usage(by: .model, fromDay: UsageDays.daysAgo(29))) ?? []
        byProject = (try? db.usage(by: .project, fromDay: UsageDays.daysAgo(29))) ?? []
        byAgentWeek = (try? db.usage(by: .agent, fromDay: UsageDays.daysAgo(6))) ?? []
        claudeWeek = (try? db.usageTotals(fromDay: UsageDays.daysAgo(6), agent: .claudeCode)) ?? .init()
        top = (try? db.topSessions(fromDay: UsageDays.daysAgo(6))) ?? []
        limits = (try? db.rateLimits()) ?? []
        budgetSpend = Dictionary(uniqueKeysWithValues: budgets.map { b in
            (b.id, (try? db.usageTotals(fromDay: b.fromDay(), project: b.project))?.cost ?? 0)
        })
    }

    var overBudget: [Budget] { budgets.filter { (budgetSpend[$0.id] ?? 0) > $0.limitUSD } }
}
