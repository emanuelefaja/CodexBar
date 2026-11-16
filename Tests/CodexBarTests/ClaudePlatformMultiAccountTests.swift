import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

private actor ClaudePlatformAccountFixture {
    var rejectSafari = false
    func reject() { self.rejectSafari = true }

    func fetch(_ context: ProviderFetchContext) throws -> UsageSnapshot {
        let settings = try #require(context.settings?[ClaudePlatformProviderSettingsKey.self])
        let browser = try #require(settings.selectedBrowserProfile?.browserID)
        #expect(settings.organizationID == "org-\(browser)")
        #expect(settings.manualCookieHeader == nil)
        if browser == "safari", self.rejectSafari {
            throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "Synthetic expired session")
        }
        let balance = browser == "chrome" ? -2.52 : 0.0
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: balance,
                limit: 0,
                currencyCode: "USD",
                period: "Prepaid credits",
                balance: balance,
                updatedAt: Date()), updatedAt: Date())
    }
}

private struct ClaudePlatformAccountStrategy: ProviderFetchStrategy {
    let fixture: ClaudePlatformAccountFixture
    let id = "claudeplatform-fixture"
    let kind: ProviderFetchKind = .web
    func isAvailable(_: ProviderFetchContext) async -> Bool { true }
    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await self.fixture.fetch(context)
        return self.makeResult(usage: usage, sourceLabel: "web")
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool { false }
}

@MainActor
@Suite(.serialized)
struct ClaudePlatformMultiAccountTests {
    @Test
    func `two browser accounts keep independent cache and authentication failures`() async throws {
        let settings = Self.makeSettings()
        Self.addAccounts(settings)
        let accounts = settings.tokenAccounts(for: .claudeplatform)
        #expect(accounts.count == 2)
        let fixture = ClaudePlatformAccountFixture()
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let base = try #require(store.providerSpecs[.claudeplatform])
        let descriptor = base.descriptor
        let strategy = ClaudePlatformAccountStrategy(fixture: fixture)
        store.providerSpecs[.claudeplatform] = ProviderSpec(
            style: base.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .claudeplatform,
                metadata: descriptor.metadata,
                branding: descriptor.branding,
                tokenCost: descriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .web],
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: descriptor.cli),
            makeFetchContext: base.makeFetchContext)
        await store.refreshTokenAccounts(provider: .claudeplatform, accounts: accounts)
        let first = try #require(store.accountSnapshots[.claudeplatform])
        #expect(first.map { $0.snapshot?.providerCost?.balance } == [-2.52, 0])
        #expect(first[0].cacheKey != first[1].cacheKey)
        await fixture.reject()
        // Existing failure policy can debounce a transient failure; auth must eventually clear only its own row.
        for _ in 0..<2 {
            await store.refreshTokenAccounts(provider: .claudeplatform, accounts: accounts)
        }
        let failed = try #require(store.accountSnapshots[.claudeplatform])
        #expect(failed[0].snapshot?.providerCost?.balance == -2.52)
        #expect(failed[0].error == nil)
        #expect(failed[1].snapshot == nil)
        #expect(failed[1].error != nil)
        #expect(store.snapshots[.claudeplatform] == nil)
    }

    @Test
    func `CLI all accounts routes profiles and edits preserve or replace their typed fields`() throws {
        let settings = Self.makeSettings()
        Self.addAccounts(settings)
        let account = try #require(settings.tokenAccounts(for: .claudeplatform).first)
        settings.updateTokenAccount(provider: .claudeplatform, accountID: account.id, label: "Renamed")
        let context = try TokenAccountCLIContext(
            selection: .init(label: nil, index: nil, allAccounts: true),
            config: settings.configSnapshot,
            verbose: false,
            baseEnvironment: [:])
        let accounts = try context.resolvedAccounts(for: .claudeplatform)
        #expect(accounts.map(\.browserID) == ["chrome", "safari"])
        for account in accounts {
            let snapshot = context.settingsSnapshot(for: .claudeplatform, account: account)
            #expect(snapshot?[ClaudePlatformProviderSettingsKey.self]?.selectedBrowserProfile == account
                .selectedBrowserProfile)
        }
        settings.updateTokenAccount(
            provider: .claudeplatform,
            accountID: account.id,
            token: "sessionKey=synthetic-manual",
            browserID: .some(nil),
            browserProfileID: .some(nil))
        #expect(settings.tokenAccounts(for: .claudeplatform).first?.selectedBrowserProfile == nil)
    }

    private static func addAccounts(_ settings: SettingsStore) {
        for browser in ["chrome", "safari"] {
            settings.addTokenAccount(
                provider: .claudeplatform,
                label: browser,
                token: "",
                organizationID: "org-\(browser)",
                browserID: browser,
                browserProfileID: "/synthetic/\(browser)")
        }
    }

    private static func makeSettings() -> SettingsStore {
        testSettingsStore(
            suiteName: "ClaudePlatformMultiAccountTests-\(UUID())",
            userDefaults: InMemoryUserDefaults(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
