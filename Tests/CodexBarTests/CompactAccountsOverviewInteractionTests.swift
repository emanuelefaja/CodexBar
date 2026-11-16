import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CompactAccountsOverviewInteractionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test
    func `second account maps by original ID even after inventory reordering`() {
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claude, accountID: self.firstID.uuidString, name: "Claude"),
            .init(provider: .claude, accountID: self.secondID.uuidString, name: "Claude"),
        ], now: self.now)
        let second = model.accounts[1]
        #expect(second.label == "Claude 2")
        #expect(second.accountID == self.secondID.uuidString)
        #expect(second.detailTarget(tokenAccountIDs: [self.firstID, self.secondID]) == .tokenAccount(self.secondID))
        #expect(second.detailTarget(tokenAccountIDs: [self.secondID, self.firstID]) == .tokenAccount(self.secondID))
        #expect(second.detailTarget(tokenAccountIDs: [self.firstID]) == .readOnly)
        #expect(second.detailTarget(tokenAccountIDs: [self.secondID, self.secondID]) == .readOnly)
    }

    @Test
    func `API account mapping uses the same stable token identity as quota accounts`() {
        let model = CompactAccountsOverview(inputs: [
            .init(
                provider: .claudeplatform,
                accountID: self.secondID.uuidString,
                name: "Claude API",
                balanceOnly: true),
        ], now: self.now)
        #expect(model.balances[0].accountID == self.secondID.uuidString)
        #expect(model.balances[0].detailTarget(tokenAccountIDs: [self.firstID, self.secondID])
            == .tokenAccount(self.secondID))
    }

    @Test
    func `managed Codex IDs remain opaque and never map another provider to Codex`() {
        let id = "profile:/fixture/account/second"
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .codex, accountID: id, name: "Codex"),
            .init(provider: .claude, accountID: id, name: "Claude"),
        ], now: self.now)
        #expect(model.accounts[0].accountID == id)
        #expect(model.accounts[0].detailTarget(codexAccountIDs: [id]) == .codexAccount(id))
        #expect(model.accounts[0].detailTarget(codexAccountIDs: ["other"]) == .readOnly)
        #expect(model.accounts[1].detailTarget(codexAccountIDs: [id]) == .readOnly)
    }

    @Test
    func `adapter unknown and removed accounts never fall back to active provider details`() {
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claude, accountID: "claude-swap:2", name: "Claude"),
            .init(provider: .claude, accountID: "tcr:2", name: "Claude"),
            .init(provider: .claude, accountID: "unknown", name: "Claude"),
            .init(provider: .claude, accountID: self.secondID.uuidString, name: "Claude"),
            .init(provider: .codex, name: "Codex"),
        ], now: self.now)
        #expect(model.accounts.prefix(4).allSatisfy {
            $0.detailTarget(tokenAccountIDs: [self.firstID]) == .readOnly
        })
        #expect(model.accounts[4].detailTarget() == .provider)
    }

    @Test
    func `quota severity uses remaining numeric value and unavailable stays neutral`() {
        let values: [Double] = [100, 120, 80, 79, 0, .nan]
        let windows = values.enumerated().map { index, used in
            NamedRateWindow(
                id: "quota-\(index)",
                title: "Quota \(index)",
                window: RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil))
        }
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: windows, updatedAt: self.now)
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claude, name: "Claude", snapshot: snapshot),
            .init(provider: .zai, name: "GLM", snapshot: snapshot, error: "Unavailable"),
        ], now: self.now)
        #expect(model.accounts[0].windows.map(\.severity) == [.critical, .critical, .low, .neutral, .neutral, .neutral])
        #expect(model.accounts[0].windows.last?.left == "Unavailable")
        #expect(model.accounts[1].windows.allSatisfy { $0.left == "Unavailable" && $0.severity == .neutral })
        #expect(CompactAccountsOverview.quotaSeverity(nil) == .neutral)
    }

    @Test
    func `balance severity uses numeric sign not a localized currency string`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0, limit: 0, currencyCode: "EUR", balance: -0.01, updatedAt: self.now),
            updatedAt: self.now)
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claudeplatform, name: "API", snapshot: snapshot, balanceOnly: true),
            .init(provider: .claudeplatform, name: "API", snapshot: snapshot, error: "Offline", balanceOnly: true),
            .init(provider: .claudeplatform, name: "API", balanceOnly: true),
        ], now: self.now)
        #expect(model.balances.map { $0.windows[0].severity } == [.critical, .neutral, .neutral])
        #expect(CompactAccountsOverview.balanceSeverity(0) == .neutral)
        #expect(CompactAccountsOverview.balanceSeverity(1) == .neutral)
        #expect(CompactAccountsOverview.balanceSeverity(.nan) == .neutral)
        #expect(CompactAccountsOverview.balanceSeverity(.infinity) == .neutral)
    }
}
