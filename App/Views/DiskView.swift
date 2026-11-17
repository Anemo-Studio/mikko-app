import MikkoCore
import SwiftUI

/// Disk leads with one number and one button. Categories sit in three groups by risk;
/// what each one costs you appears only when you open it.
struct DiskView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmClean = false
    @State private var confirmEmptyTrash = false
    @State private var showHistory = false

    private var model: DiskModel { app.diskModel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !model.hasScanned && !model.isScanning && model.results.isEmpty {
                    Headline(title: app.disk.map { "\(ByteFormat.string($0.free)) free" } ?? "Disk",
                             subtitle: "See how much your developer tools are holding. Nothing changes until you choose to clean.")
                    Button("Scan") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction).padding(.top, 14)
                } else {
                    header
                    if let clean = model.lastClean { cleanBanner(clean).padding(.top, 10) }
                    ForEach(RiskLevel.allCases, id: \.self) { level in
                        let group = model.visibleResults.filter { $0.category.risk == level }
                        if !group.isEmpty {
                            GroupLabel(text: groupTitle(level), trailing: ByteFormat.string(group.reduce(0) { $0 + $1.bytes }))
                            rows { ForEach(group) { CategoryRow(result: $0, isLast: $0.id == group.last?.id) } }
                        }
                    }
                    if model.onlyOld, model.visibleResults.isEmpty, model.visibleProjects.isEmpty, !model.isScanning {
                        Text("Nothing here has gone untouched for \(DiskModel.oldDays) days.").foregroundStyle(.secondary).card()
                    }
                    let projects = model.visibleProjects
                    if !projects.isEmpty {
                        GroupLabel(text: "Old project leftovers", trailing: ByteFormat.string(projects.reduce(0) { $0 + $1.bytes }))
                        rows { ForEach(projects) { ProjectRow(project: $0, isLast: $0.id == projects.last?.id) } }
                    } else if model.projectFolders.isEmpty, !model.isScanning {
                        GroupLabel(text: "Old project leftovers")
                        HStack {
                            Text("Add the folders where you keep projects to find old node_modules and build folders.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Folders…") { addFolders() }
                        }
                        .card()
                    }
                }
            }
            .padding(Calm.pad)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            Menu {
                Button("Rescan") { model.scan() }.disabled(model.isScanning)
                Toggle("Only Untouched for \(DiskModel.oldDays)+ Days", isOn: Binding(get: { model.onlyOld }, set: { model.onlyOld = $0 }))
                Button("History…") { showHistory = true }
                Divider()
                ForEach(model.projectFolders, id: \.self) { folder in
                    Button("Remove \((folder as NSString).abbreviatingWithTildeInPath)") { model.removeProjectFolder(folder) }
                }
                Button("Add Project Folder…") { addFolders() }
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
        .sheet(isPresented: $showHistory) { HistoryView(entries: model.history) }
        .confirmationDialog("Move \(ByteFormat.string(model.selectedBytes)) to the Trash?", isPresented: $confirmClean) {
            if riskyCount > 0 {
                Button("Move Safe and Caution Items Only") { model.cleanSelected(includeRisky: false) }
                Button("Move Everything, Including \(riskyCount) Risky", role: .destructive) { model.cleanSelected(includeRisky: true) }
            } else {
                Button("Move to Trash") { model.cleanSelected(includeRisky: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .confirmationDialog("Empty the whole Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes everything in your Trash — not only what mikko moved there. It cannot be undone.")
        }
    }

    private func rows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Calm.corner, style: .continuous))
    }

    private func groupTitle(_ level: RiskLevel) -> String {
        switch level {
        case .safe: "Safe — comes back on its own"
        case .caution: "Check first"
        case .risky: "Risky — cannot be regenerated"
        }
    }

    private var riskyCount: Int { model.selectedItems.filter { model.risk(of: $0) == .risky }.count }

    private var confirmMessage: String {
        let items = model.selectedItems
        let caution = items.filter { model.risk(of: $0) == .caution }.count
        var parts = ["\(items.count) items. They stay in the Trash until you empty it; History lists where each one came from."]
        if caution > 0 { parts.append("\(caution) are marked Caution.") }
        if riskyCount > 0 { parts.append("\(riskyCount) are marked Risky: what they hold cannot be regenerated or downloaded again.") }
        return parts.joined(separator: " ")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Headline(title: model.isScanning && model.results.isEmpty ? "Scanning…" : "\(ByteFormat.string(model.safeReclaimable)) safe to clear",
                     subtitle: subtitle)
            if model.isScanning { ProgressView().controlSize(.small) }
            Button(model.isCleaning ? "Moving…" : "Clean \(ByteFormat.string(model.selectedBytes))") { confirmClean = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.selectedItems.isEmpty || model.isCleaning || model.isScanning)
                .help("Moves the ticked items to the Trash. You confirm first.")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = app.disk { parts.append("\(ByteFormat.string(d.free)) free of \(ByteFormat.string(d.total))") }
        let other = model.reclaimable - model.safeReclaimable
        if other > 0 { parts.append("\(ByteFormat.string(other)) more needs a look first") }
        return parts.joined(separator: " · ")
    }

    private func cleanBanner(_ c: CleanSummary) -> some View {
        let problems = c.failures.count + c.blocked.count
        return HStack(spacing: 12) {
            Image(systemName: problems == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(problems == 0 ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.trashEmptied ? "Trash emptied. \(ByteFormat.string(c.bytesMoved)) from mikko is gone for good."
                     : c.count == 0 ? "Nothing was moved." : "Moved \(ByteFormat.string(c.bytesMoved)) to the Trash. Space is freed when you empty it.")
                if !c.blocked.isEmpty {
                    Text("Skipped because a tool is using them: \(c.blocked.joined(separator: ", ")).").font(.caption).foregroundStyle(.secondary)
                }
                if let f = c.failures.first {
                    Text("\(c.failures.count) could not be moved — \(f.item.name): \(f.reason)").font(.caption).foregroundStyle(.secondary)
                }
                if let m = model.trashMessage { Text(m).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if c.bytesMoved > 0, !c.trashEmptied { Button("Empty Trash…") { confirmEmptyTrash = true } }
        }
        .card()
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that contain your projects"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !model.projectFolders.contains($0) }
        guard !added.isEmpty else { return }
        model.projectFolders += added
        model.scan()
    }
}

/// A row that opens in place: chevron, checkbox, name, size.
private struct ExpandableRow<Detail: View>: View {
    let items: [DiskItem]
    let title: String
    var note: String?
    var warning: String?
    let bytes: Int64
    let isLast: Bool
    @ViewBuilder var detail: () -> Detail
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                GroupCheckbox(items: items, label: title)
                Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).lineLimit(1)
                            if let warning { Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(ByteFormat.string(bytes))")
                .accessibilityValue(expanded ? "expanded" : "collapsed")
            }
            .padding(.horizontal, 14).frame(minHeight: warning == nil ? Calm.rowHeight : 50)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary).padding(.bottom, 2) }
                    detail()
                }
                .padding(.leading, 44).padding(.trailing, 14).padding(.bottom, 12)
            }
            if !isLast { Divider().padding(.leading, 44) }
        }
        .background(hovering || expanded ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
    }
}

/// Checkbox for one item or a group (mixed state when partly selected).
private struct GroupCheckbox: View {
    @Environment(AppModel.self) private var app
    let items: [DiskItem]
    let label: String

    private struct Source { var isOn: Binding<Bool> }

    var body: some View {
        let model = app.diskModel
        let sources = items.map { item in
            Source(isOn: Binding(get: { model.selection.contains(item.id) },
                                 set: { $0 ? model.select([item.id]) : model.deselect([item.id]) }))
        }
        Toggle(sources: sources, isOn: \.isOn) { Text(label) }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(label)
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var app
    let result: DiskCategoryResult
    let isLast: Bool

    var body: some View {
        let blocker = app.diskModel.blocker(for: result.category)
        ExpandableRow(items: result.items, title: "\(result.category.group) — \(result.category.title)",
                      note: result.category.whatYouLose,
                      warning: blocker.map { "\($0) is running — quit it before cleaning this" },
                      bytes: result.bytes, isLast: isLast) {
            ForEach(result.items) { ItemRow(item: $0, risk: $0.risk) }
        }
        .contextMenu {
            Button("Never Clean This Category") { app.diskModel.neverClean(categoryID: result.category.id) }
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var app
    let project: ProjectArtifacts
    let isLast: Bool
    @State private var confirmingRemoval = false

    private var canRemoveWorktree: Bool {
        project.isWorktree && project.hasUncommittedChanges == false && !app.diskModel.isBusy(project)
    }

    var body: some View {
        ExpandableRow(items: project.artifacts, title: project.name, note: note, warning: warning, bytes: project.bytes, isLast: isLast) {
            ForEach(project.artifacts) { ItemRow(item: $0, risk: app.diskModel.risk(of: $0)) }
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.root) }
            if canRemoveWorktree {
                Button("Remove Worktree…") { confirmingRemoval = true }
            }
            Button("Never Clean This Project") { app.diskModel.neverClean(path: project.root) }
        }
        .confirmationDialog("Remove the worktree \(project.name)?", isPresented: $confirmingRemoval) {
            Button("Move to Trash", role: .destructive) { app.diskModel.removeWorktree(project) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder goes to the Trash. Its branch\(project.branch.map { " \($0)" } ?? "") and every commit stay in the main repository. It has no uncommitted changes.")
        }
    }

    private var warning: String? {
        if project.isWorktree, project.hasUncommittedChanges != false {
            return project.hasUncommittedChanges == true ? "Agent worktree with uncommitted changes" : "Agent worktree — could not check for changes"
        }
        return app.diskModel.isBusy(project) ? "Something is running here" : nil
    }

    private var note: String {
        var parts: [String] = []
        if let d = project.lastModified { parts.append("Last changed \(d.formatted(.relative(presentation: .named)))") }
        if let b = project.branch { parts.append("branch \(b)") }
        if !project.hasGit { parts.append("not a git project, so never ticked for you") }
        else if project.isActive(withinDays: app.diskModel.activeDays) { parts.append("still active, so not ticked for you") }
        parts.append("These folders are rebuilt the next time you install or build.")
        return parts.joined(separator: " · ")
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var app
    let item: DiskItem
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: 10) {
            GroupCheckbox(items: [item], label: "\(item.name), \(ByteFormat.string(item.bytes))")
            Text(item.name).lineLimit(1).truncationMode(.middle)
            if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if risk == .risky { RiskBadge(level: risk) }
            Spacer()
            Text(ByteFormat.string(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(item.modified.map { "Last changed \($0.formatted(.relative(presentation: .named)))" } ?? "")
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Button("Never Clean This") { app.diskModel.neverClean(path: item.path) }
        }
    }
}

private struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [CleanHistoryEntry]

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView("Nothing cleaned yet", systemImage: "clock.arrow.circlepath")
            } else {
                Table(entries) {
                    TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                    TableColumn("Category", value: \.category)
                    TableColumn("Item", value: \.name)
                    TableColumn("Came from") { Text(($0.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head).help($0.path) }
                    TableColumn("Size") { Text(ByteFormat.string($0.bytes)).monospacedDigit() }.width(90)
                }
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 820, height: 440)
    }
}
