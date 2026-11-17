import MikkoCore
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("menuBarMetric") private var metric: MenuBarMetric = .freeDisk
    @AppStorage("onboardingDone") private var onboardingDone = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if let text { Text(text).monospacedDigit() }
        }
        .accessibilityLabel("mikko" + (text.map { ", \($0)" } ?? ""))
        .task {
            // First launch (K-4): a menu bar app shows no window by default, so open onboarding once.
            if !onboardingDone {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var symbol: String {
        switch model.attention {
        case .calm: "eye"
        case .warning: "eye.trianglebadge.exclamationmark"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    private var text: String? {
        switch metric {
        case .freeDisk: model.disk.map { ByteFormat.string($0.free) }
        case .runningCount: String(model.runningModel.visibleItems.filter { $0.kind != .other }.count)
        case .none: nil
        }
    }
}
