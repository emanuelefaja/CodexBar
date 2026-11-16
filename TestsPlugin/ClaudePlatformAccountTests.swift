import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClaudePlatformAccountTests {
    @Test
    func `browser account fields survive persistence limits and redaction`() throws {
        let account = Self.account("chrome", "/synthetic/Default", "org-one")
        let decoded = try JSONDecoder().decode(ProviderTokenAccount.self, from: JSONEncoder().encode(account))
        for copy in [decoded, account.withModelRateLimits([]), account.sanitizedForDump()] {
            #expect(copy.browserID == "chrome")
            #expect(copy.browserProfileID == "/synthetic/Default")
            #expect(copy.organizationID == "org-one")
        }
        #expect(decoded.token.isEmpty)
        #expect(TokenAccountSupportCatalog.support(for: .claudeplatform) != nil)
    }

    @Test
    func `account snapshots isolate browser organization and manual cookie settings`() throws {
        var config = ProviderConfig(id: .claudeplatform)
        config.cookieSource = .auto
        config.cookieHeader = "sessionKey=decoy"
        config.browserID = "edge"
        config.browserProfileID = "/synthetic/decoy"
        config.organizationID = "decoy-org"
        for account in [
            Self.account("chrome", "/synthetic/Default", "org-one"),
            Self.account("safari", "/synthetic/Cookies.binarycookies", "org-two"),
        ] {
            let settings = try Self.settings(config, account)
            #expect(settings.selectedBrowserProfile == account.selectedBrowserProfile)
            #expect(settings.organizationID == account.organizationID)
            #expect(settings.manualCookieHeader == nil)
            #expect(settings.cookieSource == .auto)
        }
        let manual = ProviderTokenAccount(
            id: UUID(), label: "Manual", token: "synthetic-session", addedAt: 0, lastUsed: nil)
        let settings = try Self.settings(config, manual)
        #expect(settings.cookieSource == .manual)
        #expect(settings.manualCookieHeader == "sessionKey=synthetic-session")
        #expect(settings.selectedBrowserProfile == nil)
        #expect(settings.organizationID == nil)
        config.cookieSource = .off
        #expect(try Self.settings(config, manual).cookieSource == .off)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `explicit profiles never invoke automatic import even after authentication failure`(
        engine: ProviderPluginEngineKind) async throws
    {
        for browser in ["chrome", "safari"] {
            let profile = ProviderBrowserProfile(browserID: browser, profileID: "/synthetic/\(browser)")
            let runtime = try BundledPluginTestSupport.runtime(
                "claudeplatform", engine: engine, transport: DeniedTransport())
            var settings = CookieProviderSettings(cookieSource: .auto)
            settings.selectedBrowserProfile = profile
            let broker = ProviderPluginCookieBroker(
                provider: .claudeplatform,
                domains: runtime.manifest.cookieDomains,
                settings: settings,
                batches: { _, _ in Issue.record("Automatic browser fallback"); return nil },
                policy: runtime.manifest.cookiePolicy,
                profileReader: { selected in
                    #expect(selected == profile)
                    return try [ProviderPluginCookieRecord(cookie: #require(HTTPCookie(properties: [
                        .name: "sessionKey", .value: "synthetic-\(browser)",
                        .domain: "platform.claude.com", .path: "/", .secure: "TRUE",
                    ])))]
                })
            let failure = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
                try await runtime.fetchResult(cookies: broker)
            })
            #expect(failure.owner?.profile == profile)
            #expect((failure.underlyingError as? ProviderFetchClassifiedError)?.kind == .authenticationExpired)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional profile policy preserves manual cookies and legacy automatic imports`(
        engine: ProviderPluginEngineKind) throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "claudeplatform",
            engine: engine,
            transport: DeniedTransport())
        let manual = ProviderPluginCookieBroker(
            provider: .claudeplatform,
            domains: runtime.manifest.cookieDomains,
            settings: CookieProviderSettings(cookieSource: .manual, manualCookieHeader: "sessionKey=synthetic-manual"),
            batches: { _, _ in Issue.record("Manual cookies imported a browser"); return nil },
            policy: runtime.manifest.cookiePolicy)
        #expect(try manual.nextSession(domain: "platform.claude.com")?.header == "sessionKey=synthetic-manual")
        #expect(try manual.nextSession(domain: "platform.claude.com") == nil)
        let automatic = ProviderPluginCookieBroker(
            provider: .claudeplatform,
            domains: runtime.manifest.cookieDomains,
            settings: CookieProviderSettings(cookieSource: .auto),
            batches: { _, _ in Issue.record("Unexpected header importer"); return nil },
            jarImporter: { batch in
                guard batch == 0 else { return nil }
                let cookie = try #require(HTTPCookie(properties: [
                    .name: "sessionKey", .value: "synthetic-auto",
                    .domain: "platform.claude.com", .path: "/", .secure: "TRUE",
                ]))
                return [.init(
                    header: "",
                    source: "Synthetic Auto",
                    origin: "https://platform.claude.com",
                    records: [ProviderPluginCookieRecord(cookie: cookie)])]
            },
            policy: runtime.manifest.cookiePolicy)
        #expect(try automatic.nextSession(domain: "platform.claude.com")?.source == "Synthetic Auto")
        #expect(runtime.manifest.cookiePolicy?.optionalSelectedProfile == true)
        #expect(runtime.manifest.cookiePolicy?.allowsImportAttempt(runtime: .app, interaction: .background) == true)
    }

    private static func account(_ browser: String, _ profile: String, _ organization: String) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: browser,
            token: "",
            addedAt: 0,
            lastUsed: nil,
            organizationID: organization,
            browserID: browser,
            browserProfileID: profile)
    }

    private static func settings(
        _ config: ProviderConfig,
        _ account: ProviderTokenAccount) throws -> CookieProviderSettings
    {
        let section = ClaudePlatformProviderDescriptor.descriptor.settingsSection
        let contribution = try #require(section.credentialContribution(context: .init(
            config: config,
            account: account)))
        return try #require(section.cookieSettings(from: ProviderSettingsSnapshot(contributions: [contribution])))
    }

    private struct DeniedTransport: ProviderHTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return try (Data("{}".utf8), #require(HTTPURLResponse(
                url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
        }
    }
}
