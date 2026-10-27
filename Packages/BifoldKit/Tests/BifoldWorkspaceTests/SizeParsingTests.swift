import BifoldWorkspace
import Testing

/// Wspólny parser rozmiarów (komendy i okno wyszukiwania): wartości spoza zakresu Int64 to brak
/// wyniku, nie awaria (okno wyszukiwania miało własną kopię z `Int64(Double)`, która przerywała aplikację).
@Suite struct SizeParsingTests {
    @Test func searchWindowSizesOutOfRangeAreRejected() {
        for text in ["1e30G", "infM", "nanK", "99999999999G", "-1K", "1e30", "inf", "9e18"] {
            #expect(parseSize(text) == nil, "\(text)")
        }
        #expect(parseSize("1,5G") == 1_610_612_736)
        #expect(parseSize("700k") == 716_800)
        #expect(parseSize(" 2 M ") == 2_097_152)
        #expect(parseSize("12") == 12)
    }
}
