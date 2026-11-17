import Testing
@testable import MikkoCore

@Test func riskOrderingAndDefaults() {
    #expect(RiskLevel.safe < .caution && RiskLevel.caution < .risky)
    #expect(RiskLevel.allCases.filter(\.selectedByDefault) == [.safe])
}
