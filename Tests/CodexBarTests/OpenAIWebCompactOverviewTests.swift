import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct OpenAIWebCompactOverviewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let profile = ProviderBrowserProfile(browserID: "chrome", profileID: "/synthetic/Chrome/Profile 9")

    @Test
    func `three API balances remain independent beside all five subscriptions`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "OpenAIWebCompact-balances")
        let settings = fixture.settings
        let store = fixture.store
        settings.hidePersonalInfo = false
        for provider in [UsageProvider.claude, .zai, .claudeplatform] {
            for index in 1...2 {
                settings.addTokenAccount(provider: provider, label: "Synthetic \(index)", token: "synthetic-\(index)")
            }
            store.accountSnapshots[provider.instanceID] = settings.tokenAccounts(for: provider).enumerated()
                .map { index, account in
                    TokenAccountUsageSnapshot(
                        account: account,
                        snapshot: self.snapshot(balance: provider == .claudeplatform ? Double(index + 1) : nil),
                        error: nil,
                        sourceLabel: "synthetic",
                        cacheKey: store.tokenAccountSnapshotCacheKey(provider: provider, account: account))
                }
        }
        store.snapshots[.codex] = self.snapshot()
        self.configureWeb(settings)
        // These saved API credentials must not create duplicate browser-credit rows.
        settings.addTokenAccount(provider: .openai, label: "Synthetic key A", token: "synthetic-key-a")
        settings.addTokenAccount(provider: .openai, label: "Synthetic key B", token: "synthetic-key-b")
        store.snapshots[.openai] = try self.webSnapshot(balance: 3)
        let model = CompactAccountsOverview(inputs: store.compactOverviewInputs(
            for: [.claude, .zai, .codex, .claudeplatform, .openai]), now: self.now)
        #expect(model.accounts.count == 5)
        #expect(model.accounts.map(\.label) == ["Claude 1", "Claude 2", "GLM 1", "GLM 2", "Codex"])
        #expect(model.balances.map(\.label) == ["Claude API 1", "Claude API 2", "OpenAI API"])
        #expect(model.balances.map { $0.windows[0].left } == [1.0, 2.0, 3.0].map {
            CompactAccountsOverview.balanceText($0, currency: "USD")
        })
        #expect(model.balances.last?.accountID == nil)
        #expect(model.balances.last?.help == "synthetic-web@example.invalid")
        #expect(model.balances.allSatisfy { $0.windows.count == 1 })
    }

    @Test
    func `missing Web data is one unavailable balance with no borrowed quota identity or credential`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "OpenAIWebCompact-unavailable")
        self.configureWeb(fixture.settings)
        fixture.settings.addTokenAccount(provider: .openai, label: "Synthetic API key", token: "synthetic-key")
        fixture.store.snapshots[.codex] = self.snapshot(balance: 91)
        let model = CompactAccountsOverview(inputs: fixture.store.compactOverviewInputs(for: [.openai]), now: self.now)
        #expect(model.accounts.isEmpty)
        #expect(model.balances.count == 1)
        #expect(model.balances[0].label == "OpenAI API")
        #expect(model.balances[0].windows[0].left == "Unavailable")
        #expect(model.balances[0].accountID == nil)
        #expect(model.balances[0].help.isEmpty)
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .openai) == nil)
    }

    @Test
    func `API mode retains its account inventory without borrowing the provider snapshot`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "OpenAIWebCompact-api")
        fixture.settings.updateProviderConfig(provider: .openai) { $0.source = .api }
        for index in 1...2 {
            fixture.settings.addTokenAccount(
                provider: .openai, label: "Synthetic \(index)", token: "synthetic-\(index)")
        }
        fixture.store.snapshots[.openai] = self.snapshot(balance: 47)
        let model = CompactAccountsOverview(inputs: fixture.store.compactOverviewInputs(for: [.openai]), now: self.now)
        #expect(model.accounts.isEmpty)
        #expect(model.balances.map(\.label) == ["OpenAI API 1", "OpenAI API 2"])
        #expect(model.balances.allSatisfy { $0.windows[0].left == "Unavailable" })
    }

    @Test(arguments: ["source", "browser", "profile", "organization"])
    func `external config changes cannot render the previous browser balance`(field: String) throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "OpenAIWebCompact-reload-\(field)")
        self.configureWeb(fixture.settings)
        fixture.store.snapshots[.openai] = try self.webSnapshot(balance: 3)
        let priorConfigRevision = fixture.settings.providerConfigRevision(for: .openai)
        var config = fixture.settings.configSnapshot
        var provider = try #require(config.providerConfig(for: .openai))
        switch field {
        case "source": provider.source = .api
        case "browser": provider.browserID = "safari"
        case "profile": provider.browserProfileID = "/synthetic/Chrome/Profile 10"
        default: provider.organizationID = "org-synthetic-other"
        }
        config.setProviderConfig(provider)
        fixture.settings.applyExternalConfig(config, reason: "synthetic-reload", origin: .localFile)
        #expect(fixture.settings.providerConfigRevision(for: .openai) != priorConfigRevision)
        #expect(fixture.store.snapshot(for: .openai) == nil)
        let model = CompactAccountsOverview(inputs: fixture.store.compactOverviewInputs(for: [.openai]), now: self.now)
        #expect(model.accounts.isEmpty)
        #expect(model.balances.count == 1)
        #expect(model.balances[0].windows[0].left == "Unavailable")
        #expect(model.balances[0].help.isEmpty)
    }

    @Test
    func `Web never reuses an API snapshot without matching browser ownership`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "OpenAIWebCompact-old-api")
        self.configureWeb(fixture.settings)
        fixture.store.snapshots[.openai] = self.snapshot(balance: 47)
        #expect(fixture.store.snapshot(for: .openai) == nil)
        let model = CompactAccountsOverview(inputs: fixture.store.compactOverviewInputs(for: [.openai]), now: self.now)
        #expect(model.balances.count == 1)
        #expect(model.balances[0].windows[0].left == "Unavailable")
    }

    private func configureWeb(_ settings: SettingsStore) {
        settings.updateProviderConfig(provider: .openai) {
            $0.source = .web
            $0.browserID = self.profile.browserID
            $0.browserProfileID = self.profile.profileID
            $0.organizationID = "org-synthetic"
        }
    }

    private func snapshot(balance: Double? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primary: .init(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: balance.map {
                ProviderCostSnapshot(used: 0, limit: 0, currencyCode: "USD", balance: $0, updatedAt: self.now)
            },
            updatedAt: self.now)
    }

    private func webSnapshot(balance: Double) throws -> UsageSnapshot {
        try UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(used: 0, limit: 0, currencyCode: "USD", balance: balance, updatedAt: self.now),
            browserSessionOwner: ProviderBrowserSessionOwner(
                provider: .openai,
                profile: self.profile,
                organizationID: "org-synthetic",
                accessToken: "synthetic-token"),
            updatedAt: self.now,
            identity: .init(
                providerID: .openai,
                accountEmail: "synthetic-web@example.invalid",
                accountOrganization: "Synthetic Organization",
                loginMethod: "Browser"))
    }
}
