import Foundation

/// Browser credit settings are independent of saved API-key accounts and their project scopes.
public struct OpenAIWebSettings: Sendable, Equatable {
    public let browserID: String?
    public let browserProfileID: String?
    public let organizationID: String?
    public let hasTokenAccountOverride: Bool

    public init(
        browserID: String? = nil,
        browserProfileID: String? = nil,
        organizationID: String? = nil,
        hasTokenAccountOverride: Bool = false)
    {
        self.browserID = browserID
        self.browserProfileID = browserProfileID
        self.organizationID = organizationID
        self.hasTokenAccountOverride = hasTokenAccountOverride
    }

    public init(context: ProviderCredentialSettingsContext) {
        self.init(
            browserID: context.config?.browserID,
            browserProfileID: context.config?.browserProfileID,
            organizationID: context.config?.organizationID,
            hasTokenAccountOverride: context.account != nil)
    }

    public var selectedProfile: ProviderBrowserProfile? {
        guard let browserID, let browserProfileID,
              !browserID.isEmpty, !browserProfileID.isEmpty else { return nil }
        return ProviderBrowserProfile(browserID: browserID, profileID: browserProfileID)
    }
}

public enum OpenAIWebProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.openai
    public typealias Section = OpenAIWebSettings
}
