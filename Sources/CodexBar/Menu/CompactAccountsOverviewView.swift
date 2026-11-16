import SwiftUI

struct CompactAccountsHeading: View {
    var body: some View {
        HStack(spacing: 8) {
            Text(L("ACCOUNT")).frame(width: 96, alignment: .leading)
            Text(L("LIMIT")).frame(width: 88, alignment: .leading)
            Text(L("LEFT")).frame(width: 80, alignment: .trailing)
            Text(L("RESET")).frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(width: 384)
        .help(L("Percentages show remaining quota."))
    }
}

struct CompactAccountsRowView: View {
    let account: CompactAccountsOverview.Account
    var balance = false
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(self.account.windows.enumerated()), id: \.offset) { index, window in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(index == 0 ? self.account.label : "")
                            .fontWeight(.medium)
                        if index == 0, let price = self.account.monthlyPrice {
                            Text(L("%@/month", price))
                                .font(.system(size: 9))
                                .foregroundStyle(self.isHighlighted ? .primary : .secondary)
                        }
                        if index == 0, self.account.stale {
                            Text(L("Stale"))
                                .font(.system(size: 9))
                                .foregroundStyle(self.isHighlighted ? .primary : .secondary)
                        }
                    }
                    .frame(width: 96, alignment: .leading)
                    if self.balance {
                        Text(window.left)
                            .monospacedDigit()
                            .foregroundStyle(self.numberColor(window.severity))
                            .frame(width: 248, alignment: .trailing)
                    } else {
                        Text(window.label)
                            .frame(width: 88, alignment: .leading)
                            .help(window.label)
                        Text(window.left)
                            .monospacedDigit()
                            .foregroundStyle(self.numberColor(window.severity))
                            .frame(width: 80, alignment: .trailing)
                        Text(window.reset)
                            .monospacedDigit()
                            .foregroundStyle(self.isHighlighted ? .primary : .secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 384, alignment: .leading)
        .help(self.account.help)
        .accessibilityElement(children: .combine)
    }

    private func numberColor(_ severity: CompactAccountsOverview.Severity) -> Color {
        switch severity {
        case .neutral: .primary
        case .low: .orange
        case .critical: .red
        }
    }
}
