import MikkoCore
import SwiftUI

struct SimulatorsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirm: Confirmation?

    struct Confirmation: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var button: String
        var action: () -> Void
    }

    private var model: SimulatorsModel { app.simulatorsModel }

    var body: some View {
        List {
            Section {
                Headline(title: headline, subtitle: "Shut-down simulators use no memory, only disk space.")
                    .listRowSeparator(.hidden).padding(.vertical, 6)
                if let m = model.message {
                    Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            let booted = model.devices.filter(\.isBooted)
            if !booted.isEmpty {
                Section("Running now") { ForEach(booted) { deviceRow($0) } }
            }
            let runningAVDs = model.avds.filter(\.isRunning)
            if !runningAVDs.isEmpty {
                Section("Android emulators running") { ForEach(runningAVDs) { avdRow($0) } }
            }
            Section("On disk") {
                let off = model.devices.filter { !$0.isBooted }
                if !off.isEmpty {
                    DisclosureGroup {
                        ForEach(off) { deviceRow($0) }
                    } label: { foldLabel("Shut-down simulators", count: off.count, bytes: off.reduce(0) { $0 + $1.dataBytes }) }
                }
                if !model.runtimes.isEmpty {
                    DisclosureGroup {
                        ForEach(model.runtimes) { runtimeRow($0) }
                    } label: { foldLabel("Installed OS versions", count: model.runtimes.count, bytes: model.runtimes.reduce(0) { $0 + $1.sizeBytes }) }
                }
                let stopped = model.avds.filter { !$0.isRunning }
                if !stopped.isEmpty {
                    DisclosureGroup {
                        ForEach(stopped) { avdRow($0) }
                    } label: { foldLabel("Android emulators", count: stopped.count, bytes: stopped.reduce(0) { $0 + $1.bytes }) }
                }
                if !model.images.isEmpty {
                    DisclosureGroup {
                        ForEach(model.images) { imageRow($0) }
                    } label: { foldLabel("Android system images", count: model.images.count, bytes: model.images.reduce(0) { $0 + $1.bytes }) }
                }
            }
            if model.devices.isEmpty, model.avds.isEmpty, !model.isLoading {
                ContentUnavailableView("No simulators or emulators", systemImage: "iphone.slash")
            }
        }
        .listStyle(.inset)
        .overlay { if model.isLoading, model.devices.isEmpty, model.avds.isEmpty { ProgressView() } }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    bulk("Shut Down All", .safe, count: model.booted.count, "Shut down \(model.booted.count) booted simulators?",
                         "They are shut down cleanly. Nothing is deleted.") { model.shutdownAll() }
                    bulk("Kill Preview Simulators", .safe, count: model.devices.filter { $0.isPreview && $0.isBooted }.count,
                         "Stop Xcode preview simulators?", "Xcode starts them again when you open a preview.") { model.shutdownPreviews() }
                    bulk("Delete Unavailable", .safe, count: model.unavailable.filter { !$0.isPreview }.count, "Delete \(model.unavailable.count) unavailable simulators?",
                         "Their OS version is no longer installed, so they cannot boot.") { model.deleteUnavailable() }
                    bulk("Delete Unused for 60+ Days", .caution, count: model.unused().count, "Delete \(model.unused().count) simulators last used over 60 days ago?",
                         "\(model.unused().prefix(12).map { "\($0.name) (\($0.runtimeName))" }.joined(separator: ", "))\(model.unused().count > 12 ? " and more" : ""). Apps and data installed on them are lost. This cannot be undone. Simulators that were never booted are not included.") { model.deleteUnused() }
                } label: { Label("Bulk Actions", systemImage: "ellipsis.circle") }
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.isLoading)
            }
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(c.button, role: .destructive) { c.action() }
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.message) }
        .onAppear { model.refresh() }
    }

    private var headline: String {
        let n = model.booted.count + model.avds.filter(\.isRunning).count
        if model.isLoading, model.devices.isEmpty, model.avds.isEmpty { return "Reading simulators…" }
        return n == 0 ? "No simulators running." : "\(n) simulator\(n == 1 ? "" : "s") running"
    }

    private func foldLabel(_ title: String, count: Int, bytes: Int64) -> some View {
        HStack {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary)
            Spacer()
            Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func bulk(_ title: String, _ risk: RiskLevel, count: Int, _ question: String, _ message: String,
                      _ action: @escaping () -> Void) -> some View {
        Button("\(title) (\(count)) — \(risk.label)") {
            confirm = Confirmation(title: question, message: message, button: title, action: action)
        }
        .disabled(count == 0)
    }

    private func deviceRow(_ d: SimDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.isBooted ? "iphone.radiowaves.left.and.right" : "iphone").foregroundStyle(d.isBooted ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.name).font(.body.weight(.medium))
                    Text(d.runtimeName).foregroundStyle(.secondary)
                    if d.isPreview { Tag("Xcode Preview", color: .blue) }
                    if !d.isAvailable { Tag("Unavailable", symbol: "exclamationmark.triangle", color: .orange).help("Its OS version is no longer installed.") }
                }
            }
            .help(d.lastUsed.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
            Spacer()
            Text(ByteFormat.string(d.dataBytes)).monospacedDigit().foregroundStyle(.secondary)
            if model.busy.contains(d.udid) { ProgressView().controlSize(.small).frame(width: 90) }
            else if d.isBooted { Button("Shut Down") { model.shutdown(d) }.frame(width: 90) }
            else { Button("Boot") { model.boot(d) }.controlSize(.small).buttonStyle(.borderless).frame(width: 90, alignment: .trailing).disabled(!d.isAvailable) }
        }
        .contextMenu {
            if let path = d.dataPath { Button("Reveal Data Folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } }
            Button("Erase Content…") {
                confirm = Confirmation(title: "Erase \(d.name)?", message: "Installed apps and their data are removed and the simulator returns to a clean state. This cannot be undone.",
                                       button: "Erase") { model.erase(d) }
            }
            .disabled(d.isBooted)
            Button("Delete…") {
                confirm = Confirmation(title: "Delete \(d.name)?", message: "The simulator and everything on it is removed. You can create it again in Xcode, but its data is gone.",
                                       button: "Delete") { model.delete(d) }
            }
        }
    }

    private func runtimeRow(_ r: SimRuntime) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.body.weight(.medium))
                Text("\(r.deviceCount) simulator\(r.deviceCount == 1 ? "" : "s") use it" + (r.lastUsed.map { " · last used \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(r.sizeBytes)).monospacedDigit()
            if model.busy.contains(r.id) { ProgressView().controlSize(.small) } else {
                Button("Remove…") {
                    confirm = Confirmation(title: "Remove \(r.name)?",
                                           message: "\(ByteFormat.string(r.sizeBytes)) is freed. To use this OS version again you must download it in Xcode. \(r.deviceCount) simulators that need it become unavailable.",
                                           button: "Remove") { model.deleteRuntime(r) }
                }
                .disabled(!r.deletable)
            }
        }
    }

    private func avdRow(_ a: AndroidAVD) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "candybarphone").foregroundStyle(a.isRunning ? .green : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.displayName).font(.body.weight(.medium))
                    if let t = a.target { Text(t).foregroundStyle(.secondary) }
                    if a.isRunning { Tag("Running", color: .green) }
                }
                Text(a.lastUsed.map { "Last changed \($0.formatted(.relative(presentation: .named)))" } ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(a.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if model.busy.contains(a.name) { ProgressView().controlSize(.small).frame(width: 90) }
            else if a.isRunning { Button("Stop") { model.stop(a) }.frame(width: 90) }
            else { Color.clear.frame(width: 90, height: 1) }
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }
            Button("Wipe Data…") {
                confirm = Confirmation(title: "Wipe \(a.displayName)?", message: "Apps and data on the emulator are moved to the Trash; it starts clean next time.", button: "Wipe Data") { model.wipe(a) }
            }
            .disabled(a.isRunning)
            Button("Delete…") {
                confirm = Confirmation(title: "Delete \(a.displayName)?", message: "The emulator is moved to the Trash.", button: "Delete") { model.delete(a) }
            }
            .disabled(a.isRunning)
        }
    }

    private func imageRow(_ i: AndroidSystemImage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.name).font(.body.weight(.medium))
                Text(i.usedByAVDs == 0 ? "Not used by any emulator" : "Used by \(i.usedByAVDs) emulator\(i.usedByAVDs == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(i.bytes)).monospacedDigit()
            Button("Remove…") {
                confirm = Confirmation(title: "Remove this system image?", message: "It is moved to the Trash. Download it again in Android Studio's SDK Manager if you need it.", button: "Remove") { model.delete(i) }
            }
            .disabled(i.usedByAVDs > 0)
            .help(i.usedByAVDs > 0 ? "An emulator still uses this image." : "")
        }
    }
}
