import MikkoCore
import SwiftUI

/// K-4: three short steps — what mikko does, permissions, what it found.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0: promise
            case 1: PermissionsView()
            default: found
            }
            Spacer(minLength: 0)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button("Skip") { finish() }
                Button(step == 2 ? "Done" : "Continue") {
                    if step == 2 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540, height: 420)
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: 12) {
            Headline(title: "Welcome to mikko",
                     subtitle: "See what you and your AI agents left on this Mac — and stop, clean or find it safely.")
                .padding(.bottom, 6)
            point("trash", "Nothing is deleted for good without asking", "Files go to the Trash. Stopped servers can be undone.")
            point("lock.shield", "Everything stays on this Mac", "No account, no telemetry, no cloud.")
            point("scope", "Developer tools only", "mikko never touches source files, .git or .env.")
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 12) {
            Headline(title: "Found on this Mac")
            let tools = DevTool.allCases.filter(model.detectedTools.contains)
            if tools.isEmpty {
                Text("No developer tools found yet. mikko will pick them up when they appear.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(tools, id: \.self) { Label($0.displayName, systemImage: "checkmark.circle.fill") }
                }
            }
            if let disk = model.disk {
                Text("\(ByteFormat.string(disk.free)) free of \(ByteFormat.string(disk.total))")
                    .font(.title3)
                    .padding(.top, 8)
            }
            let running = model.runningModel.visibleItems.filter { $0.kind != .other }.count
            HStack(spacing: 8) {
                if model.diskModel.isScanning { ProgressView().controlSize(.small) }
                Text("\(ByteFormat.string(model.diskModel.safeReclaimable)) can be safely reclaimed\(model.diskModel.isScanning ? " so far" : "") · \(running) things are running")
                    .font(.headline)
            }
        }
        .onAppear { if !model.diskModel.hasScanned, !model.diskModel.isScanning { model.diskModel.scan() } }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
