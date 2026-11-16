import CodexBarCore
import Foundation
import SweetCookieKit
import SwiftUI

extension OpenAIAPIProviderImplementation {
    @MainActor
    func usesWeb(_ settings: SettingsStore) -> Bool {
        settings.providerConfig(for: self.id)?.source == .web
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.providerConfig(for: self.id)?.source ?? .auto
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        let section = ProviderDescriptorRegistry.descriptor(for: self.id).settingsSection
        // Saved API accounts are passive in Web mode. Only an explicit override must be rejected by Core.
        let account = context.tokenOverride.flatMap { $0.provider == self.id ? $0.account : nil }
        return section.credentialContribution(context: ProviderCredentialSettingsContext(
            config: context.settings.providerConfig(for: self.id),
            account: account))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support _: TokenAccountSupport) -> Bool {
        !self.usesWeb(context.settings)
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        var pickers = [self.sourcePicker(context: context)]
        if self.usesWeb(context.settings) {
            pickers.append(self.webProfilePicker(context: context))
        }
        return pickers
    }

    @MainActor
    func sourcePicker(context: ProviderSettingsContext) -> ProviderSettingsPickerDescriptor {
        ProviderSettingsPickerDescriptor(
            id: "openai-source",
            title: L("Usage source"),
            subtitle: L(
                "Auto and API use API keys. Web reads credits from a selected Chrome profile and organization."),
            binding: Binding(
                get: { (context.settings.providerConfig(for: self.id)?.source ?? .auto).rawValue },
                set: { value in
                    guard let source = ProviderSourceMode(rawValue: value), [.auto, .api, .web].contains(source),
                          source != (context.settings.providerConfig(for: self.id)?.source ?? .auto)
                    else { return }
                    context.store.clearProviderState(self.id)
                    context.settings.updateProviderConfig(provider: self.id) { $0.source = source }
                }),
            options: [
                .init(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
                .init(id: ProviderSourceMode.api.rawValue, title: "API"),
                .init(id: ProviderSourceMode.web.rawValue, title: "Web"),
            ],
            isVisible: nil,
            onChange: nil)
    }

    @MainActor
    func webProfilePicker(
        context: ProviderSettingsContext,
        profiles: [BrowserProfile]? = nil) -> ProviderSettingsPickerDescriptor
    {
        // Chrome only: this source reads Chrome LocalStorage, not cookies. Discovery reads profile metadata only.
        let config = context.settings.providerConfig(for: self.id)
        let saved = config?.browserID == "chrome" ? config?.browserProfileID : nil
        let options = ProviderBrowserProfileOptions.options(browser: .chrome, saved: saved, profiles: profiles)
        return ProviderSettingsPickerDescriptor(
            id: "openai-web-profile",
            title: L("Chrome profile"),
            subtitle: L(
                """
                Select an existing Chrome profile signed in to OpenAI Platform. No profile is selected automatically.
                """),
            binding: Binding(
                get: {
                    let current = context.settings.providerConfig(for: self.id)
                    return current?.browserID == "chrome" ? current?.browserProfileID ?? "" : ""
                },
                set: { value in
                    let profile = value.isEmpty ? nil : value
                    let current = context.settings.providerConfig(for: self.id)
                    guard current?.browserID != "chrome" || current?.browserProfileID != profile else { return }
                    context.store.clearProviderState(self.id)
                    context.settings.updateProviderConfig(provider: self.id) {
                        $0.browserID = "chrome"
                        $0.browserProfileID = profile
                    }
                }),
            options: options,
            isVisible: nil,
            onChange: nil)
    }

    @MainActor
    func webOrganizationField(context: ProviderSettingsContext) -> ProviderSettingsFieldDescriptor {
        ProviderSettingsFieldDescriptor(
            id: "openai-web-organization",
            title: L("Organization ID"),
            subtitle: L(
                "Required. If auth expires, refresh Platform in this Chrome profile, then refresh CodexBar."),
            kind: .plain,
            placeholder: "org-...",
            binding: Binding(
                get: { context.settings.providerConfig(for: self.id)?.organizationID ?? "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    let organization = trimmed.isEmpty ? nil : trimmed
                    guard organization != context.settings.providerConfig(for: self.id)?.organizationID else { return }
                    context.store.clearProviderState(self.id)
                    context.settings.updateProviderConfig(provider: self.id) { $0.organizationID = organization }
                }),
            actions: [.openURL(
                id: "openai-web-billing",
                title: L("Open billing"),
                url: URL(string: "https://platform.openai.com/settings/organization/billing/overview"))],
            isVisible: nil)
    }
}
