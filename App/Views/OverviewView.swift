import MikkoCore
import SwiftUI

/// The home screen answers one question: does anything need me? Everything else is one click away.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Headline(title: model.headline, subtitle: subtitle)

                let items = model.attentionItems
                if items.isEmpty {
                    AllQuiet()
                } else {
                    VStack(spacing: 10) { ForEach(items.prefix(5)) { AttentionRow(item: $0) } }
                }

                HStack(spacing: 12) {
                    let running = model.runningDevItems
                    StatTile(symbol: AppSection.running.symbol, value: "\(running.count)",
                             label: running.isEmpty ? "Nothing running" : "running · \(ByteFormat.string(Int64(running.reduce(0) { $0 + $1.memory })))") { model.select(.running) }
                    StatTile(symbol: AppSection.disk.symbol, value: model.disk.map { ByteFormat.string($0.free) } ?? "–", label: "free disk space") { model.select(.disk) }
                    if model.visibleSections.contains(.usage) {
                        StatTile(symbol: AppSection.usage.symbol, value: String(format: "$%.0f", model.usageModel.today.cost), label: "today, at API prices") { model.select(.usage) }
                    }
                }

                if !model.diskModel.hasScanned {
                    HStack {
                        Text("See how much space your dev tools are holding.").foregroundStyle(.secondary)
                        Spacer()
                        Button(model.diskModel.isScanning ? "Scanning…" : "Scan Disk") { model.diskModel.scan() }.disabled(model.diskModel.isScanning)
                    }
                    .card()
                }
            }
            .padding(Calm.pad)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.usageModel.reload() }
    }

    private var subtitle: String {
        let agents = model.runningModel.visibleItems.filter { $0.kind == .agent }.count
        return agents == 0 ? "No agent sessions open." : "\(agents) agent session\(agents == 1 ? "" : "s") open."
    }
}
