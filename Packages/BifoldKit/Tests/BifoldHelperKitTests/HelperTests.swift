import Foundation
import Testing
@testable import BifoldHelperKit

@Suite struct HelperTests {
    func tmp() throws -> URL {
        let base = URL(filePath: String(cString: realpath(NSTemporaryDirectory(), nil)))
        let u = base.appending(path: "bifold-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func pathValidation() throws {
        let t = try tmp()
        defer { try? FileManager.default.removeItem(at: t) }
        #expect(try HelperOperations.validate(t.path + "/x") == t.path + "/x")
        for bad in ["relative", "/System/Library/x", "/usr/bin/sudo", "/", t.path + "/../etc", "/etc/sudoers", "/private/etc/sudoers"] {
            #expect(throws: HelperError.self, "\(bad)") { try HelperOperations.validate(bad) }
        }
        // Dowiązanie do zabronionego katalogu — rozwiązywane przez realpath rodzica.
        try FileManager.default.createSymbolicLink(atPath: t.path + "/sys", withDestinationPath: "/System")
        #expect(throws: HelperError.self) { try HelperOperations.validate(t.path + "/sys/Library") }
    }

    @Test func requestShapeIsChecked() throws {
        let t = try tmp()
        defer { try? FileManager.default.removeItem(at: t) }
        #expect(throws: HelperError.self) { try HelperOperations.check(HelperRequest(operation: .move, paths: [t.path + "/a"])) }
        #expect(throws: HelperError.self) { try HelperOperations.check(HelperRequest(operation: .setPermissions, paths: [t.path + "/a"], mode: 0o17777)) }
        #expect(throws: HelperError.self) { try HelperOperations.check(HelperRequest(operation: .setOwner, paths: [t.path + "/a"])) }
        var r = HelperRequest(operation: .remove, paths: [t.path + "/a"])
        r.version = 99
        #expect(throws: HelperError.self) { try HelperOperations.check(r) }
    }

    /// Operacje na plikach użytkownika (bez roota) — ta sama ścieżka kodu co w demonie.
    @Test func executeOperations() throws {
        let t = try tmp()
        defer { try? FileManager.default.removeItem(at: t) }
        _ = try HelperOperations.execute(HelperRequest(operation: .createDirectory, paths: [t.path + "/d"]))
        FileManager.default.createFile(atPath: t.path + "/d/f", contents: Data("x".utf8))
        _ = try HelperOperations.execute(HelperRequest(operation: .setPermissions, paths: [t.path + "/d/f"], mode: 0o600))
        #expect((try FileManager.default.attributesOfItem(atPath: t.path + "/d/f")[.posixPermissions] as? Int) == 0o600)
        _ = try HelperOperations.execute(HelperRequest(operation: .copy, paths: [t.path + "/d/f", t.path + "/g"]))
        _ = try HelperOperations.execute(HelperRequest(operation: .move, paths: [t.path + "/g", t.path + "/h"]))
        #expect(throws: HelperError.self) { try HelperOperations.execute(HelperRequest(operation: .move, paths: [t.path + "/h", t.path + "/d/f"])) }
        _ = try HelperOperations.execute(HelperRequest(operation: .remove, paths: [t.path + "/d"]))
        #expect(!FileManager.default.fileExists(atPath: t.path + "/d"))
        #expect(throws: HelperError.self) { try HelperOperations.execute(HelperRequest(operation: .setOwner, paths: [t.path + "/h"], owner: 0)) }
    }

    @Test func authorizationWithoutRightsIsRejected() {
        #expect(!HelperOperations.verify(authorization: Data(), for: .remove))
        #expect(!HelperOperations.verify(authorization: Data(count: 32), for: .remove))
        #expect(HelperOperation.allCases.allSatisfy { $0.right.hasPrefix(HelperConstants.machService + ".") })
    }
}
