import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CompactAccountPresentationTests {
    @Test
    func `display slots sanitize names and prices without touching credentials`() {
        let slots = CompactAccountPresentations(accounts: [
            "1": .init(name: "  Claude Ultra 1  ", monthlyPriceUSD: 200),
            "2": .init(name: "Line\nbreak", monthlyPriceUSD: -5),
            "3": .init(name: String(repeating: "x", count: 49), monthlyPriceUSD: 12.345),
            "0": .init(name: "Zero slot", monthlyPriceUSD: 1),
        ])
        #expect(slots.presentation(forOrdinal: 1) == .init(name: "Claude Ultra 1", monthlyPriceUSD: 200))
        #expect(slots.presentation(forOrdinal: 2) == .init(name: nil, monthlyPriceUSD: nil))
        #expect(slots.presentation(forOrdinal: 3) == .init(name: nil, monthlyPriceUSD: 12.35))
        #expect(slots.presentation(forOrdinal: 0) == nil)
        #expect(slots.presentation(forOrdinal: 4) == nil)
    }

    @Test
    func `render metadata is not fetch identity`() throws {
        let decoder = JSONDecoder()
        let plain = try decoder.decode(
            ProviderConfig.self,
            from: Data(#"{"id":"claude"}"#.utf8))
        var renamed = plain
        renamed.compactAccounts = CompactAccountPresentations(accounts: [
            "1": .init(name: "Claude Ultra 1", monthlyPriceUSD: 200),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(renamed.fetchIdentityConfig) == encoder.encode(plain.fetchIdentityConfig))
        #expect(renamed.compactAccounts?.presentation(forOrdinal: 1)?.name == "Claude Ultra 1")
    }
}
