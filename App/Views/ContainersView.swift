import MikkoCore
import SwiftUI

struct ContainersView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmCleanup: (ContainersModel.Cleanup, ContainersModel.Engine)?
    @State private var volumeEngine: ContainersModel.Engine?

    private var model: ContainersModel { app.containersModel }

    var body: some View {
        List {
            Section {
                Headline(title: headline, subtitle: subtitle).listRowSeparator(.hidden).padding(.vertical, 6)
                if let m = model.message { Label(m, systemImage: "info.circle").foregroundStyle(.secondary) }
            }
            ForEach(model.engines) { engine in
                let running = engine.containers.filter(\.isRunning).sorted { ($0.composeProject ?? "~", $0.name) < ($1.composeProject ?? "~", $1.name) }
                let stopped = engine.containers.filter { !$0.isRunning }.sorted { $0.name < $1.name }
                Section(model.engines.count > 1 || !engine.reachable ? engine.client.runtimeName : "") {
                    if !engine.reachable {
                        Label("Not running, so there is nothing to show or stop.", systemImage: "moon.zzz").foregroundStyle(.secondary)
                    } else if let error = engine.error {
                        Label("Did not answer: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    ForEach(running) { containerRow($0) }
                    if !stopped.isEmpty {
                        DisclosureGroup {
                            ForEach(stopped) { containerRow($0) }
                        } label: { fold("Stopped containers", "\(stopped.count)") }
                    }
                    if let usage = engine.usage {
                        DisclosureGroup {
                            spaceRows(usage, engine)
                        } label: {
                            fold("Free up space", ByteFormat.string(ContainersModel.Cleanup.allCases.reduce(0) { $0 + $1.bytes(usage) }) + " can go")
                        }
                    }
                }
            }
            if let disk = model.vmDisk {
                Section {
                    DisclosureGroup {
                        Text("Removing images and containers frees space inside Docker's disk file, but the file itself only shrinks when Docker Desktop compacts it — it does that on its own after a cleanup while it is running.")
                            .font(.callout).foregroundStyle(.secondary)
                    } label: { fold("Docker's disk file", ByteFormat.string(disk.allocatedBytes) + " on your SSD") }
                }
            }
            if model.engines.isEmpty, !model.isLoading {
                ContentUnavailableView("No container engine found", systemImage: "shippingbox",
                                       description: Text("Docker Desktop, OrbStack and Colima appear here when installed."))
            }
        }
        .listStyle(.inset)
        .toolbar { Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.isLoading) }
        .confirmationDialog(confirmCleanup.map { "\($0.0.title)?" } ?? "", isPresented: Binding(get: { confirmCleanup != nil }, set: { if !$0 { confirmCleanup = nil } })) {
            if let (cleanup, engine) = confirmCleanup {
                Button(cleanup.title, role: .destructive) { model.run(cleanup, on: engine) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((confirmCleanup?.0.whatYouLose ?? "") + " Containers do not use the Trash: this cannot be undone.")
        }
        .sheet(item: $volumeEngine) { VolumeSheet(engine: $0) }
        .onAppear { model.refresh() }
    }

    private var headline: String {
        let n = model.containers.filter(\.isRunning).count
        if model.isLoading, model.engines.isEmpty { return "Looking for containers…" }
        if !model.engines.contains(where: \.reachable), !model.engines.isEmpty { return "Docker is not running." }
        return n == 0 ? "No containers running." : "\(n) container\(n == 1 ? "" : "s") running"
    }

    private var subtitle: String? {
        let mem = model.stats.values.reduce(Int64(0)) { $0 + $1.memory }
        return mem > 0 ? "Using \(ByteFormat.string(mem)) of memory. Stopping a container keeps its data." : "Stopping a container keeps its data."
    }

    private func fold(_ title: String, _ trailing: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(trailing).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func containerRow(_ c: DockerContainer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(c.isRunning ? .green : .secondary).frame(width: 22)
            Text(c.name).lineLimit(1)
            if let p = c.composeProject, p != c.name { Text(p).foregroundStyle(.secondary).lineLimit(1) }
            if let port = c.ports.first { Tag(":\(port)", color: .secondary) }
            Spacer()
            if let s = model.stats[c.id] { Text(ByteFormat.string(s.memory)).monospacedDigit().foregroundStyle(.secondary) }
            if model.busy.contains(c.id) { ProgressView().controlSize(.small).frame(width: 70) }
            else if c.isRunning { Button("Stop") { model.stop(c) }.frame(width: 70).help("Stops the container. Its data is kept.") }
            else { Button("Start") { model.start(c) }.frame(width: 70) }
        }
        .help("\(c.image) · \(c.status)")
        .contextMenu {
            if let port = c.ports.first { Button("Open in Browser") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) } }
            Button("Restart") { model.restart(c) }.disabled(!c.isRunning)
            if let p = c.composeProject { Button("Stop Project \(p)") { model.stopProject(p, of: c) } }
        }
    }

    @ViewBuilder private func spaceRows(_ usage: DockerDiskUsage, _ engine: ContainersModel.Engine) -> some View {
        Text("In use: images \(ByteFormat.string(usage.imagesBytes)), containers \(ByteFormat.string(usage.containersBytes)), volumes \(ByteFormat.string(usage.volumesBytes)).")
            .font(.callout).foregroundStyle(.secondary)
        ForEach(ContainersModel.Cleanup.allCases) { cleanup in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(cleanup.title); RiskBadge(level: cleanup.risk) }
                    Text(cleanup.whatYouLose).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.string(cleanup.bytes(usage))).monospacedDigit()
                Button("Clean…") { confirmCleanup = (cleanup, engine) }.disabled(cleanup.bytes(usage) == 0)
            }
        }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Remove unused volumes"); RiskBadge(level: .risky) }
                Text("Volumes can hold databases. Each one is listed by name and must be ticked by you.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(usage.unusedVolumes.reduce(0) { $0 + max($1.bytes, 0) })).monospacedDigit()
            Button("Review…") { volumeEngine = engine }.disabled(usage.unusedVolumes.isEmpty)
        }
    }
}

/// C-3: volumes are never ticked for you.
private struct VolumeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let engine: ContainersModel.Engine
    @State private var chosen: Set<String> = []
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Unused volumes").font(.title2.bold()); RiskBadge(level: .risky) }
            Text("No container refers to these volumes, but they may still hold a database or uploads you want. Removing a volume deletes its contents for good.")
                .foregroundStyle(.secondary)
            List(engine.usage?.unusedVolumes ?? []) { v in
                Toggle(isOn: Binding(get: { chosen.contains(v.name) }, set: { if $0 { chosen.insert(v.name) } else { chosen.remove(v.name) } })) {
                    HStack { Text(v.name).lineLimit(1).truncationMode(.middle); Spacer(); Text(ByteFormat.string(max(v.bytes, 0))).monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Remove \(chosen.count)…", role: .destructive) { confirm = true }.disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .confirmationDialog("Permanently remove \(chosen.count) volume\(chosen.count == 1 ? "" : "s")?", isPresented: $confirm) {
            Button("Remove Permanently", role: .destructive) {
                app.containersModel.removeVolumes(Array(chosen), on: engine)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their contents cannot be recovered.") }
    }
}
