import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CompactAccountsOverviewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ used: Double = 20, title: String? = nil) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(3600),
            resetDescription: nil,
            title: title)
    }

    @Test
    func `missing account stays unavailable beside a live account`() {
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claude, accountID: "first", name: "Claude", snapshot: UsageSnapshot(
                primary: self.window(), secondary: nil, updatedAt: self.now)),
            .init(provider: .claude, accountID: "second", name: "Claude"),
        ], now: self.now)
        #expect(model.accounts.map(\.label) == ["Claude 1", "Claude 2"])
        #expect(model.accounts.map(\.id) == ["claude/account/first", "claude/account/second"])
        #expect(model.accounts[0].windows[0].left == "80%")
        #expect(model.accounts[1].windows[0].left == "Unavailable")
        #expect(model.accounts[1].windows[0].reset == "Unknown")
        #expect(!model.accounts[1].stale)
    }

    @Test
    func `stale retained and failed data never become fresh zero usage`() {
        let old = UsageSnapshot(primary: self.window(), secondary: nil, updatedAt: self.now.addingTimeInterval(-1800))
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .zai, accountID: "old", name: "GLM", snapshot: old),
            .init(provider: .zai, accountID: "failed", name: "GLM", snapshot: old, error: "Offline"),
            .init(
                provider: .claude,
                name: "Claude",
                snapshot: UsageSnapshot(primary: self.window(), secondary: nil, updatedAt: self.now),
                retained: true),
        ], now: self.now)
        let allStale = model.accounts.allSatisfy(\.stale)
        #expect(allStale)
        #expect(model.accounts[0].windows[0].left == "80%")
        #expect(model.accounts[1].windows[0].left == "Unavailable")
        #expect(model.updatedAt == old.updatedAt)
    }

    @Test
    func `all real windows including scoped Fable stay on their own account`() {
        let snapshot = UsageSnapshot(
            primary: self.window(10, title: "Session"),
            secondary: self.window(30, title: "Weekly"),
            tertiary: self.window(40, title: "Other model"),
            extraRateWindows: [
                NamedRateWindow(id: "claude-weekly-scoped-fable", title: "Fable", window: self.window(60)),
                NamedRateWindow(id: "unknown", title: "Unknown quota", window: self.window(100), usageKnown: false),
            ],
            updatedAt: self.now)
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claude, accountID: "one", name: "Claude", snapshot: snapshot),
            .init(provider: .claude, accountID: "two", name: "Claude"),
        ], now: self.now)
        #expect(model.accounts[0].windows.map(\.label) == [
            "Session",
            "Weekly",
            "Other model",
            "Fable",
            "Unknown quota",
        ])
        #expect(model.accounts[0].windows.map(\.left) == ["90%", "70%", "60%", "40%", "Unavailable"])
        #expect(model.accounts[1].windows.count == 1)
        #expect(model.accounts[1].windows[0].left == "Unavailable")
    }

    @Test
    func `synthetic windows are omitted and genuine zero usage means fully remaining`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: self.window(0),
            updatedAt: self.now)
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claude, name: "Claude", snapshot: snapshot),
        ], now: self.now)
        #expect(model.accounts[0].windows.count == 1)
        #expect(model.accounts[0].windows[0].left == "100%")
    }

    @Test
    func `negative API balances are separate numbers not inferred grant budgets`() {
        let balance = ProviderCostSnapshot(
            used: 123, limit: 999, currencyCode: "USD", balance: -4.25, updatedAt: self.now)
        let snapshot = UsageSnapshot(
            primary: self.window(), secondary: self.window(), providerCost: balance, updatedAt: self.now)
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claudeplatform, name: "API", snapshot: snapshot, balanceOnly: true),
            .init(
                provider: .claudeplatform,
                accountID: "missing",
                name: "API",
                snapshot: UsageSnapshot(
                    primary: nil,
                    secondary: nil,
                    providerCost: ProviderCostSnapshot(
                        used: 5, limit: 100, currencyCode: "USD", updatedAt: self.now),
                    updatedAt: self.now),
                balanceOnly: true),
        ], now: self.now)
        #expect(model.accounts.isEmpty)
        #expect(model.balances.count == 2)
        #expect(model.balances[0].windows[0].left == CompactAccountsOverview.balanceText(-4.25, currency: "USD"))
        #expect(model.balances[0].windows[0].left != CompactAccountsOverview.balanceText(4.25, currency: "USD"))
        #expect(model.balances[1].windows[0].left == "Unavailable")
    }

    @Test
    func `balance classification uses snapshot kind not display label`() {
        let model = CompactAccountsOverview(inputs: [
            .init(provider: .claudeplatform, name: "Unrelated label", snapshot: UsageSnapshot(
                primary: self.window(), secondary: nil, iconProvider: .claudeplatform, updatedAt: self.now)),
        ], now: self.now)
        #expect(model.accounts.isEmpty)
        #expect(model.balances[0].windows[0].left == "Unavailable")
    }

    @Test
    func `configured names and prices replace generated ordinals`() {
        let slots = CompactAccountPresentations(accounts: [
            "1": .init(name: "Claude Ultra 1", monthlyPriceUSD: 200),
            "2": .init(name: "Claude Ultra 2", monthlyPriceUSD: 200),
        ])
        let model = CompactAccountsOverview(inputs: [
            .init(
                provider: .claude,
                accountID: "one",
                name: "Claude",
                snapshot: UsageSnapshot(primary: self.window(), secondary: nil, updatedAt: self.now),
                presentations: slots),
            .init(provider: .claude, accountID: "two", name: "Claude", presentations: slots),
            .init(provider: .claude, accountID: "three", name: "Claude"),
        ], now: self.now)
        #expect(model.accounts.map(\.label) == ["Claude Ultra 1", "Claude Ultra 2", "Claude 3"])
        #expect(model.accounts.map(\.monthlyPrice) == ["$200", "$200", nil])
        #expect(model.accounts.map(\.id) == ["claude/account/one", "claude/account/two", "claude/account/three"])
    }

    @Test
    func `price text is fixed USD and never negative`() {
        #expect(CompactAccountsOverview.monthlyPriceText(200) == "$200")
        #expect(CompactAccountsOverview.monthlyPriceText(12.5) == "$12.50")
        #expect(CompactAccountsOverview.monthlyPriceText(0) == "$0")
        #expect(CompactAccountsOverview.monthlyPriceText(-1) == nil)
        #expect(CompactAccountsOverview.monthlyPriceText(.infinity) == nil)
    }

    @Test
    func `reset without a future timestamp is unknown never zero`() {
        #expect(CompactAccountsOverview.resetText(nil, now: self.now) == "Unknown")
        #expect(CompactAccountsOverview.resetText(self.now, now: self.now) == "Unknown")
        #expect(CompactAccountsOverview.resetText(self.now.addingTimeInterval(-30), now: self.now) == "Unknown")
        #expect(CompactAccountsOverview.resetText(self.now.addingTimeInterval(1), now: self.now) == "1m")
        #expect(CompactAccountsOverview.resetText(self.now.addingTimeInterval(3600), now: self.now) == "1h 0m")
    }

    @Test
    func `two GLM accounts keep distinct values and private identities in help only`() {
        let model = CompactAccountsOverview(inputs: [
            .init(
                provider: .zai,
                accountID: "a",
                name: "GLM",
                identity: "first@example.invalid",
                snapshot: UsageSnapshot(
                    primary: self.window(20), secondary: nil, updatedAt: self.now)),
            .init(
                provider: .zai,
                accountID: "b",
                name: "GLM",
                identity: "second@example.invalid",
                snapshot: UsageSnapshot(
                    primary: self.window(80), secondary: nil, updatedAt: self.now)),
        ], now: self.now)
        #expect(model.accounts.map(\.label) == ["GLM 1", "GLM 2"])
        #expect(model.accounts.map { $0.windows[0].left } == ["80%", "20%"])
        #expect(model.accounts[0].help == "first@example.invalid")
        #expect(!model.accounts[0].stale)
    }
}
