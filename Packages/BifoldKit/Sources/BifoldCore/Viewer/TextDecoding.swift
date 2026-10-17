import CoreFoundation
import Foundation

/// Kodowania dostępne w podglądzie (F3). Polskie strony kodowe na początku listy.
public enum TextEncoding: String, CaseIterable, Codable, Sendable, Identifiable {
    case utf8, utf16LE, utf16BE, windows1250, iso8859_2, cp852, macCentralEurope, windows1252, iso8859_1, macRoman, ascii

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .windows1250: "Windows-1250 (Europa Środkowa)"
        case .iso8859_2: "ISO 8859-2 (Latin-2)"
        case .cp852: "CP852 (DOS Latin-2)"
        case .macCentralEurope: "Mac Central European"
        case .windows1252: "Windows-1252 (Europa Zachodnia)"
        case .iso8859_1: "ISO 8859-1 (Latin-1)"
        case .macRoman: "Mac Roman"
        case .ascii: "ASCII"
        }
    }

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .windows1250: .windowsCP1250
        case .iso8859_2: .isoLatin2
        case .cp852: Self.cf(CFStringEncoding(CFStringEncodings.dosLatin2.rawValue))
        case .macCentralEurope: Self.cf(CFStringEncoding(CFStringEncodings.macCentralEurRoman.rawValue))
        case .windows1252: .windowsCP1252
        case .iso8859_1: .isoLatin1
        case .macRoman: .macOSRoman
        case .ascii: .ascii
        }
    }

    private static func cf(_ e: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(e))
    }
}

public enum TextDecoding {
    /// Heurystyka: BOM → UTF-8 (jeśli poprawny) → UTF-16 bez BOM (dużo zer) → Windows-1250
    /// (najczęstsze dla polskich plików tekstowych z Windows).
    public static func detect(_ data: Data) -> TextEncoding {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        let sample = data.prefix(64 * 1024)
        if isValidUTF8(sample) { return .utf8 }
        let zerosEven = stride(from: 0, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
        let zerosOdd = stride(from: 1, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
        let half = max(1, sample.count / 2)
        if zerosOdd > half / 3 && zerosEven < half / 10 { return .utf16LE }
        if zerosEven > half / 3 && zerosOdd < half / 10 { return .utf16BE }
        return .windows1250
    }

    /// Poprawność UTF-8 z tolerancją uciętego znaku na końcu próbki.
    static func isValidUTF8(_ data: Data) -> Bool {
        if String(validating: data, as: UTF8.self) != nil { return true }
        for cut in 1...3 where data.count > cut {
            if String(validating: data.dropLast(cut), as: UTF8.self) != nil { return true }
        }
        return false
    }

    public static func decode(_ data: Data, as encoding: TextEncoding) -> String {
        var body = data
        switch encoding {
        case .utf8 where data.starts(with: [0xEF, 0xBB, 0xBF]): body = data.dropFirst(3)
        case .utf16LE where data.starts(with: [0xFF, 0xFE]), .utf16BE where data.starts(with: [0xFE, 0xFF]): body = data.dropFirst(2)
        default: break
        }
        if let s = String(data: body, encoding: encoding.stringEncoding) { return s }
        // Niepoprawne bajty → znak zastępczy zamiast pustego podglądu.
        if encoding == .utf8 { return String(decoding: body, as: UTF8.self) }
        return String(data: body, encoding: .isoLatin1) ?? ""
    }

    /// Czy dane wyglądają na binarne (bajt zerowy w próbce, poza UTF-16).
    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard sample.contains(0) else { return false }
        let enc = detect(data)
        return enc != .utf16LE && enc != .utf16BE
    }

    /// Wiersze zrzutu szesnastkowego (offset, 16 bajtów hex, ASCII).
    public static func hexDump(_ data: Data, startOffset: Int64 = 0, bytesPerLine: Int = 16) -> String {
        var out = ""
        out.reserveCapacity(data.count * 4)
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let line = bytes[offset..<min(offset + bytesPerLine, bytes.count)]
            out += String(format: "%08llX  ", startOffset + Int64(offset))
            for i in 0..<bytesPerLine {
                if i < line.count { out += String(format: "%02X ", line[line.startIndex + i]) } else { out += "   " }
                if i == 7 { out += " " }
            }
            out += " "
            for b in line { out.append(b >= 0x20 && b < 0x7F ? Character(UnicodeScalar(b)) : ".") }
            out += "\n"
            offset += bytesPerLine
        }
        return out
    }
}
