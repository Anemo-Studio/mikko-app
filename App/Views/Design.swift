import MikkoCore
import SwiftUI

/// Shared look: generous spacing, one accent, colour only where something needs attention.
enum Calm {
    static let pad: CGFloat = 24
    static let rowHeight: CGFloat = 40
    static let corner: CGFloat = 14
}

/// The headline of a screen: one big statement, one quiet line under it.
struct Headline: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Calm.corner, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Small uppercase label above a group of rows.
struct GroupLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
        }
        .padding(.top, 14).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One thing that wants the person's attention: a sentence and a single action.
struct AttentionItem: Identifiable {
    enum Level { case info, warning, critical }
    let id: String
    var level: Level = .warning
    var symbol: String
    var text: String
    var actionTitle: String
    var action: () -> Void

    var tint: Color {
        switch level {
        case .info: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct AttentionRow: View {
    let item: AttentionItem
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(compact ? .body : .title3)
                .foregroundStyle(item.tint)
                .frame(width: compact ? 20 : 28)
            Text(item.text)
                .font(compact ? .callout : .body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(item.actionTitle, action: item.action)
                .controlSize(compact ? .small : .regular)
        }
        .padding(.vertical, compact ? 6 : 12)
        .padding(.horizontal, compact ? 12 : 16)
        .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: compact ? 10 : Calm.corner, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A quiet number the person can click through to.
struct StatTile: View {
    let symbol: String
    let value: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(height: 68, alignment: .topLeading)
            .card()
            .contentShape(RoundedRectangle(cornerRadius: Calm.corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// The big calm state shown when there is nothing to do.
struct AllQuiet: View {
    var text = "Nothing needs you right now."

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .card()
    }
}
