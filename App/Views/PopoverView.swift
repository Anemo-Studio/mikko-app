import MikkoCore
import SwiftUI

/// The menu bar popover: the headline, what needs attention, three quiet numbers.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.headline).font(.system(size: 18, weight: .semibold, design: .rounded))

            let items = model.attentionItems
            if items.isEmpty {
                Label("Nothing needs you right now.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary).symbolRenderingMode(.multicolor)
            } else {
                VStack(spacing: 6) {
                    ForEach(items.prefix(3)) { item in
                        AttentionRow(item: AttentionItem(id: item.id, level: item.level, symbol: item.symbol, text: item.text,
                                                         actionTitle: item.actionTitle) { item.action(); showWindow() }, compact: true)
                    }
                }
            }

            HStack(spacing: 0) {
                stat("\(model.runningDevItems.count)", "running", .running)
                Divider().frame(height: 26)
                stat(model.disk.map { ByteFormat.string($0.free) } ?? "–", "free", .disk)
                if model.visibleSections.contains(.usage) {
                    Divider().frame(height: 26)
                    stat(String(format: "$%.0f", model.usageModel.today.cost), "today", .usage)
                }
            }

            if let release = model.updateModel.available {
                HStack {
                    Label("mikko \(release.version) is available", systemImage: "arrow.down.circle")
                        .font(.callout)
                    Spacer()
                    Button("Download") { model.updateModel.download() }.controlSize(.small)
                }
            }

            Divider()
            HStack {
                Button("Open Window") { showWindow() }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.accessibilityLabel("Quit mikko")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.runningModel.refresh(); model.usageModel.reload() }
    }

    private func stat(_ value: String, _ label: String, _ section: AppSection) -> some View {
        Button {
            model.select(section)
            showWindow()
        } label: {
            VStack(spacing: 1) {
                Text(value).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityHint("Opens \(section.title)")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
