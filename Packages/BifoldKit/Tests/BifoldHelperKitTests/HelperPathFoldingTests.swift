import Foundation
import Testing
@testable import BifoldHelperKit

/// Lista katalogów zabronionych porównywana tak, jak APFS składa nazwy: `lowercased()` nie zamienia
/// długiego „ſ” na „s”, a APFS traktuje „LaunchDaemonſ” jak „LaunchDaemons”.
@Suite struct HelperPathFoldingTests {
    @Test func unicodeCaseFoldingLikeAPFS() throws {
        for bad in ["/Library/LaunchDaemonſ", "/Library/LaunchDaemonſ/x.plist", "/private/etc/ſudoers", "/private/etc/ſsh",
                    "/Library/\u{212A}eychains", "/LIBRARY/LAUNCHAGENTſ", "/ſyſtem", "/Library/Keychains".decomposedStringWithCanonicalMapping] {
            #expect(throws: HelperError.self, "\(bad)") { try HelperOperations.validate(bad) }
        }
        // Zwykłe nazwy (także z polskimi znakami) nadal dozwolone.
        #expect(try HelperOperations.validate("/Applications/Zażółć.app") == "/Applications/Zażółć.app")
        #expect(HelperOperations.fold("/Library/LaunchDaemonſ") == HelperOperations.fold("/library/launchdaemons"))
    }
}
