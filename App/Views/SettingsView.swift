import MikkoCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RunningSettings().tabItem { Label("Running", systemImage: "bolt.horizontal") }
            DiskSettings().tabItem { Label("Disk", systemImage: "internaldrive") }
            AgentSettings().tabItem { Label("Agents", systemImage: "terminal") }
            PermissionsView().padding(20).tabItem { Label("Permissions", systemImage: "hand.raised") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("menuBarMetric") private var metric: MenuBarMetric = .freeDisk
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Picker("Show in menu bar", selection: $metric) {
                ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
            }
            Section {
                Toggle("Check for new versions once a day", isOn: Binding(get: { app.updateModel.enabled },
                                                                          set: { app.updateModel.enabled = $0 }))
                Text("Asks GitHub for the latest version number. Nothing about you or this Mac is sent. Everything else stays on this Mac: no account, no telemetry, no cloud.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("mikko \(app.updateModel.currentVersion)").font(.headline)
                        Text("見 mi · to see. Free and open source, by Anemo.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let release = app.updateModel.available {
                        Button("Download \(release.version)") { app.updateModel.download() }
                    } else {
                        Button("Check Now") { Task { await app.updateModel.checkNow() } }
                    }
                }
                HStack(spacing: 16) {
                    Link("Website", destination: Links.website)
                    Link("Source code", destination: Links.source)
                    Link("Report a problem", destination: Links.issues)
                    Link("Privacy", destination: Links.privacy)
                }
            }
            Section("More from Anemo") {
                ForEach(Links.family) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.headline)
                            Text(p.line).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("Website", destination: p.site)
                        if let store = p.appStore { Link("App Store", destination: store) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RunningSettings: View {
    @AppStorage("idleMinutes") private var idleMinutes = 30
    @AppStorage("showSystemListeners") private var showSystem = false
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Stepper("Call something idle after \(idleMinutes) minutes without connections or CPU use", value: $idleMinutes, in: 5...720, step: 5)
            Toggle("Show system services in the list", isOn: $showSystem)
            Section("Pinned — never stopped in bulk or by agents") {
                if app.runningModel.pinned.isEmpty { Text("Nothing pinned. Right-click an item in Running to pin it.").foregroundStyle(.secondary) }
                ForEach(app.runningModel.pinned.sorted(), id: \.self) { key in
                    HStack {
                        Text(pinLabel(key)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Unpin") { app.runningModel.pinned.remove(key) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pinLabel(_ key: String) -> String {
        if key.hasPrefix("project:") { return "Project " + (String(key.dropFirst(8)) as NSString).abbreviatingWithTildeInPath }
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? "\(parts[1]) — \((parts[0] as NSString).abbreviatingWithTildeInPath)" : key
    }
}

private struct DiskSettings: View {
    @AppStorage("activeProjectDays") private var activeDays = 14
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.diskModel
        Form {
            Stepper("Treat a project as active for \(activeDays) days after its last change", value: $activeDays, in: 1...180)
            Section("Project folders") {
                if model.projectFolders.isEmpty { Text("None chosen. Add them from the Disk screen.").foregroundStyle(.secondary) }
                ForEach(model.projectFolders, id: \.self) { folder in
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { model.removeProjectFolder(folder) }
                    }
                }
            }
            Section("Never clean") {
                if model.exclusions.paths.isEmpty, model.exclusions.categoryIDs.isEmpty {
                    Text("Nothing excluded. Right-click an item in Disk to exclude it.").foregroundStyle(.secondary)
                }
                ForEach(model.exclusions.categoryIDs.sorted(), id: \.self) { id in
                    HStack {
                        Text("Category: \(model.categoryTitle(id))")
                        Spacer()
                        Button("Allow Again") { model.exclusions.categoryIDs.remove(id) }
                    }
                }
                ForEach(model.exclusions.paths.sorted(), id: \.self) { path in
                    HStack {
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Allow Again") { model.exclusions.paths.remove(path) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettings: View {
    @Environment(AppModel.self) private var app
    @State private var actions: [AgentAction] = []
    @State private var message: String?

    private var bundledCLI: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mikko").path }
    private var linkPath: String { "\(NSHomeDirectory())/.local/bin/mikko" }
    private var cliAvailable: Bool { FileManager.default.isExecutableFile(atPath: bundledCLI) }
    private var installed: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundledCLI }

    var body: some View {
        Form {
            Section("Command line tool") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installed ? "Installed at ~/.local/bin/mikko" : "Not installed")
                        Text("mikko status · mikko ports · mikko stop 3000 · mikko disk").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(installed ? "Remove" : "Install") { toggleCLI() }.disabled(!cliAvailable)
                }
                if !cliAvailable { Text("This build has no bundled command line tool. Build with scripts/build.sh.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("MCP server for agents") {
                Text("Agents can see what is running and stop only what they started. They cannot stop your servers, databases, pinned items or builds, and cannot clean the disk.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("claude mcp add mikko -- \(installed ? "mikko" : bundledCLI) mcp").font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude mcp add mikko -- \(installed ? linkPath : bundledCLI) mcp", forType: .string)
                    }
                    .disabled(!cliAvailable)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Section("What agents did") {
                if actions.isEmpty { Text("No agent has used mikko yet.").foregroundStyle(.secondary) }
                ForEach(actions.prefix(50)) { a in
                    HStack {
                        Text(a.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(Launcher(rawValue: a.agent)?.label.replacingOccurrences(of: "Started by ", with: "") ?? a.agent)
                        Text("\(a.tool) \(a.target)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(a.result).foregroundStyle(a.result.hasPrefix("refused") ? .orange : .secondary).lineLimit(1)
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { actions = (try? app.sessionsModel.database?.agentActions()) ?? [] }
    }

    private func toggleCLI() {
        let fm = FileManager.default
        do {
            if installed {
                try fm.removeItem(atPath: linkPath)
            } else {
                try fm.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                // Only ever replace our own link, never someone else's file.
                if fm.fileExists(atPath: linkPath) || (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil {
                    guard (try? fm.destinationOfSymbolicLink(atPath: linkPath))?.hasSuffix("/Contents/Helpers/mikko") == true else {
                        message = "~/.local/bin/mikko already exists and is not mikko's. Remove it first."
                        return
                    }
                    try fm.removeItem(atPath: linkPath)
                }
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: bundledCLI)
                let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").contains("/.local/bin")
                message = onPath ? nil : "Installed. Add ~/.local/bin to your shell PATH to run “mikko” from anywhere."
            }
        } catch {
            message = "Could not change the command line tool: \(error.localizedDescription)"
        }
    }
}
