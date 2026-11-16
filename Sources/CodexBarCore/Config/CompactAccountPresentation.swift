import Foundation

/// Fork-only display metadata for the compact dashboard.
/// A presentation changes labels only: it never selects, authenticates, or inherits another account.
public struct CompactAccountPresentation: Codable, Sendable, Equatable {
    public var name: String?
    public var monthlyPriceUSD: Double?

    public init(name: String? = nil, monthlyPriceUSD: Double? = nil) {
        self.name = name
        self.monthlyPriceUSD = monthlyPriceUSD
    }

    /// Trimmed, single-line, bounded name and a finite, non-negative price.
    /// Invalid display values are omitted instead of leaking control characters or nonsense amounts.
    public var validated: Self {
        var result = self
        if let candidate = self.name?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let isSingleLine = !candidate.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            }
            result.name = !candidate.isEmpty && candidate.count <= 48 && isSingleLine ? candidate : nil
        }
        if let price = self.monthlyPriceUSD {
            let isValid = price.isFinite && price >= 0 && price <= 1_000_000
            result.monthlyPriceUSD = isValid ? (price * 100).rounded() / 100 : nil
        }
        return result
    }
}

/// One-based slots follow the dashboard's stable, deterministic account order.
/// They are display keys only and cannot address credentials.
public struct CompactAccountPresentations: Codable, Sendable, Equatable {
    public var accounts: [String: CompactAccountPresentation]

    public init(accounts: [String: CompactAccountPresentation] = [:]) {
        self.accounts = accounts
    }

    public func presentation(forOrdinal ordinal: Int) -> CompactAccountPresentation? {
        guard ordinal > 0 else { return nil }
        return self.accounts[String(ordinal)]?.validated
    }
}

extension ProviderConfig {
    /// Display-only. Excluded from fetch identity so renaming a row never refetches usage.
    public var compactAccounts: CompactAccountPresentations? {
        get { self.extensionValue(forKey: "compactAccounts") }
        set { self.setExtensionValue(newValue, forKey: "compactAccounts") }
    }
}
