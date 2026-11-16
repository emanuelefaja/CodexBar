import CodexBarCore

extension ProviderConfig {
    /// Display preferences must not change ownership of fetched or cached usage.
    var fetchIdentityConfig: Self {
        var copy = self
        copy.codexAccountNames = nil
        copy.accentColor = nil
        copy.hiddenUsageItemIDs = nil
        copy.modelRateLimits = nil
        // Compact dashboard names and prices are display-only and must not refetch usage.
        copy.compactAccounts = nil
        if let data = copy.tokenAccounts {
            copy.tokenAccounts = ProviderTokenAccountData(
                version: data.version,
                accounts: data.accounts.map { $0.withModelRateLimits(nil) },
                activeIndex: data.activeIndex)
        }
        copy.claudeResetCreditsVisibilityMigrated = nil
        return copy
    }
}
