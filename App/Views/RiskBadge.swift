import MikkoCore
import SwiftUI

extension RiskLevel {
    var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .risky: .red
        }
    }
}

/// P-4: same shape + word + colour everywhere, so colour is never the only signal.
struct RiskBadge: View {
    let level: RiskLevel
    var body: some View {
        Label(level.label, systemImage: level.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(level.color)
            .accessibilityLabel("Risk level: \(level.label)")
    }
}
