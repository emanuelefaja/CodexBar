import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Platform credit balances are deliberately separate from the API-key usage plugin.
struct OpenAIWebFetchStrategy: ProviderFetchStrategy {
    typealias TokenLoader = @Sendable (ProviderBrowserProfile) throws -> String
    let id = "openai.web"
    let kind: ProviderFetchKind = .web
    private let tokenLoader: TokenLoader
    private let clock: @Sendable () -> Date
    private let transport: any ProviderHTTPTransport

    init(
        tokenLoader: @escaping TokenLoader = OpenAIWebProfileReader.loadToken,
        clock: @escaping @Sendable () -> Date = { Date() },
        transport: any ProviderHTTPTransport = OpenAIWebTransport())
    {
        self.tokenLoader = tokenLoader
        self.clock = clock
        self.transport = transport
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool { context.sourceMode == .web }
    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        do {
            try Task.checkCancellation()
            guard context.sourceMode == .web,
                  let settings = context.settings?[OpenAIWebProviderSettingsKey.self],
                  !settings.hasTokenAccountOverride, context.selectedTokenAccountID == nil
            else { throw OpenAIWebError.selection }
            guard let profile = settings.selectedProfile, profile.browserID == "chrome",
                  let organizationID = settings.organizationID,
                  Self.isHeaderIdentifier(organizationID), organizationID.hasPrefix("org-")
            else { throw OpenAIWebError.selection }

            let token = try self.tokenLoader(profile)
            try Self.validateToken(token, now: self.clock())
            let login: Login = try await self.request(
                path: "onboarding/login",
                method: "POST",
                token: token,
                body: Data(#"{"app":"api"}"#.utf8))
            let session = login.user.session
            guard session.enabled, session.deletedAt == nil,
                  Self.isHeaderIdentifier(session.sensitiveID), session.sensitiveID.hasPrefix("sess-"),
                  session.expiresAt.map({ $0.isFinite && $0 > self.clock().timeIntervalSince1970 }) ?? true
            else { throw OpenAIWebError.reopenPlatform }
            let memberships = login.user.orgs.data.filter { $0.id == organizationID }
            guard memberships.count == 1, let organization = memberships.first else {
                throw OpenAIWebError.organization
            }
            try Task.checkCancellation()
            let credits: Credits = try await self.request(
                path: "billing/credit_grants",
                method: "GET",
                token: session.sensitiveID,
                organizationID: organizationID)
            guard credits.totalAvailable.isFinite, credits.totalUsed.isFinite else {
                throw OpenAIWebError.invalidResponse
            }

            // A profile directory can change accounts while a request is in flight. Never publish that result.
            let current = try self.tokenLoader(profile)
            guard current == token else { throw OpenAIWebError.sessionChanged }
            let now = self.clock()
            try Self.validateToken(current, now: now)
            guard session.expiresAt.map({ $0 > now.timeIntervalSince1970 }) ?? true else {
                throw OpenAIWebError.reopenPlatform
            }
            try Task.checkCancellation()
            let owner = try ProviderBrowserSessionOwner(
                provider: .openai, profile: profile, organizationID: organizationID, accessToken: current)
            let usage = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: credits.totalUsed,
                    limit: 0,
                    currencyCode: "USD",
                    period: "API credits",
                    balance: credits.totalAvailable,
                    balanceUpdatedAt: now,
                    updatedAt: now),
                browserSessionOwner: owner,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .openai,
                    accountEmail: login.user.email,
                    accountOrganization: organization.title?.nilIfEmpty ?? organization.name,
                    loginMethod: "Platform browser session"),
                dataConfidence: .exact)
            return self.makeResult(usage: usage, sourceLabel: "web")
        } catch {
            // No unvalidated owner or transport/decoder error (which can contain secrets) escapes this boundary.
            let safe: Error = if error is CancellationError || Task.isCancelled
                || (error as? URLError)?.code == .cancelled
            {
                CancellationError()
            } else {
                (error as? OpenAIWebError) ?? OpenAIWebError.invalidResponse
            }
            throw ProviderBrowserSessionFailure(owner: nil, underlyingError: safe)
        }
    }

    private func request<T: Decodable>(
        path: String, method: String, token: String, organizationID: String? = nil, body: Data? = nil) async throws -> T
    {
        try Task.checkCancellation()
        let url = URL(string: "https://api.openai.com/v1/dashboard/" + path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let organizationID { request.setValue(organizationID, forHTTPHeaderField: "OpenAI-Organization") }
        // Direct transport call: no retries, including the login POST.
        let (data, response) = try await self.transport.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == url,
              data.count <= OpenAIWebTransport.maximumBodyBytes
        else { throw OpenAIWebError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw OpenAIWebError.reopenPlatform }
        guard response.statusCode == 200 else { throw OpenAIWebError.requestFailed }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpenAIWebError.invalidResponse
        }
    }

    static func isHeaderIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096
            && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func validateToken(_ token: String, now: Date) throws {
        guard token.utf8.count <= 65536 else { throw OpenAIWebError.reopenPlatform }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        } }) else { throw OpenAIWebError.reopenPlatform }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        struct Claims: Decodable { let exp: Double }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode(Claims.self, from: data),
              claims.exp.isFinite, claims.exp > now.timeIntervalSince1970
        else { throw OpenAIWebError.reopenPlatform }
    }
}

extension OpenAIWebFetchStrategy {
    fileprivate struct Login: Decodable {
        let user: User
        struct User: Decodable {
            let email: String
            let session: Session
            let orgs: Organizations
        }

        struct Organizations: Decodable { let data: [Organization] }
        struct Organization: Decodable {
            let id: String
            let title: String?
            let name: String?
        }

        struct Session: Decodable {
            let sensitiveID: String
            let expiresAt: Double?
            let enabled: Bool
            let deletedAt: Double?
            enum CodingKeys: String, CodingKey {
                case sensitiveID = "sensitive_id"
                case expiresAt = "expires_at"
                case enabled
                case deletedAt = "deleted_at"
            }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                self.sensitiveID = try values.decode(String.self, forKey: .sensitiveID)
                self.enabled = try values.decode(Bool.self, forKey: .enabled)
                // Missing fields are not evidence of a non-expiring, active session; explicit null is.
                self.expiresAt = try values.decode(Double?.self, forKey: .expiresAt)
                self.deletedAt = try values.decode(Double?.self, forKey: .deletedAt)
            }
        }
    }

    fileprivate struct Credits: Decodable {
        let totalAvailable: Double
        let totalUsed: Double
        enum CodingKeys: String, CodingKey {
            case totalAvailable = "total_available"
            case totalUsed = "total_used"
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

enum OpenAIWebError: LocalizedError, Sendable {
    case selection, reopenPlatform, organization, invalidResponse, requestFailed, sessionChanged, profileAccess
    var errorDescription: String? {
        switch self {
        case .selection:
            "Select a Chrome profile and pin an OpenAI organization ID. Browser credits cannot use an API-key account."
        case .reopenPlatform:
            "Reopen platform.openai.com in the selected Chrome profile, sign in, and refresh."
        case .organization:
            "The selected Platform session does not have one matching membership for the pinned organization."
        case .invalidResponse:
            "OpenAI Platform returned an invalid credit response. Reopen Platform and refresh."
        case .requestFailed:
            "OpenAI Platform credits are unavailable. Try again later."
        case .sessionChanged:
            "The selected Platform session changed. Refresh again."
        case .profileAccess:
            "Cannot read the selected Chrome profile. Check the profile selection and Files & Folders access."
        }
    }
}
