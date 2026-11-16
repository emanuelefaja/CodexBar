import CodexBarCore
import Foundation

extension UsageStore {
    /// Uses every configured account, independent of the old Overview selection and card layout.
    /// Read only: opening the menu never switches credentials or uses another account as a fallback.
    func compactOverviewInputs(for providers: [ProviderInstanceID]) -> [CompactAccountsOverview.Input] {
        providers.flatMap { instanceID -> [CompactAccountsOverview.Input] in
            let provider = instanceID.firstPartyProvider
            let name: String = switch provider {
            // Provider-specific by design: Short dashboard names distinguish subscriptions from Console API billing.
            case .claude: "Claude"
            case .zai: "GLM"
            case .codex: "Codex"
            case .claudeplatform: "Claude API"
            case .openai: "OpenAI API"
            case let .some(provider): self.metadata(for: provider).displayName
            case .none: UserProviderPluginRegistry.plugin(for: instanceID)?.manifest.name ?? instanceID.rawValue
            }
            let labels: [String] = if let provider {
                [self.metadata(for: provider).sessionLabel, self.metadata(for: provider).weeklyLabel, "Other"]
            } else {
                ["Primary", "Secondary", "Other"]
            }
            let hidePersonalInfo = self.settings.hidePersonalInfo
            func input(
                id: String? = nil,
                identity: String? = nil,
                snapshot: UsageSnapshot?,
                error: String?,
                retained: Bool = false) -> CompactAccountsOverview.Input
            {
                CompactAccountsOverview.Input(
                    provider: instanceID,
                    accountID: id,
                    name: name,
                    identity: hidePersonalInfo ? nil : identity,
                    snapshot: snapshot,
                    error: error,
                    retained: retained,
                    // Provider-specific by design: Console and OpenAI Platform own API balances, not subscription
                    // quotas.
                    balanceOnly: provider == .claudeplatform || provider == .openai,
                    windowLabels: labels)
            }
            if provider == .claude, !self.claudeSwapAccountSnapshots.isEmpty {
                // Adapter order puts the active account first; sort by stable slot instead.
                return self.claudeSwapAccountSnapshots.sorted {
                    ($0.id.source + ":" + $0.id.opaqueID).localizedStandardCompare(
                        $1.id.source + ":" + $1.id.opaqueID) == .orderedAscending
                }.map { account in
                    input(
                        id: account.id.source + ":" + account.id.opaqueID,
                        identity: account.displayLabel,
                        snapshot: account.snapshot,
                        error: account.error ?? self.claudeSwapLastError,
                        retained: account.usesLastKnownUsage)
                }
            }
            // Provider-specific by design: Codex managed accounts use their identity-validated snapshot inventory.
            if provider == .codex,
               let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay,
               projection.visibleAccounts.count > 1
            {
                return projection.visibleAccounts.map { account in
                    let record = self.codexAccountSnapshots.first {
                        $0.id == account.id && Self.codexPriorSnapshotAccountMatches($0.account, account: account)
                    }
                    return input(
                        id: account.id,
                        identity: account.displayName,
                        snapshot: record?.snapshot,
                        error: record?.error)
                }
            }
            // Provider-specific by design: OpenAI Web owns one browser balance, never one copy per saved API key.
            let passiveOpenAIAccounts = provider == .openai
                && self.settings.providerConfig(for: .openai)?.source == .web
            if let provider, !passiveOpenAIAccounts {
                let accounts = self.settings.tokenAccounts(for: provider)
                if !accounts.isEmpty {
                    let cached = self.validTokenAccountSnapshots(provider: provider, accounts: accounts)
                    return accounts.map { account in
                        let record = cached.first { $0.id == account.id }
                        return input(
                            id: account.id.uuidString,
                            identity: account.displayName,
                            snapshot: record?.snapshot,
                            error: record?.error)
                    }
                }
            }
            let snapshot = self.profileScopedSnapshot(for: instanceID)
            return [input(
                identity: snapshot?.identity?.accountEmail,
                snapshot: snapshot,
                error: self.errors[instanceID])]
        }
    }
}
