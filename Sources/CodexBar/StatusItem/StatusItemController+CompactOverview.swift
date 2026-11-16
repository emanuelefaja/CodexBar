import AppKit
import CodexBarCore

extension StatusItemController {
    static let quotaWarningFlashDuration: TimeInterval = 60

    func populateCompactOverview(_ menu: NSMenu, enabledProviders: [UsageProvider]) {
        self.performMenuMutationWithoutAnimation {
            menu.removeAllItems()
            self.lastMergedMenuContentSelection = .overview
            _ = self.addOverviewRows(to: menu, enabledProviders: enabledProviders, menuWidth: 384)
            menu.addItem(.separator())
            self.addCompactOverviewFooter(to: menu)
            self.flushHostedMenuRowRendering(in: menu)
        }
    }

    func makeCompactOverviewAccountItem(
        _ account: CompactAccountsOverview.Account,
        balance: Bool,
        interactionMenu: NSMenu) -> NSMenuItem
    {
        let readOnly = self.compactOverviewDetailTarget(account) == .readOnly
        let submenu = readOnly ? self.compactOverviewReadOnlySubmenu(account, balance: balance) : nil
        let item = self.makeMenuCardItem(
            CompactAccountsRowView(account: account, balance: balance),
            id: Self.overviewRowIdentifierPrefix + account.id,
            width: 384,
            heightCacheFingerprint: Self.compactRowFingerprint(account, balance: balance),
            submenu: submenu,
            usesGPUSelection: true,
            onClick: readOnly ? nil : { [weak self, weak interactionMenu] in
                guard let self, let interactionMenu else { return }
                self.selectCompactOverviewAccount(account, menu: interactionMenu)
            })
        if !readOnly {
            item.target = self
            item.action = #selector(self.selectCompactOverviewAccount(_:))
        }
        item.toolTip = account.help
        return item
    }

    /// Includes the label and price line so a renamed or repriced row cannot reuse an old height.
    static func compactRowFingerprint(_ account: CompactAccountsOverview.Account, balance: Bool) -> String {
        let price = account.monthlyPrice ?? ""
        return "\(account.label)|\(price)|\(account.windows.count)|\(account.stale)|\(balance)"
    }

    private func compactOverviewDetailTarget(
        _ account: CompactAccountsOverview.Account) -> CompactAccountsOverview.DetailTarget
    {
        guard let provider = account.provider.firstPartyProvider else {
            return account.detailTarget()
        }
        // Provider-specific by design: Claude adapters own their details; Codex uses its separate managed inventory.
        if provider == .claude, account.accountID != nil, !self.store.claudeSwapAccountSnapshots.isEmpty {
            return .readOnly
        }
        if provider == .codex, let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay {
            return account.detailTarget(codexAccountIDs: projection.visibleAccounts.map(\.id))
        }
        // A passive credential source cannot safely own the live provider detail card.
        let tokenAccounts = self.settings.effectiveSelectedTokenAccount(for: provider) == nil
            ? [] : self.settings.tokenAccounts(for: provider)
        let cached = self.store.validTokenAccountSnapshots(provider: provider, accounts: tokenAccounts)
        let tokenIDs = tokenAccounts.filter { token in
            self.settings.multiAccountMenuLayout == .segmented ||
                cached.contains { $0.id == token.id && $0.snapshot != nil }
        }.map(\.id)
        return account.detailTarget(tokenAccountIDs: tokenIDs)
    }

    private func compactOverviewReadOnlySubmenu(
        _ account: CompactAccountsOverview.Account,
        balance: Bool) -> NSMenu
    {
        let submenu = NSMenu(title: account.label)
        submenu.autoenablesItems = false
        if !account.help.isEmpty {
            submenu.addItem(self.makeWrappedSecondaryTextItem(text: account.help, width: 384))
            submenu.addItem(.separator())
        }
        if !balance {
            submenu.addItem(self.makeMenuCardItem(
                CompactAccountsHeading(), id: "compactAccountDetailHeading", width: 384))
        }
        submenu.addItem(self.makeMenuCardItem(
            CompactAccountsRowView(account: account, balance: balance),
            id: "compactAccountDetail-" + account.id,
            width: 384,
            heightCacheFingerprint: Self.compactRowFingerprint(account, balance: balance)))
        return submenu
    }

    @objc func selectCompactOverviewAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id.hasPrefix(Self.overviewRowIdentifierPrefix), let menu = sender.menu else { return }
        let rowID = String(id.dropFirst(Self.overviewRowIdentifierPrefix.count))
        let inputs = self.store.compactOverviewInputs(for: self.overviewProviderIDs(
            enabledProviders: self.store.enabledFirstPartyProvidersForDisplay()))
        let model = CompactAccountsOverview(inputs: inputs, now: Date())
        guard let account = (model.accounts + model.balances).first(where: { $0.id == rowID }) else { return }
        self.selectCompactOverviewAccount(account, menu: menu)
    }

    private func selectCompactOverviewAccount(_ account: CompactAccountsOverview.Account, menu: NSMenu) {
        // Revalidate at activation: the account may have been removed while the menu was open.
        guard self.overviewProviderIDs(enabledProviders: self.store.enabledFirstPartyProvidersForDisplay())
            .contains(account.provider) else { return }
        switch self.compactOverviewDetailTarget(account) {
        case .provider:
            break
        case let .tokenAccount(id):
            guard let provider = account.provider.firstPartyProvider,
                  let index = self.settings.tokenAccounts(for: provider).firstIndex(where: { $0.id == id })
            else { return }
            self.advanceMenuInteraction(for: menu)
            self.settings.setActiveTokenAccountIndex(index, for: provider)
            guard self.settings.effectiveSelectedTokenAccount(for: provider)?.id == id else { return }
            self.store.activateCachedTokenAccountSnapshot(provider: provider, accountID: id)
        case let .codexAccount(id):
            guard let visible = self.settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts
                .first(where: { $0.id == id }) else { return }
            self.handleCodexVisibleAccountSelection(visible, menu: menu)
        case .readOnly:
            return
        }
        self.selectOverviewProvider(account.provider, menu: menu)
    }

    func addCompactOverviewFooter(to menu: NSMenu) {
        for (title, action) in [("Settings…", MenuDescriptor.MenuAction.settings), ("Quit", .quit)] {
            let (selector, represented) = self.selector(for: action)
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = represented
            if let shortcut = self.shortcut(for: action) {
                item.keyEquivalent = shortcut.key
                item.keyEquivalentModifierMask = shortcut.modifiers
            }
            menu.addItem(item)
        }
    }

    @objc func backToCompactOverview(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        self.compactOverviewShowsDetails = false
        self.settings.mergedMenuLastSelectedWasOverview = true
        self.lastMergedSwitcherSelection = .overview
        self.cancelMergedSwitcherSiblingWarmup()
        self.refreshProviderSelectionDependentUI(deferRendering: true)
        self.requestProviderSwitcherMenuRebuild(menu, provider: nil)
    }
}
