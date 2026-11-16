import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OpenAIWebAppSettingsTests {
    @Test
    func `explicit Web is available without API credentials or complete setup`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(
            suite: "OpenAIWebAppSettings-availability")
        let implementation = OpenAIAPIProviderImplementation()
        let context = fixture.settingsContext(provider: .openai)
        let availability = ProviderAvailabilityContext(provider: .openai, settings: fixture.settings, environment: [:])
        let picker = implementation.sourcePicker(context: context)
        #expect(picker.options.map(\.id) == ["auto", "api", "web"])
        #expect(picker.binding.wrappedValue == "auto")
        #expect(!implementation.isAvailable(context: availability))
        picker.binding.wrappedValue = "web"
        #expect(implementation.isAvailable(context: availability))
        #expect(implementation.sourceMode(context: .init(provider: .openai, settings: fixture.settings)) == .web)
        #expect(fixture.settings.providerConfig(for: .openai)?.browserProfileID == nil)
        #expect(fixture.settings.providerConfig(for: .openai)?.organizationID == nil)
        picker.binding.wrappedValue = "api"
        #expect(!implementation.isAvailable(context: availability))
    }

    @Test
    func `Web hides API controls but preserves saved keys projects accounts and limits`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "OpenAIWebAppSettings-passive")
        let settings = fixture.settings
        settings.updateProviderConfig(provider: .openai) {
            $0.apiKey = "synthetic-admin-key"
            $0.workspaceID = "proj_synthetic"
            $0.pluginSettings = ["OPENAI_LIVE_MINUTES": "0"]
            $0.modelRateLimits = [.init(model: "synthetic-model", tokensPerMinute: 1234, requestsPerMinute: 12)]
        }
        settings.addTokenAccount(provider: .openai, label: "Synthetic API account", token: "synthetic-account-key")
        let before = try #require(settings.providerConfig(for: .openai))
        let implementation = OpenAIAPIProviderImplementation()
        let context = fixture.settingsContext(provider: .openai)
        let support = try #require(TokenAccountSupportCatalog.support(for: .openai))
        implementation.sourcePicker(context: context).binding.wrappedValue = "web"
        #expect(!implementation.tokenAccountsVisibility(context: context, support: support))
        #expect(implementation.settingsFields(context: context).map(\.id) == ["openai-web-organization"])
        #expect(implementation.settingsToggles(context: context).isEmpty)
        #expect(implementation.settingsModelLimits(context: context).isEmpty)
        #expect(implementation.liveUsageMenuEntries(settings: settings, environment: [:]).isEmpty)
        let after = try #require(settings.providerConfig(for: .openai))
        #expect(after.apiKey == before.apiKey)
        #expect(after.workspaceID == before.workspaceID)
        #expect(after.pluginSettings == before.pluginSettings)
        #expect(after.modelRateLimits == before.modelRateLimits)
        #expect(after.tokenAccounts?.accounts.map(\.id) == before.tokenAccounts?.accounts.map(\.id))
        #expect(after.tokenAccounts?.accounts.map(\.token) == before.tokenAccounts?.accounts.map(\.token))
        #expect(after.tokenAccounts?.activeIndex == before.tokenAccounts?.activeIndex)
        #expect(settings.effectiveSelectedTokenAccount(for: .openai) == nil)
        implementation.sourcePicker(context: context).binding.wrappedValue = "api"
        #expect(implementation.tokenAccountsVisibility(context: context, support: support))
        #expect(implementation.settingsFields(context: context).map(\.id) == ["openai-api-key", "openai-project-id"])
        #expect(!implementation.settingsModelLimits(context: context).isEmpty)
        #expect(!implementation.liveUsageMenuEntries(settings: settings, environment: [:]).isEmpty)
    }

    @Test
    func `profile picker leaves missing selection explicit and does not invent a default`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "OpenAIWebAppSettings-profile")
        let implementation = OpenAIAPIProviderImplementation()
        let context = fixture.settingsContext(provider: .openai)
        let picker = implementation.webProfilePicker(context: context, profiles: [])
        #expect(picker.binding.wrappedValue.isEmpty)
        #expect(picker.options.map(\.id) == [""])
        fixture.settings.updateProviderConfig(provider: .openai) {
            $0.browserID = "chrome"
            $0.browserProfileID = "/synthetic/Chrome/Profile 9"
        }
        let unavailable = implementation.webProfilePicker(context: context, profiles: [])
        #expect(unavailable.options.map(\.id) == ["", "/synthetic/Chrome/Profile 9"])
        #expect(unavailable.options.last?.title.contains("Unavailable profile") == true)
    }

    @Test
    func `source profile and organization edits retire publication before saving`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(
            suite: "OpenAIWebAppSettings-invalidate")
        let implementation = OpenAIAPIProviderImplementation()
        let context = fixture.settingsContext(provider: .openai)
        let bindings = [
            implementation.sourcePicker(context: context).binding,
            implementation.webProfilePicker(context: context, profiles: []).binding,
            implementation.webOrganizationField(context: context).binding,
        ]
        for (binding, value) in zip(bindings, ["web", "/synthetic/Chrome/Profile 9", "org-synthetic"]) {
            fixture.store.snapshots[.openai] = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
            let revision = fixture.store.providerPublicationRevision(for: .openai)
            binding.wrappedValue = value
            #expect(fixture.store.snapshots[.openai] == nil)
            #expect(!fixture.store.providerPublicationRevisionIsCurrent(revision, for: .openai))
            let unchangedRevision = fixture.store.providerPublicationRevision(for: .openai)
            binding.wrappedValue = value
            #expect(fixture.store.providerPublicationRevisionIsCurrent(unchangedRevision, for: .openai))
        }
        let config = try #require(fixture.settings.providerConfig(for: .openai))
        #expect(config.browserID == "chrome")
        #expect(config.browserProfileID == "/synthetic/Chrome/Profile 9")
        #expect(config.organizationID == "org-synthetic")
    }

    @Test
    func `typed settings carry provider scope and only explicit token overrides`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "OpenAIWebAppSettings-snapshot")
        let settings = fixture.settings
        settings.addTokenAccount(provider: .openai, label: "Synthetic", token: "synthetic-key")
        settings.updateProviderConfig(provider: .openai) {
            $0.source = .web
            $0.browserID = "chrome"
            $0.browserProfileID = "/synthetic/Chrome/Profile 9"
            $0.organizationID = "org-synthetic"
        }
        let implementation = OpenAIAPIProviderImplementation()
        let account = try #require(settings.tokenAccounts(for: .openai).first)
        for explicit in [false, true] {
            let contribution = try #require(implementation.settingsSnapshot(context: .init(
                settings: settings,
                tokenOverride: explicit ? .init(provider: .openai, account: account) : nil)))
            let snapshot = ProviderSettingsSnapshot(contributions: [contribution])
            let web = try #require(snapshot[OpenAIWebProviderSettingsKey.self])
            #expect(web.browserID == "chrome")
            #expect(web.browserProfileID == "/synthetic/Chrome/Profile 9")
            #expect(web.organizationID == "org-synthetic")
            #expect(web.hasTokenAccountOverride == explicit)
        }
    }
}
