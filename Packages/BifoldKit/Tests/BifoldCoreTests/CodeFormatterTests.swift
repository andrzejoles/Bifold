import Foundation
import Testing
@testable import BifoldCore

/// „Formatuj” w przeglądarce F3: JSON (kolejność kluczy i zapis liczb bez zmian) i XML (bez encji zewnętrznych).
@Suite struct CodeFormatterTests {
    @Test func jsonKeepsOrderNumbersAndStrings() throws {
        let input = #"{"z":1.0,"a":[1,2,{"x":"a,b:{c}\"d"}],"e":{},"f":[],"g":1e3,"h":null}"#
        let out = try CodeFormatter.formatJSON(input).get()
        #expect(out == """
        {
          "z": 1.0,
          "a": [
            1,
            2,
            {
              "x": "a,b:{c}\\"d"
            }
          ],
          "e": {},
          "f": [],
          "g": 1e3,
          "h": null
        }
        """)
        // Ponowne formatowanie niczego nie zmienia, a wynik to ten sam dokument.
        #expect(try CodeFormatter.formatJSON(out).get() == out)
        let a = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? NSDictionary
        #expect(a == b)
    }

    @Test func jsonInvalidIsReported() throws {
        // Przecinek końcowy akceptuje Foundation — formatowanie go pomija.
        #expect(try CodeFormatter.formatJSON(#"{"a": [1,],}"#).get() == "{\n  \"a\": [\n    1\n  ]\n}")
        guard case .failure(.invalid) = CodeFormatter.formatJSON(#"{"a": }"#) else {
            Issue.record("niepoprawny JSON powinien zostać odrzucony")
            return
        }
    }

    @Test func xmlIndentsAndKeepsDeclarationChoice() throws {
        let out = try CodeFormatter.formatXML("<root><a x=\"1\">tekst</a><b/><!-- uwaga --></root>").get()
        #expect(!out.hasPrefix("<?xml"))
        #expect(out.contains("\n  <a x=\"1\">tekst</a>"))
        #expect(out.contains("\n  <b/>"))
        #expect(out.contains("<!-- uwaga -->"))
        let declared = try CodeFormatter.formatXML("<?xml version=\"1.0\" encoding=\"UTF-8\"?><r><s/></r>").get()
        #expect(declared.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<r>"))
        #expect(!declared.contains("standalone"))
    }

    @Test func xmlDoesNotLoadExternalEntities() throws {
        let tmp = try TempDir()
        let secret = try tmp.file("sekret.txt", "TAJNE-DANE")
        let xxe = """
        <?xml version="1.0"?>
        <!DOCTYPE r [<!ENTITY x SYSTEM "file://\(secret.path)">]>
        <r>&x;</r>
        """
        if case .success(let out) = CodeFormatter.formatXML(xxe) {
            #expect(!out.contains("TAJNE-DANE"))
        }
    }

    @Test func xmlInvalidAndLimits() {
        guard case .failure(.invalid) = CodeFormatter.formatXML("<a><b></a>") else {
            Issue.record("niepoprawny XML powinien zostać odrzucony")
            return
        }
        #expect(CodeFormatter.supports(language: "json") && CodeFormatter.supports(language: "xml"))
        #expect(!CodeFormatter.supports(language: "swift") && !CodeFormatter.supports(language: nil))
        let big = String(repeating: " ", count: CodeFormatter.maxBytes + 1)
        guard case .failure(.tooLarge) = CodeFormatter.format(big, language: "json") else {
            Issue.record("za duży tekst powinien zostać pominięty")
            return
        }
    }
}
