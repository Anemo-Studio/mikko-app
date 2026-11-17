import Foundation

/// P-4: one risk vocabulary for every module.
public enum RiskLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    case safe, caution, risky

    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .caution: "Caution"
        case .risky: "Risky"
        }
    }

    /// SF Symbol, so the level never relies on colour alone.
    public var symbolName: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .risky: "exclamationmark.octagon.fill"
        }
    }

    /// Only Safe items are pre-selected and eligible for automation (D-3, D-6).
    public var selectedByDefault: Bool { self == .safe }
}
