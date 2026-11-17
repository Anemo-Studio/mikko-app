import MikkoCore
import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("exportTools") private var exportTools = true
    @AppStorage("exportDiffs") private var exportDiffs = true
    @AppStorage("exportMask") private var exportMask = true

    private var model: SessionsModel { app.sessionsModel }

    var body: some View {
        @Bindable var model = app.sessionsModel
        HSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if model.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
                    hitList
                } else {
                    sessionList
                }
                if model.isIndexing {
                    Divider()
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.indexProgress.total > 0 ? "Indexing \(model.indexProgress.done) of \(model.indexProgress.total) sessions…" : "Looking for sessions…")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 320, idealWidth: 400)
            Group {
                if let row = model.selected {
                    SessionDetail(row: row)
                } else {
                    ContentUnavailableView("Select a session", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("mikko only reads the files your agents already write. Nothing in them is changed."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $model.searchText, prompt: "Search every session")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Section("Format") {
                        ForEach(SessionExport.Format.allCases, id: \.self) { format in
                            Button("Export as \(format.rawValue.uppercased() == "MARKDOWN" ? "Markdown" : format.rawValue.uppercased())…") {
                                if let row = model.selected {
                                    model.export([row], format: format, options: .init(includeTools: exportTools, includeDiffs: exportDiffs, maskSecrets: exportMask))
                                }
                            }
                        }
                    }
                    Section("Include") {
                        Toggle("Tool calls", isOn: $exportTools)
                        Toggle("File diffs", isOn: $exportDiffs)
                        Toggle("Hide passwords and keys", isOn: $exportMask)
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.selected == nil)
                Button { model.index(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.isIndexing)
            }
        }
        .onAppear { model.index() }
    }

    private var filterBar: some View {
        @Bindable var model = app.sessionsModel
        // One control instead of three; the summary says what is being shown.
        return HStack(spacing: 8) {
            Text(filterSummary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Menu {
                Picker("Agent", selection: $model.filter.agent) {
                    Text("All agents").tag(AgentTool?.none)
                    ForEach(AgentTool.allCases, id: \.self) { Text($0.displayName).tag(AgentTool?.some($0)) }
                }
                Picker("Project", selection: $model.filter.project) {
                    Text("All projects").tag(String?.none)
                    ForEach(model.projects, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Divider()
                Toggle("Only with file changes", isOn: $model.filter.onlyFileChanges)
                Toggle("Only with API errors or aborted turns", isOn: $model.filter.onlyErrors)
                if !model.searchText.isEmpty {
                    Divider()
                    Picker("Search in", selection: $model.searchKind) {
                        Text("Everything").tag(SearchKind?.none)
                        Text("My messages").tag(SearchKind?.some(.user))
                        Text("Commands").tag(SearchKind?.some(.command))
                        Text("File paths").tag(SearchKind?.some(.file))
                    }
                }
                if isFiltered {
                    Divider()
                    Button("Show Everything") { model.filter = SessionFilter() }
                }
            } label: {
                Label("Filter", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var isFiltered: Bool {
        let f = model.filter
        return f.agent != nil || f.project != nil || f.onlyErrors || f.onlyFileChanges || f.from != nil
    }

    private var filterSummary: String {
        let f = model.filter
        var parts: [String] = []
        if let p = f.project { parts.append(p) }
        if let a = f.agent { parts.append(a.displayName) }
        if f.onlyFileChanges { parts.append("with file changes") }
        if f.onlyErrors { parts.append("with errors") }
        return parts.isEmpty ? "\(model.rows.count) sessions" : "\(model.rows.count) sessions · " + parts.joined(separator: ", ")
    }

    private var sessionList: some View {
        @Bindable var model = app.sessionsModel
        return List(selection: $model.selection) {
            // Grouped by when, so the eye lands on "today" instead of scanning dates.
            ForEach(dayGroups(model.rows), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in sessionRow(row).tag(row.path) }
                }
            }
        }
        .overlay {
            if model.rows.isEmpty, !model.isIndexing { ContentUnavailableView("No sessions found", systemImage: "tray") }
        }
    }

    private func dayGroups(_ rows: [SessionRow]) -> [(title: String, rows: [SessionRow])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func bucket(_ r: SessionRow) -> (Int, String) {
            if r.pinned { return (0, "Pinned") }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: r.started), to: today).day ?? 0
            if days <= 0 { return (1, "Today") }
            if days == 1 { return (2, "Yesterday") }
            if days < 7 { return (3, "Earlier this week") }
            if days < 31 { return (4, "This month") }
            return (5, "Older")
        }
        return Dictionary(grouping: rows) { bucket($0).0 }.sorted { $0.key < $1.key }
            .map { (title: bucket($0.value[0]).1, rows: $0.value) }
    }

    private func sessionRow(_ row: SessionRow) -> some View {
        @Bindable var model = app.sessionsModel
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                Text("\(row.project) · \(row.started.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(costText(row)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help("\(row.agent.displayName) · \(row.started.formatted(date: .abbreviated, time: .shortened)) · \(row.messages) messages\(row.hasErrors ? " · had API errors" : "")")
        .contextMenu {
            Button("Copy Resume Command") { model.copyResume(row) }
            Button(row.pinned ? "Unpin" : "Pin") { model.togglePin(row) }
            Button("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
        }
    }

    private var hitList: some View {
        List(model.hits) { hit in
            Button { model.open(hit) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(model.title(for: hit.path)).font(.body.weight(.medium)).lineLimit(1)
                        Spacer()
                        Tag(hitLabel(hit.kind), color: .secondary)
                    }
                    highlighted(hit.snippet).font(.callout).lineLimit(3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay { if model.hits.isEmpty { ContentUnavailableView.search(text: model.searchText) } }
    }

    private func hitLabel(_ k: SearchKind) -> String {
        switch k {
        case .user: "You"
        case .assistant: "Agent"
        case .command: "Command"
        case .file: "File"
        }
    }

    /// The index marks matches with ⟦ ⟧; show them bold.
    private func highlighted(_ snippet: String) -> Text {
        var out = Text("")
        var rest = Substring(snippet.replacingOccurrences(of: "\n", with: " "))
        while let open = rest.range(of: "⟦") {
            out = out + Text(rest[..<open.lowerBound]).foregroundStyle(.secondary)
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "⟧") else { break }
            out = out + Text(rest[..<close.lowerBound]).bold()
            rest = rest[close.upperBound...]
        }
        return out + Text(rest).foregroundStyle(.secondary)
    }
}

func costText(_ row: SessionRow) -> String {
    if row.tokens == 0 { return "–" }
    return String(format: "$%.2f", row.cost) + (row.hasUnpriced ? "+" : "")
}

private struct SessionDetail: View {
    @Environment(AppModel.self) private var app
    let row: SessionRow
    @State private var note = ""
    @State private var cursor = 0

    private var model: SessionsModel { app.sessionsModel }

    var body: some View {
        // MCP servers belong to a live session and end with it; they are not "left behind".
        let running = app.runningModel.items.filter { $0.sessionID == row.sessionID && $0.kind != .agent && $0.kind != .mcp }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.title).font(.title3.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                Text("\(row.agent.displayName) · \(row.project) · \(row.started.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("\(row.branch.map { "Branch \($0) · " } ?? "")\(DurationFormat.short(row.duration)) long · \(row.messages) messages · \(row.models.joined(separator: ", "))")
                HStack(spacing: 12) {
                    Text("\(row.filesChanged) files changed")
                    Text("\(costText(row)) at API prices")
                        .help(row.hasUnpriced ? "A lower bound: a model has no known price, or the agent did not record all of a subagent's usage. This is list price, not a bill."
                              : "What these tokens would cost at API list prices. Not a bill.")
                }
                .font(.caption).foregroundStyle(.secondary)
                if !running.isEmpty {
                    HStack {
                        Label("This session left \(running.count) thing\(running.count == 1 ? "" : "s") running: \(running.map(\.title).joined(separator: ", "))", systemImage: "bolt.horizontal")
                        Spacer()
                        Button("Stop") { app.runningModel.requestStop(running) }
                        Button("Show") { app.select(.running) }
                    }
                    .padding(8).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if let m = model.exportMessage { Label(m, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if !row.originalExists {
                    Label("The original transcript has been deleted; only the search index remains.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Menu("Resume") {
                        Button("Copy Command") { model.copyResume(row) }
                        Button("Open in Terminal") { model.resumeInTerminal(row) }
                    }
                    .fixedSize()
                    Menu("Jump To") {
                        Button("Next File Change") { jump(to: .fileChange) }.disabled(!model.transcript.contains { $0.kind == .fileChange })
                        Button("Next Error") { jump(error: true) }.disabled(!model.transcript.contains(where: \.isError))
                    }
                    .fixedSize()
                    Button(row.pinned ? "Unpin" : "Pin") { model.togglePin(row) }
                    Spacer()
                    TextField("Add a note", text: $note).textFieldStyle(.plain).foregroundStyle(.secondary).frame(maxWidth: 200)
                        .onSubmit { model.setNote(note, for: row) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.transcript) { EntryView(entry: $0).id($0.id) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay { if model.isLoadingTranscript { ProgressView() } }
                .onChange(of: cursor) { _, id in withAnimation { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: model.transcript.count) { _, _ in scrollToHit(proxy) }
                .onChange(of: model.jumpToLine) { _, _ in scrollToHit(proxy) } // a hit in the session already open
            }
        }
        .onAppear { note = row.note ?? "" }
        .onChange(of: row.path) { _, _ in note = row.note ?? ""; cursor = 0 }
    }

    private func scrollToHit(_ proxy: ScrollViewProxy) {
        guard let line = model.jumpToLine, let e = model.transcript.first(where: { $0.line >= line }) else { return }
        proxy.scrollTo(e.id, anchor: .top)
        model.jumpToLine = nil
    }

    private func jump(to kind: TranscriptEntry.Kind? = nil, error: Bool = false) {
        let matches = model.transcript.filter { error ? $0.isError : $0.kind == kind }
        guard let next = matches.first(where: { $0.id > cursor }) ?? matches.first else { return }
        cursor = next.id
    }
}

private struct EntryView: View {
    let entry: TranscriptEntry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(entry.text).textSelection(.enabled)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(entry.text).textSelection(.enabled)
            }
        case .note:
            Label("\(entry.title) \(entry.text)", systemImage: entry.isError ? "exclamationmark.triangle" : "info.circle")
                .font(.caption).foregroundStyle(entry.isError ? .orange : .secondary)
        case .tool, .toolResult, .fileChange:
            DisclosureGroup(isExpanded: $expanded) {
                Text(entry.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            } label: {
                Label {
                    Text(label).font(.callout).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: icon).foregroundStyle(entry.isError ? .red : .secondary)
                }
            }
        }
    }

    private var icon: String {
        switch entry.kind {
        case .tool: "terminal"
        case .fileChange: "doc.badge.gearshape"
        default: entry.isError ? "xmark.octagon" : "arrow.turn.down.right"
        }
    }

    private var label: String {
        switch entry.kind {
        case .tool: "\(entry.title): \(entry.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")"
        case .fileChange: "Changed \((entry.title as NSString).lastPathComponent)"
        default: entry.isError ? "Error" : "Result"
        }
    }
}
