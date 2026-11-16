import CodexBarCore
import Foundation

/// A display-only projection. Each input owns its snapshot; missing accounts never borrow live usage.
struct CompactAccountsOverview {
    struct Input {
        let provider: ProviderInstanceID
        var accountID: String?
        let name: String
        var identity: String?
        var snapshot: UsageSnapshot?
        var error: String?
        var retained: Bool = false
        var balanceOnly: Bool = false
        var windowLabels: [String] = ["Session", "Weekly", "Other"]
    }

    enum Severity: Equatable {
        case neutral, low, critical
    }

    struct Window: Equatable {
        let label: String
        let left: String
        let reset: String
        var severity: Severity = .neutral
    }

    enum DetailTarget: Equatable {
        case provider
        case tokenAccount(UUID)
        case codexAccount(String)
        case readOnly
    }

    struct Account: Identifiable {
        let id: String
        let provider: ProviderInstanceID
        let accountID: String?
        let label: String
        let help: String
        let stale: Bool
        let windows: [Window]

        /// Inventories belong to this provider. Match stable IDs, never labels or active indices.
        func detailTarget(tokenAccountIDs: [UUID] = [], codexAccountIDs: [String] = []) -> DetailTarget {
            guard let accountID = self.accountID else { return .provider }
            // Provider-specific by design: Codex managed accounts have opaque IDs, not token-account UUIDs.
            if self.provider == .codex, codexAccountIDs.filter({ $0 == accountID }).count == 1 {
                return .codexAccount(accountID)
            }
            if self.provider.firstPartyProvider != nil,
               let id = UUID(uuidString: accountID), tokenAccountIDs.filter({ $0 == id }).count == 1
            {
                return .tokenAccount(id)
            }
            // Adapter inspection is transient and ordinary selection can change CLI credentials.
            // Unknown, removed, and adapter accounts use their captured read-only submenu instead.
            return .readOnly
        }
    }

    let accounts: [Account]
    let balances: [Account]
    /// Oldest observation, not the newest successful provider hiding older account data.
    let updatedAt: Date?
    static let staleAfter: TimeInterval = 15 * 60

    init(inputs: [Input], now: Date) {
        var accounts: [Account] = []
        var balances: [Account] = []
        var dates: [Date] = []
        let counts = Dictionary(grouping: inputs, by: \.name).mapValues(\.count)
        var ordinals: [String: Int] = [:]
        for input in inputs {
            ordinals[input.name, default: 0] += 1
            let ordinal = ordinals[input.name, default: 1]
            let label = counts[input.name, default: 0] > 1 ? "\(input.name) \(ordinal)" : input.name
            let snapshot = input.snapshot
            let stale = snapshot.map {
                input.retained || input.error != nil || now.timeIntervalSince($0.updatedAt) > Self.staleAfter
            } ?? false
            if let date = snapshot?.updatedAt { dates.append(date) }
            let id = input.provider.rawValue + (input.accountID.map { "/account/" + $0 } ?? "")
            let help = [input.identity, input.error].compactMap(\.self).joined(separator: "\n")
            func account(_ windows: [Window], stale: Bool) -> Account {
                Account(
                    id: id,
                    provider: input.provider,
                    accountID: input.accountID,
                    label: label,
                    help: help,
                    stale: stale,
                    windows: windows)
            }
            // API balances are numbers reported by the provider, never limit minus cost.
            // Provider-specific by design: Console billing has no subscription quota, even when its balance is absent.
            let balanceOnly = input.balanceOnly || snapshot?.iconProvider == .claudeplatform
            if balanceOnly || snapshot?.providerCost?.balance != nil {
                let cost = snapshot?.providerCost
                let balanceDate = cost?.balanceUpdatedAt ?? snapshot?.updatedAt
                if let balanceDate { dates.append(balanceDate) }
                let balanceStale = stale || balanceDate.map { now.timeIntervalSince($0) > Self.staleAfter } == true
                let balance = input.error == nil ? cost?.balance : nil
                balances.append(account([Window(
                    label: "Balance",
                    left: Self.balanceText(balance, currency: cost?.currencyCode ?? "USD"),
                    reset: "",
                    severity: Self.balanceSeverity(balance))], stale: balanceStale))
            }
            guard !balanceOnly else { continue }
            var windows: [Window] = []
            let standard = [snapshot?.primary, snapshot?.secondary, snapshot?.tertiary]
            for (index, window) in standard.enumerated() {
                guard let window, !window.isSyntheticPlaceholder else { continue }
                let fallback = input.windowLabels.indices.contains(index) ? input.windowLabels[index] : "Other"
                windows.append(Self.window(
                    window, label: window.title ?? fallback, known: input.error == nil, now: now))
            }
            for extra in snapshot?.extraRateWindows ?? [] where !extra.window.isSyntheticPlaceholder {
                windows.append(Self.window(
                    extra.window, label: extra.title, known: extra.usageKnown && input.error == nil, now: now))
            }
            if windows.isEmpty {
                windows = [Window(label: "—", left: "Unavailable", reset: "Unknown")]
            }
            accounts.append(account(windows, stale: stale))
        }
        self.accounts = accounts
        self.balances = balances
        self.updatedAt = dates.min()
    }

    private static func window(_ window: RateWindow, label: String, known: Bool, now: Date) -> Window {
        let remaining = known && window.usedPercent.isFinite ? min(100, max(0, 100 - window.usedPercent)) : nil
        let left = remaining.map { String(format: "%.0f%%", $0) } ?? "Unavailable"
        return Window(
            label: label,
            left: left,
            reset: self.resetText(window.resetsAt, now: now),
            severity: Self.quotaSeverity(remaining))
    }

    static func quotaSeverity(_ remaining: Double?) -> Severity {
        guard let remaining, remaining.isFinite else { return .neutral }
        if remaining <= 0 { return .critical }
        return remaining <= 20 ? .low : .neutral
    }

    static func balanceSeverity(_ balance: Double?) -> Severity {
        guard let balance, balance.isFinite else { return .neutral }
        return balance < 0 ? .critical : .neutral
    }

    static func resetText(_ date: Date?, now: Date) -> String {
        guard let date, date > now else { return "Unknown" }
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    static func balanceText(_ value: Double?, currency: String) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(currency) \(value)"
    }
}
