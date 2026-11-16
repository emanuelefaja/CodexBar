import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct OpenAIWebFetchTests {
    @Test(arguments: [12.25, 0, -4.75])
    func `reported available balance is used without grant arithmetic`(available: Double) async throws {
        let requests = LockIsolated<[URLRequest]>([])
        let reads = LockIsolated(0)
        let strategy = OpenAIWebFetchStrategy(
            tokenLoader: { profile in
                #expect(profile == Fixture.profile)
                reads.setValue(reads.value + 1)
                return Fixture.token
            },
            clock: { Fixture.now },
            transport: ProviderHTTPTransportHandler { request in
                requests.setValue(requests.value + [request])
                let body = request.httpMethod == "POST" ? Fixture.login : Fixture.credits(available)
                return try Fixture.response(request, body: body)
            })
        let result = try await strategy.fetch(Fixture.context())
        let usage = result.usage
        #expect(requests.value.count == 2)
        #expect(reads.value == 2)
        let login = try #require(requests.value.first)
        #expect(login.httpMethod == "POST")
        #expect(login.url?.absoluteString == "https://api.openai.com/v1/dashboard/onboarding/login")
        #expect(login.value(forHTTPHeaderField: "Authorization") == "Bearer " + Fixture.token)
        #expect(login.value(forHTTPHeaderField: "OpenAI-Organization") == nil)
        #expect(login.httpBody == Data(#"{"app":"api"}"#.utf8))
        let credits = requests.value[1]
        #expect(credits.httpMethod == "GET")
        #expect(credits.url?.absoluteString == "https://api.openai.com/v1/dashboard/billing/credit_grants")
        #expect(credits.value(forHTTPHeaderField: "Authorization") == "Bearer sess-synthetic")
        #expect(credits.value(forHTTPHeaderField: "OpenAI-Organization") == "org-pinned")
        #expect(requests.value.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        #expect(requests.value.allSatisfy { !$0.httpShouldHandleCookies && $0.timeoutInterval <= 20 })
        #expect(usage.providerCost?.balance == available)
        #expect(usage.providerCost?.used == 91)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "API credits")
        #expect(usage.providerCost?.balanceUpdatedAt == Fixture.now)
        #expect(usage.providerCost?.resetsAt == nil)
        #expect(usage.subscriptionRenewsAt == nil)
        #expect(usage.primary == nil && usage.secondary == nil && usage.tertiary == nil)
        #expect(usage.openAIAPIUsage == nil)
        #expect(usage.identity?.providerID == .openai)
        #expect(usage.identity?.accountEmail == "fixture@example.invalid")
        #expect(usage.identity?.accountOrganization == "Pinned organization")
        #expect(usage.browserSessionOwner != nil)
        #expect(usage.browserSessionOwner?.organizationID == "org-pinned")
        let presentation = OpenAIAPIProviderDescriptor.descriptor.presentation.cost(snapshot: usage)
        #expect(presentation.menuCardStyle == .prepaidCredits)
        #expect(!presentation.showsGenericFallback)
        #expect(presentation.balances.first?.amount == available)
        let encoded = try JSONEncoder().encode(usage)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains(Fixture.token))
        #expect(!text.contains("sess-synthetic"))
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(restored.browserSessionOwner == nil)
    }

    @Test(arguments: [
        "{}",
        #"{"total_available":null,"total_used":1}"#,
        #"{"total_available":"9","total_used":1}"#,
        #"{"total_available":9}"#,
        #"{"total_available":1e999,"total_used":1}"#,
    ])
    func `missing and malformed totals fail closed`(body: String) async {
        await Fixture.expectFailure(credits: body)
    }

    @Test(arguments: ["null", "2000000000"])
    func `session expiry can be null or a future epoch`(expiry: String) async throws {
        let body = Fixture.login.replacingOccurrences(of: "\"expires_at\":null", with: "\"expires_at\":" + expiry)
        _ = try await Fixture.strategy(login: body).fetch(Fixture.context())
    }

    @Test(arguments: ["0", "1699999999", "\"future\"", "false", "1e999"])
    func `invalid session expiry is rejected before billing`(expiry: String) async {
        await Fixture.expectFailure(
            login: Fixture.login.replacingOccurrences(of: "\"expires_at\":null", with: "\"expires_at\":" + expiry),
            expectedRequests: 1)
    }

    @Test(arguments: [
        ("\"enabled\":true", "\"enabled\":false"),
        ("\"deleted_at\":null", "\"deleted_at\":1700000001"),
        ("\"expires_at\":null,", ""),
        ("\"deleted_at\":null,", ""),
        ("org-pinned", "org-other"),
        ("sess-synthetic", "not-a-session"),
        ("\"data\":[", "\"data\":[{\"id\":\"org-pinned\"},"),
    ])
    func `invalid sessions and ambiguous or mismatched membership never reach billing`(
        replacement: (String, String)) async
    {
        await Fixture.expectFailure(
            login: Fixture.login.replacingOccurrences(of: replacement.0, with: replacement.1), expectedRequests: 1)
    }

    @Test
    func `organization title falls back to name and ignores default membership`() async throws {
        let login = Fixture.login.replacingOccurrences(of: "\"title\":\"Pinned organization\",", with: "")
        let result = try await Fixture.strategy(login: login).fetch(Fixture.context())
        #expect(result.usage.identity?.accountOrganization == "pinned-name")
    }

    @Test(arguments: [401, 403, 302, 429, 500])
    func `login failure does not retry or fall back`(status: Int) async {
        let requests = LockIsolated(0)
        let strategy = OpenAIWebFetchStrategy(
            tokenLoader: { _ in Fixture.token },
            clock: { Fixture.now },
            transport: ProviderHTTPTransportHandler { request in
                requests.setValue(requests.value + 1)
                return try Fixture.response(
                    request,
                    status: status,
                    body: Fixture.token)
            })
        await Fixture.failure(strategy)
        #expect(requests.value == 1)
        #expect(!strategy.shouldFallback(on: OpenAIWebError.requestFailed, context: Fixture.context()))
    }

    @Test(arguments: ["", "not-a-jwt", "a.e30.b", Fixture.jwt(expiry: 1_600_000_000)])
    func `missing malformed and expired access tokens never reach HTTP`(token: String) async {
        let requests = LockIsolated(0)
        let strategy = OpenAIWebFetchStrategy(
            tokenLoader: { _ in token },
            clock: { Fixture.now },
            transport: ProviderHTTPTransportHandler { _ in
                requests.setValue(requests.value + 1)
                throw OpenAIWebError.requestFailed
            })
        let failure = await Fixture.failure(strategy)
        #expect(failure?.localizedDescription.contains("Reopen platform.openai.com") == true)
        #expect(requests.value == 0)
    }

    @Test
    func `profile org and token account checks precede token access`() async {
        let reads = LockIsolated(0)
        let strategy = OpenAIWebFetchStrategy(tokenLoader: { _ in
            reads.setValue(reads.value + 1)
            return Fixture.token
        }, transport: ProviderHTTPTransportHandler { _ in throw OpenAIWebError.requestFailed })
        let settings: [OpenAIWebSettings] = [
            .init(),
            .init(browserID: "chrome", browserProfileID: Fixture.profile.profileID),
            .init(browserID: "safari", browserProfileID: Fixture.profile.profileID, organizationID: "org-pinned"),
            .init(browserID: "chrome", browserProfileID: Fixture.profile.profileID, organizationID: "org-pinned\r\nx"),
            .init(
                browserID: "chrome",
                browserProfileID: Fixture.profile.profileID,
                organizationID: "org-pinned",
                hasTokenAccountOverride: true),
        ]
        for setting in settings {
            await Fixture.failure(strategy, context: Fixture.context(settings: setting))
        }
        await Fixture.failure(strategy, context: Fixture.context(accountID: UUID()))
        #expect(reads.value == 0)
    }

    @Test
    func `session changes fail closed without an owner`() async {
        let reads = LockIsolated(0)
        let strategy = OpenAIWebFetchStrategy(
            tokenLoader: { _ in
                reads.setValue(reads.value + 1)
                return reads.value == 1 ? Fixture.token : Fixture.jwt(expiry: 2_100_000_000)
            },
            clock: { Fixture.now },
            transport: Fixture.transport())
        let failure = await Fixture.failure(strategy)
        #expect(failure?.localizedDescription.contains("session changed") == true)
        #expect(reads.value == 2)
    }

    @Test
    func `transport cancellation is preserved but unsafe errors are redacted`() async {
        let cancelled = OpenAIWebFetchStrategy(
            tokenLoader: { _ in Fixture.token },
            clock: { Fixture.now },
            transport: ProviderHTTPTransportHandler { _ in
                throw CancellationError()
            })
        let failure = await Fixture.failure(cancelled)
        #expect(failure?.underlyingError is CancellationError)
        let unsafe = OpenAIWebFetchStrategy(
            tokenLoader: { _ in Fixture.token },
            clock: { Fixture.now },
            transport: ProviderHTTPTransportHandler { _ in
                throw NSError(
                    domain: "synthetic",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: Fixture.token])
            })
        await Fixture.failure(unsafe)
    }

    @Test
    func `expiry during fetch blocks publication`() async {
        let clock = LockIsolated(Fixture.now)
        let strategy = OpenAIWebFetchStrategy(
            tokenLoader: { _ in Fixture.token },
            clock: { clock.value },
            transport: ProviderHTTPTransportHandler { request in
                if request
                    .httpMethod ==
                    "GET"
                {
                    clock.setValue(Date(timeIntervalSince1970: 2_000_000_001))
                }
                return try Fixture.response(
                    request,
                    body: request.httpMethod == "POST" ? Fixture.login : Fixture
                        .credits())
            })
        await Fixture.failure(strategy)
    }

    @Test
    func `cancelled task never reads the browser`() async {
        let reads = LockIsolated(0)
        let strategy = OpenAIWebFetchStrategy(tokenLoader: { _ in
            reads.setValue(reads.value + 1)
            return Fixture.token
        }, transport: Fixture.transport())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let failure = await Fixture.failure(strategy)
            #expect(failure?.underlyingError is CancellationError)
        }
        await task.value
        #expect(reads.value == 0)
    }

    @Test
    func `oversized bodies are rejected`() async {
        await Fixture.expectFailure(credits: String(repeating: "x", count: OpenAIWebTransport.maximumBodyBytes + 1))
    }

    @Test
    func `native owner changes with provider profile org and token`() throws {
        let original = try ProviderBrowserSessionOwner(
            provider: .openai, profile: Fixture.profile, organizationID: "org-pinned", accessToken: Fixture.token)
        for (provider, profile, org, token) in [
            (UsageProvider.claude, Fixture.profile, "org-pinned", Fixture.token),
            (
                .openai,
                ProviderBrowserProfile(browserID: "chrome", profileID: "/synthetic/other"),
                "org-pinned",
                Fixture.token),
            (.openai, Fixture.profile, "org-other", Fixture.token),
            (.openai, Fixture.profile, "org-pinned", "synthetic-other-token"),
        ] {
            #expect(try original != ProviderBrowserSessionOwner(
                provider: provider, profile: profile, organizationID: org, accessToken: token))
        }
        #expect(!String(reflecting: original).contains(Fixture.token))
    }

    @Test
    func `legacy API snapshots keep API spend presentation`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: .init(used: 10, limit: 0, currencyCode: "USD", updatedAt: Fixture.now),
            openAIAPIUsage: OpenAIAPIUsageSnapshot(daily: [], updatedAt: Fixture.now, historyDays: 30),
            updatedAt: Fixture.now)
        let presentation = OpenAIAPIProviderDescriptor.descriptor.presentation.cost(snapshot: snapshot)
        #expect(presentation.menuCardStyle == .apiSpend)
        #expect(presentation.showsGenericFallback)
        #expect(presentation.balances.isEmpty)
    }

    @Test
    func `web is explicit and API routes and passive accounts are preserved`() async {
        let descriptor = OpenAIAPIProviderDescriptor.descriptor
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api, .web])
        #expect(descriptor.credentials?.tokenAccountSupport?.passiveSourceModes == [.web])
        #expect(descriptor.settingsSection.selectedProfileBrowsers == nil)
        for mode in [ProviderSourceMode.auto, .api, .web] {
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(Fixture.context(mode: mode))
            #expect(strategies.count == 1)
            #expect(strategies.first?.id == (mode == .web ? "openai.web" : "openai.js"))
        }
    }
}

private enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let profile = ProviderBrowserProfile(browserID: "chrome", profileID: "/synthetic/chrome/Profile 1")
    static let token = Self.jwt(expiry: 2_000_000_000)
    static func jwt(expiry: Int) -> String {
        let payload = Data("{\"exp\":\(expiry)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJub25lIn0.\(payload).synthetic"
    }

    static let login = #"""
    {"user":{"email":"fixture@example.invalid","session":{
    "sensitive_id":"sess-synthetic","expires_at":null,"enabled":true,"deleted_at":null,"organization":null},
    "orgs":{"data":[{"id":"org-default","title":"Ignore default"},
    {"id":"org-pinned","title":"Pinned organization","name":"pinned-name"}]}}}
    """#
    static func credits(_ available: Double = 12.25) -> String {
        """
        {"total_granted":1000,"total_used":91,"total_available":\(available),"total_paid_available":3,
        "grants":{"data":[{"grant_amount":999,"used_amount":2,"expires_at":1800000000}]}}
        """
    }

    static func transport(
        login: String = Self.login, credits: String = Self.credits()) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            try self.response(request, body: request.httpMethod == "POST" ? login : credits)
        }
    }

    static func strategy(login: String = Self.login) -> OpenAIWebFetchStrategy {
        OpenAIWebFetchStrategy(
            tokenLoader: { _ in self.token }, clock: { self.now }, transport: self.transport(login: login))
    }

    static func response(_ request: URLRequest, status: Int = 200, body: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    static func expectFailure(
        login: String = Self.login, credits: String = Self.credits(), expectedRequests: Int = 2) async
    {
        let requests = LockIsolated(0)
        let strategy = OpenAIWebFetchStrategy(
            tokenLoader: { _ in self.token },
            clock: { self.now },
            transport: ProviderHTTPTransportHandler { request in
                requests.setValue(requests.value + 1)
                return try self.response(
                    request,
                    body: request.httpMethod == "POST" ? login : credits)
            })
        await self.failure(strategy)
        #expect(requests.value == expectedRequests)
    }

    @discardableResult
    static func failure(
        _ strategy: OpenAIWebFetchStrategy,
        context: ProviderFetchContext = Self.context()) async -> ProviderBrowserSessionFailure?
    {
        do {
            _ = try await strategy.fetch(context)
            Issue.record("Expected a safe session failure")
            return nil
        } catch {
            let failure = error as? ProviderBrowserSessionFailure
            #expect(failure != nil)
            #expect(failure?.owner == nil)
            #expect(!error.localizedDescription.contains(self.token))
            #expect(!String(reflecting: error).contains(self.token))
            #expect(!String(reflecting: error).contains("sess-synthetic"))
            return failure
        }
    }

    static func context(
        mode: ProviderSourceMode = .web,
        settings: OpenAIWebSettings = .init(
            browserID: "chrome",
            browserProfileID: Self.profile.profileID,
            organizationID: "org-pinned"),
        accountID: UUID? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .cli,
            sourceMode: mode,
            includeCredits: true,
            webTimeout: 20,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot(settings, for: OpenAIWebProviderSettingsKey.self),
            fetcher: UsageFetcher(),
            claudeFetcher: OpenAIWebUnusedClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: accountID)
    }
}

private struct OpenAIWebUnusedClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw CancellationError() }
    func debugRawProbe(model _: String) async -> String { "unused" }
}
