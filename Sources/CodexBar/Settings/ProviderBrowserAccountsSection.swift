import CodexBarCore
import SweetCookieKit
import SwiftUI

@MainActor
enum ProviderBrowserProfileOptions {
    static func options(
        browser: Browser?, saved: String?, profiles: [BrowserProfile]? = nil) -> [ProviderSettingsPickerOption]
    {
        let profiles = profiles ?? browser.flatMap { try? BrowserCookieClient().codexBarStores(for: $0) }
            .map { ProviderBrowserProfile.selectableProfiles(from: $0) } ?? []
        var seen = Set<String>()
        var options = [ProviderSettingsPickerOption(id: "", title: L("Select profile…"))]
        options += profiles.filter { seen.insert($0.id).inserted }.map {
            ProviderSettingsPickerOption(id: $0.id, title: $0.name, localizesTitle: false)
        }
        if let saved, !saved.isEmpty, !seen.contains(saved) {
            options.append(.init(
                id: saved, title: L("Unavailable profile: %@", URL(fileURLWithPath: saved).lastPathComponent)))
        }
        return options
    }
}

/// Uses the shared browser-store picker; discovery reads metadata, never session cookies.
@MainActor
struct ProviderBrowserAccountsSection: View {
    let descriptor: ProviderSettingsTokenAccountsDescriptor
    @State private var editingID: UUID?
    @State private var label = ""
    @State private var token = ""
    @State private var organizationID = ""
    @State private var browserID = "chrome"
    @State private var profileID = ""

    private var isManual: Bool {
        self.browserID == "manual"
    }

    var body: some View {
        Section {
            ForEach(Array(self.descriptor.accounts().enumerated()), id: \.element.id) { index, account in
                HStack {
                    Button {
                        self.descriptor.setActiveIndex(index)
                    } label: {
                        Label(
                            account.label,
                            systemImage: self.descriptor.activeIndex() == index
                                ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(L("Edit")) { self.edit(account) }
                    Button(L("Remove")) {
                        self.descriptor.removeAccount(account.id)
                        if self.editingID == account.id { self.reset() }
                    }
                }
            }
            TextField(L("Label"), text: self.$label)
            ProviderSettingsPickerRowView(picker: .init(
                id: "account-browser",
                title: "Connection",
                subtitle: "",
                binding: Binding(get: { self.browserID }, set: {
                    self.browserID = $0
                    self.profileID = ""
                }),
                options: [.init(id: "manual", title: "Manual cookie")] +
                    Browser.defaultImportOrder.map { .init(id: $0.rawValue, title: $0.displayName) },
                isVisible: nil,
                onChange: nil))
            if self.isManual {
                SecureField(L("sessionKey or Cookie header"), text: self.$token)
                if self.editingID != nil {
                    Text(L("Leave blank to keep the saved credential.")).font(.caption)
                }
            } else {
                ProviderSettingsPickerRowView(picker: .init(
                    id: "account-profile",
                    title: "Browser profile",
                    subtitle: "Read only this profile. No other browser or account is tried.",
                    binding: self.$profileID,
                    options: ProviderBrowserProfileOptions.options(
                        browser: Browser(rawValue: self.browserID), saved: self.profileID),
                    isVisible: nil,
                    onChange: nil))
            }
            TextField(L("Organization ID (optional for a sole API organization)"), text: self.$organizationID)
            HStack {
                Button(L(self.editingID == nil ? "Add" : "Save")) {
                    let org = self.organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.descriptor.saveBrowserAccount?(
                        self.editingID,
                        self.label,
                        self.token,
                        self.isManual ? nil : ProviderBrowserProfile(
                            browserID: self.browserID, profileID: self.profileID),
                        org.isEmpty ? nil : org)
                    self.reset()
                }
                .disabled(self.saveDisabled)
                if self.editingID != nil {
                    Button(L("Cancel")) { self.reset() }
                }
                Spacer()
                Button(L("Open token file")) { self.descriptor.openConfigFile() }
                Button(L("Reload")) { self.descriptor.reloadFromDisk() }
            }
        } header: {
            Text(L(self.descriptor.title))
        } footer: {
            SettingsSectionFooter(L(self.descriptor.subtitle))
        }
        .textFieldStyle(.roundedBorder)
    }

    private var saveDisabled: Bool {
        if self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !self.isManual { return self.profileID.isEmpty }
        if !self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return !self.descriptor.accounts().contains {
            $0.id == self.editingID && $0.selectedBrowserProfile == nil && !$0.token.isEmpty
        }
    }

    private func edit(_ account: ProviderTokenAccount) {
        self.editingID = account.id
        self.label = account.label
        self.token = ""
        self.organizationID = account.organizationID ?? ""
        self.browserID = account.browserID ?? "manual"
        self.profileID = account.browserProfileID ?? ""
    }

    private func reset() {
        self.editingID = nil
        self.label = ""
        self.token = ""
        self.organizationID = ""
        self.profileID = ""
    }
}
