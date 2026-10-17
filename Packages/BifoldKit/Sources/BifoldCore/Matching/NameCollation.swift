import Foundation

/// Klucz sortowania nazw liczony raz na element, porównywany jak tablica liczb.
/// Odwzorowuje kolejność „jak w Finderze” (`localizedStandardCompare`) dla nazw plików:
/// - bez rozróżniania wielkości liter,
/// - ciągi cyfr porównywane jako liczby (plik2 < plik10),
/// - odstępy i interpunkcja przed cyframi, cyfry przed literami,
/// - litery z diakrytykami tuż po literze bazowej, jak w alfabecie polskim (a < ą < b, z < ź < ż).
/// Remisy rozstrzyga `localizedStandardCompare` na pełnych nazwach.
public enum NameCollation {
    static let punctuationClass: UInt32 = 0x1000_0000
    static let digitClass: UInt32 = 0x2000_0000
    static let letterClass: UInt32 = 0x3000_0000

    public static func key(_ name: String) -> [UInt32] {
        let scalars = Array(name.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars)
        var out: [UInt32] = []
        out.reserveCapacity(scalars.count + 2)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if digitValue(c) != nil {
                // Ciąg cyfr: długość bez zer wiodących, potem cyfry.
                var j = i
                while j < scalars.count, digitValue(scalars[j]) != nil { j += 1 }
                var k = i
                while k < j - 1, digitValue(scalars[k]) == 0 { k += 1 }
                out.append(digitClass | UInt32(j - k) << 8)
                for m in k..<j { out.append(digitClass | UInt32(digitValue(scalars[m])!)) }
                i = j
                continue
            }
            if c.properties.generalCategory == .nonspacingMark {
                // Znak diakrytyczny — modyfikuje wagę poprzedniej litery.
                if let last = out.last, last & 0xF000_0000 == letterClass {
                    out[out.count - 1] = (last & ~0xF) | accentRank(c)
                }
                i += 1
                continue
            }
            if c == "ł" {
                out.append(letterClass | (UInt32(("l" as Unicode.Scalar).value) << 4) | 1)
            } else if c.properties.isAlphabetic {
                out.append(letterClass | (min(c.value, 0x00FF_FFFF) << 4))
            } else {
                out.append(punctuationClass | c.value)
            }
            i += 1
        }
        return out
    }

    private static func digitValue(_ c: Unicode.Scalar) -> Int? {
        if c.value >= 0x30 && c.value <= 0x39 { return Int(c.value - 0x30) }
        if c.properties.numericType == .decimal, let v = c.properties.numericValue { return Int(v) }
        return nil
    }

    /// Kolejność znaków diakrytycznych w obrębie litery (ź przed ż).
    private static func accentRank(_ mark: Unicode.Scalar) -> UInt32 {
        switch mark.value {
        case 0x0301: 1 // ostry (ć, ń, ó, ś, ź)
        case 0x0328: 1 // ogonek (ą, ę)
        case 0x0307: 2 // kropka (ż)
        default: 3 + mark.value % 12
        }
    }

    public static func compare(_ a: [UInt32], _ b: [UInt32]) -> ComparisonResult {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] ? .orderedAscending : .orderedDescending }
            i += 1
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }
}
