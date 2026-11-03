import Foundation

/// „Formatuj” w przeglądarce F3: czytelne wcięcia dla JSON i XML.
public enum CodeFormatter {
    public enum Failure: Error, Equatable, Sendable {
        /// Tekst nie jest poprawnym JSON/XML — zostaje oryginał.
        case invalid(String)
        /// Za duży do formatowania w przeglądarce.
        case tooLarge
    }

    /// Powyżej tego rozmiaru formatowanie jest pomijane (XMLDocument trzyma całe drzewo w pamięci).
    public static let maxBytes = 16 * 1024 * 1024

    /// Czy język (highlight.js) można formatować.
    public static func supports(language: String?) -> Bool {
        language == "json" || language == "xml"
    }

    public static func format(_ text: String, language: String?, indent: Int = 2) -> Result<String, Failure> {
        guard text.utf8.count <= maxBytes else { return .failure(.tooLarge) }
        switch language {
        case "json": return formatJSON(text, indent: indent)
        case "xml": return formatXML(text, indent: indent)
        default: return .failure(.invalid(""))
        }
    }

    // MARK: JSON

    /// Wcięcia bez przebudowy dokumentu: kolejność kluczy, zapis liczb (`1.0`, `1e3`) i znaki ucieczki
    /// zostają takie, jak w pliku (JSONSerialization sortowałby klucze i zmieniał liczby).
    /// Najpierw sprawdzenie poprawności — niepoprawny JSON nie jest „naprawiany” po cichu.
    public static func formatJSON(_ text: String, indent: Int = 2) -> Result<String, Failure> {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            return .failure(.invalid((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription))
        }
        let pad = [UInt8](repeating: 0x20, count: indent)
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 2)
        var level = 0
        var inString = false
        var escaped = false
        func newline() {
            out.append(0x0A)
            for _ in 0..<level { out.append(contentsOf: pad) }
        }
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                i += 1
                continue
            }
            switch c {
            case 0x22: // "
                inString = true
                out.append(c)
            case 0x7B, 0x5B: // { [
                // Pusty obiekt/tablica w jednym wierszu: {} []
                var j = i + 1
                while j < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[j]) { j += 1 }
                if j < bytes.count, bytes[j] == (c == 0x7B ? 0x7D : 0x5D) {
                    out.append(c)
                    out.append(bytes[j])
                    i = j
                } else {
                    out.append(c)
                    level += 1
                    newline()
                }
            case 0x7D, 0x5D: // } ]
                level -= 1
                newline()
                out.append(c)
            case 0x2C: // ,
                // Przecinek końcowy (`[1,]` — Foundation go akceptuje) pomijamy zamiast wcinać pusty wiersz.
                var j = i + 1
                while j < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[j]) { j += 1 }
                if j < bytes.count, bytes[j] == 0x7D || bytes[j] == 0x5D { break }
                out.append(c)
                newline()
            case 0x3A: // :
                out.append(contentsOf: [0x3A, 0x20])
            case 0x20, 0x09, 0x0A, 0x0D:
                break // białe znaki poza napisami — wcięcia są nowe
            default:
                out.append(c)
            }
            i += 1
        }
        return .success(String(decoding: out, as: UTF8.self))
    }

    // MARK: XML

    /// `XMLDocument` z wcięciami. Zewnętrzne encje i DTD nie są wczytywane (plik nie może kazać
    /// przeglądarce czytać innych plików ani łączyć się z siecią — XXE).
    public static func formatXML(_ text: String, indent: Int = 2) -> Result<String, Failure> {
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA])
        } catch {
            return .failure(.invalid(error.localizedDescription))
        }
        var result = document.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
        // Deklaracja dokładnie jak w pliku: XMLDocument dopisuje ją, gdy jej nie było, i dodaje `standalone`.
        let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        let original = trimmed.hasPrefix("<?xml") ? trimmed.range(of: "?>").map { String(trimmed[..<$0.upperBound]) } : nil
        if result.hasPrefix("<?xml"), let end = result.range(of: "?>") {
            let rest = String(result[end.upperBound...]).trimmingCharacters(in: .newlines)
            result = original.map { $0 + "\n" + rest } ?? rest
        }
        if indent != 4 {
            // XMLDocument wcina po 4 spacje — przeliczenie wcięć na początku wierszy.
            let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
            var rebuilt: [String] = []
            rebuilt.reserveCapacity(lines.count)
            for line in lines {
                let spaces = line.prefix(while: { $0 == " " }).count
                let width = spaces / 4 * indent + spaces % 4
                rebuilt.append(String(repeating: " ", count: width) + String(line.dropFirst(spaces)))
            }
            result = rebuilt.joined(separator: "\n")
        }
        return .success(result)
    }
}
