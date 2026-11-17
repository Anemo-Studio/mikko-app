import MikkoCore
import SwiftUI

/// What is running, with the noise folded away: the things a developer started are listed,
/// background groups (agent sessions, their MCP servers, other apps) are one line each.
struct RunningView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("showSystemListeners") private var showSystem = false
    @AppStorage("runningGroupByProject") private var byProject = false
    @AppStorage("runningExpandedGroups") private var expandedRaw = ""
    @State private var confirming: RunningItem?
    @State private var showStopIdle = false
    @State private var openItem: String?

    private var model: RunningModel { app.runningModel }
    /// Groups that are background noise for most people, shown collapsed.
    private static let quietKinds: Set<RunningKind> = [.agent, .mcp, .other]

    var body: some View {
        let items = showSystem ? model.items : model.visibleItems
        // Left behind by an agent session that has ended: what mikko exists to catch, so it
        // comes first and is never folded into a quiet group.
        let orphans = items.filter(\.isOrphan)
        let main = items.filter { !Self.quietKinds.contains($0.kind) && !$0.isOrphan }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Headline(title: main.isEmpty ? "Nothing left running." : "\(main.count) thing\(main.count == 1 ? "" : "s") running",
                         subtitle: summary(main))
                MemoryBar(memory: model.memory, dev: main.reduce(0) { $0 + $1.memory }).padding(.top, 10)

                if let m = model.message {
                    notice(m, button: "Dismiss") { model.message = nil }
                }
                ForEach(model.leftovers) { l in
                    notice("\(l.processes.count) process\(l.processes.count == 1 ? "" : "es") of \(l.title) kept running after being asked to stop.",
                           button: "Force Stop") { model.forceStop(l) }
                }
                if !model.idleCandidates.isEmpty {
                    AttentionRow(item: AttentionItem(id: "idle", level: .info, symbol: "moon.zzz",
                                                     text: "\(model.idleCandidates.count) idle — nobody has used \(model.idleCandidates.count == 1 ? "it" : "them") for \(Int(model.idleThreshold / 60)) minutes.",
                                                     actionTitle: "Stop Idle…") { showStopIdle = true })
                        .padding(.top, 10)
                }

                if !orphans.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        GroupLabel(text: "Left behind by ended agent sessions",
                                   trailing: ByteFormat.string(Int64(orphans.reduce(0) { $0 + $1.memory })))
                        Spacer()
                        let stoppable = orphans.filter { model.policy.allowsOrphanBatchStop($0) && model.pendingStops[$0.id] == nil }
                        if stoppable.count > 1 {
                            Button("Stop All \(stoppable.count)") { model.requestStop(stoppable) }
                                .controlSize(.small)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(orphans) { item in
                            RunningRow(item: item, isOpen: openItem == item.id, toggle: { openItem = openItem == item.id ? nil : item.id },
                                       confirm: { confirming = $0 })
                            if item.id != orphans.last?.id { Divider().padding(.leading, 44) }
                        }
                    }
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Calm.corner, style: .continuous))
                }

                ForEach(groups(main), id: \.title) { group in
                    GroupLabel(text: group.title, trailing: ByteFormat.string(Int64(group.items.reduce(0) { $0 + $1.memory })))
                    VStack(spacing: 0) {
                        ForEach(group.items) { item in
                            RunningRow(item: item, isOpen: openItem == item.id, toggle: { openItem = openItem == item.id ? nil : item.id },
                                       confirm: { confirming = $0 })
                            if item.id != group.items.last?.id { Divider().padding(.leading, 44) }
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Calm.corner, style: .continuous))
                }

                let quiet = RunningKind.allCases.filter { Self.quietKinds.contains($0) }.compactMap { kind -> (RunningKind, [RunningItem])? in
                    let g = items.filter { $0.kind == kind && !$0.isOrphan }
                    return g.isEmpty ? nil : (kind, g)
                }
                if !quiet.isEmpty {
                    GroupLabel(text: "In the background")
                    VStack(spacing: 0) {
                        ForEach(quiet, id: \.0) { kind, group in
                            QuietGroup(kind: kind, items: group, expanded: binding(for: kind), openItem: $openItem, confirm: { confirming = $0 })
                            if kind != quiet.last?.0 { Divider().padding(.leading, 44) }
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Calm.corner, style: .continuous))
                }
            }
            .padding(Calm.pad)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            Menu {
                Toggle("Group by Project", isOn: $byProject)
                Toggle("Show System Services", isOn: $showSystem)
            } label: { Label("View Options", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .sheet(isPresented: $showStopIdle) { StopIdleSheet() }
        .confirmationDialog(confirming.map { "Stop \($0.title)?" } ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { item in
            Button("Stop", role: .destructive) { model.requestStop([item]) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(model.policy.warning(for: item) ?? "")
        }
        .onAppear { model.isForeground = true }
        .onDisappear { model.isForeground = false }
    }

    private func summary(_ main: [RunningItem]) -> String? {
        guard !main.isEmpty else { return "No dev servers, simulators or databases found." }
        return "Click a row for details."
    }

    private func notice(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        AttentionRow(item: AttentionItem(id: text, symbol: "exclamationmark.triangle", text: text, actionTitle: button, action: action))
            .padding(.top, 10)
    }

    private func binding(for kind: RunningKind) -> Binding<Bool> {
        Binding(get: { expandedRaw.split(separator: ",").contains(Substring(kind.rawValue)) },
                set: { on in
                    var set = Set(expandedRaw.split(separator: ",").map(String.init))
                    if on { set.insert(kind.rawValue) } else { set.remove(kind.rawValue) }
                    expandedRaw = set.sorted().joined(separator: ",")
                })
    }

    private func groups(_ items: [RunningItem]) -> [(title: String, items: [RunningItem])] {
        if byProject {
            return Dictionary(grouping: items) { $0.project?.name ?? "No project" }
                .map { (title: $0.key, items: $0.value) }
                .sorted { ($0.title == "No project" ? 1 : 0, $0.title) < ($1.title == "No project" ? 1 : 0, $1.title) }
        }
        return RunningKind.allCases.compactMap { kind in
            let group = items.filter { $0.kind == kind }
            return group.isEmpty ? nil : (title: kind.title, items: group)
        }
    }
}

/// A background group folded into one line: "Agents · 4 · 1.3 GB ›".
private struct QuietGroup: View {
    let kind: RunningKind
    let items: [RunningItem]
    @Binding var expanded: Bool
    @Binding var openItem: String?
    let confirm: (RunningItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 20)
                    Text(kind.title)
                    Text("\(items.count)").foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteFormat.string(Int64(items.reduce(0) { $0 + $1.memory }))).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 14).frame(minHeight: Calm.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kind.title), \(items.count) items")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                ForEach(items) { item in
                    Divider().padding(.leading, 44)
                    RunningRow(item: item, isOpen: openItem == item.id, toggle: { openItem = openItem == item.id ? nil : item.id }, confirm: confirm)
                }
            }
        }
    }
}

extension RunningKind {
    var symbol: String {
        switch self {
        case .devServer: "server.rack"
        case .bundler: "shippingbox"
        case .agent: "sparkles"
        case .simulator: "iphone"
        case .container: "cube"
        case .database: "cylinder"
        case .mcp: "puzzlepiece.extension"
        case .other: "app.dashed"
        }
    }
}

/// A thin bar: all memory in use, with the dev tools' share highlighted. Pressure is only mentioned when it is a problem.
private struct MemoryBar: View {
    let memory: MemoryStatus
    let dev: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let total = max(Double(memory.total), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.secondary.opacity(0.35)).frame(width: geo.size.width * Double(memory.used) / total)
                    Capsule().fill(.tint).frame(width: geo.size.width * min(Double(dev), Double(memory.used)) / total)
                }
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                Circle().fill(.tint).frame(width: 7, height: 7)
                Text("These \(ByteFormat.string(Int64(dev)))")
                Text("· Mac \(ByteFormat.string(Int64(memory.used))) of \(ByteFormat.string(Int64(memory.total)))")
                if memory.pressure != .normal {
                    Label("Memory is \(memory.pressure == .critical ? "critically " : "")tight", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(memory.pressure == .critical ? .red : .orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory: dev tools use \(ByteFormat.string(Int64(dev))), the Mac uses \(ByteFormat.string(Int64(memory.used))) of \(ByteFormat.string(Int64(memory.total)))")
    }
}

/// One line per thing: icon, name, at most one status, memory, stop. Everything else opens on click.
private struct RunningRow: View {
    @Environment(AppModel.self) private var app
    let item: RunningItem
    let isOpen: Bool
    let toggle: () -> Void
    let confirm: (RunningItem) -> Void
    @State private var hovering = false

    private var model: RunningModel { app.runningModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        Image(systemName: item.kind.symbol).foregroundStyle(.secondary).frame(width: 20)
                        Text(item.title).lineLimit(1)
                        if let p = item.project { Text(p.name).foregroundStyle(.secondary).lineLimit(1) }
                        if model.policy.isPinned(item) {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary).accessibilityLabel("Pinned")
                        }
                        status
                        Spacer(minLength: 8)
                        Text(ByteFormat.string(Int64(item.memory))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint(isOpen ? "Hides details" : "Shows details")
                stopControl.frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: Calm.rowHeight)
            if isOpen { details.padding(.leading, 46).padding(.trailing, 14).padding(.bottom, 12) }
        }
        .background(hovering || isOpen ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private var accessibilitySummary: String {
        var parts = [item.title]
        if let p = item.project { parts.append(p.name) }
        if let s = statusText { parts.append(s) }
        parts.append(ByteFormat.string(Int64(item.memory)))
        return parts.joined(separator: ", ")
    }

    /// The agent session this item came from: its own marker first, then the running agent's session file.
    private var sessionID: String? {
        if let id = item.sessionID { return id }
        if item.kind == .agent { return ClaudeSessionMap.sessionID(for: item.root) }
        return item.agentProcess.flatMap { ClaudeSessionMap.sessionID(for: $0) }
    }

    /// The single most important thing to know about this row, if any.
    private var statusText: String? {
        if item.isOrphan { return "Left behind" }
        if item.exposedToLAN, item.kind == .devServer { return "On your network" }
        if item.isBuilding { return "Building" }
        if model.isIdle(item), let a = model.activity[item.id] { return "Idle \(DurationFormat.short(a.idleSeconds()))" }
        return nil
    }

    @ViewBuilder private var status: some View {
        if let text = statusText {
            let color: Color = item.isOrphan ? .orange : (item.exposedToLAN && item.kind == .devServer) ? .red : item.isBuilding ? .blue : .secondary
            Tag(text, color: color)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if let port = item.primaryPort, item.kind != .agent { detail("Address", "localhost:\(port)") }
                detail("Started", "\(item.launcher.label.replacingOccurrences(of: "Started by ", with: "By ")) · \(DurationFormat.short(Date().timeIntervalSince(item.startedAt))) ago")
                detail("Chain", item.chain.prefix(5).joined(separator: " ← "))
                if let a = model.activity[item.id] { detail("CPU", String(format: "%.0f%%", a.cpuPercent)) }
                if let b = item.project?.branch { detail("Branch", b) }
            }
            .font(.callout)
            if item.exposedToLAN, item.kind == .devServer {
                Text("Other devices on your network can open this server. Restart it bound to localhost to keep it private.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.isOrphan {
                Text("The agent session that started this has ended, so nothing will stop it for you.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let port = item.primaryPort, item.kind != .agent {
                    Button("Open") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
                    Button("Copy URL") { copy("http://localhost:\(port)") }
                }
                if let dir = item.project?.root ?? item.cwd {
                    Button("Show Folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir) }
                }
                if let session = sessionID {
                    Button("Open Session") {
                        if app.sessionsModel.show(sessionID: session) { app.select(.sessions) }
                        else { model.message = "That session isn't indexed yet. Open Sessions to refresh the list." }
                    }
                }
                Button(model.pinned.contains(item.pinKey) ? "Unpin" : "Pin") { model.togglePin(item) }
                    .help("Pinned items are never stopped in bulk or by agents.")
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private var stopControl: some View {
        if let fireAt = model.pendingStops[item.id] {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Button("Undo \(max(Int(fireAt.timeIntervalSinceNow.rounded(.up)), 0))") { model.undoStop(item.id) }
                    .controlSize(.small)
            }
        } else if model.stopping.contains(item.id) {
            ProgressView().controlSize(.small)
        } else if model.survivors[item.id] != nil {
            Button("Force Stop", role: .destructive) { model.forceStop(item) }
                .controlSize(.small).help("It did not stop when asked politely.")
        } else {
            Button { stop() } label: { Image(systemName: "stop.circle").font(.title3) }
                .buttonStyle(.borderless)
                .foregroundStyle(hovering || isOpen ? Color.primary : Color.secondary.opacity(0.6))
                .help("Stop \(item.title)")
                .accessibilityLabel("Stop \(item.title)")
        }
    }

    private func stop() {
        if model.policy.warning(for: item) != nil { confirm(item) } else { model.requestStop([item]) }
    }

    @ViewBuilder private var menu: some View {
        if let port = item.primaryPort, item.kind != .agent {
            Button("Open in Browser") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
            Button("Copy URL") { copy("http://localhost:\(port)") }
            Button("Copy Port") { copy(String(port)) }
        }
        Button("Copy PID") { copy(String(item.root.pid)) }
        Button("Copy Command") { copy(item.command) }
        if let dir = item.project?.root ?? item.cwd {
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir) }
            Button("Open in Terminal") {
                NSWorkspace.shared.open([URL(fileURLWithPath: dir)],
                                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        }
        Divider()
        Button(model.pinned.contains(item.pinKey) ? "Unpin" : "Pin — Never Stop in Bulk") { model.togglePin(item) }
        if let p = item.project {
            Button(model.pinned.contains("project:\(p.root)") ? "Unpin Project \(p.name)" : "Pin Project \(p.name)") { model.togglePin(project: p) }
            let siblings = model.visibleItems.filter { $0.project == p && model.policy.allowsBulkStop($0) }
            if siblings.count > 1 { Button("Stop Project \(p.name) (\(siblings.count))") { model.requestStop(siblings) } }
        }
        Divider()
        Button("Stop") { stop() }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct Tag: View {
    let text: String
    var symbol: String?
    let color: Color
    init(_ text: String, symbol: String? = nil, color: Color) { self.text = text; self.symbol = symbol; self.color = color }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// R-5: everything idle is ticked, except pinned items and databases, with one confirmation.
struct StopIdleSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var unchecked: Set<String> = []

    var body: some View {
        let model = app.runningModel
        let candidates = model.idleCandidates
        VStack(alignment: .leading, spacing: 12) {
            Text("Stop idle items").font(.title2.bold())
            Text("Idle means no connections and almost no CPU use for \(Int(model.idleThreshold / 60)) minutes. Pinned items, databases, agent sessions and running builds are never included.")
                .foregroundStyle(.secondary)
            List(candidates) { item in
                Toggle(isOn: Binding(get: { !unchecked.contains(item.id) },
                                     set: { if $0 { unchecked.remove(item.id) } else { unchecked.insert(item.id) } })) {
                    HStack {
                        Text(item.title + (item.project.map { " (\($0.name))" } ?? ""))
                        Spacer()
                        Text(ByteFormat.string(Int64(item.memory))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                let chosen = candidates.filter { !unchecked.contains($0.id) }
                Button("Stop \(chosen.count)") {
                    model.requestStop(chosen)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }
}
