import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct OpenAIWebCostPresentationTests {
    @Test(arguments: [12.25, 0, -4.75])
    func `explicit available balance reaches the final credit section`(balance: Double) throws {
        let cost = Self.cost(balance: balance)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: cost,
            updatedAt: cost.updatedAt)
        let presentation = OpenAIAPIProviderDescriptor.descriptor.presentation.cost(snapshot: snapshot)
        #expect(presentation.menuCardStyle == .prepaidCredits)
        let section = try #require(UsageMenuCardView.Model.providerCostSection(
            cost: cost,
            style: presentation.menuCardStyle,
            percentStyle: .left,
            preferredCurrencyCode: "USD"))
        #expect(section.spendLine == "Balance: \(UsageFormatter.currencyString(balance, currencyCode: "USD"))")
    }

    @Test
    func `legacy prepaid providers retain used as balance`() throws {
        let section = try #require(UsageMenuCardView.Model.providerCostSection(
            cost: Self.cost(balance: nil),
            style: .prepaidCredits,
            percentStyle: .left,
            preferredCurrencyCode: "USD"))
        #expect(section.spendLine == "Balance: $91.00")
    }

    private static func cost(balance: Double?) -> ProviderCostSnapshot {
        ProviderCostSnapshot(
            used: 91,
            limit: 0,
            currencyCode: "USD",
            period: "API credits",
            balance: balance,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
