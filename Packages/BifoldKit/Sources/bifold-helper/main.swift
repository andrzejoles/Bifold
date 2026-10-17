import BifoldHelperKit
import Foundation

// bifold-helper — demon uprawnień administratora (launchd, SMAppService). Przyjmuje połączenia
// XPC tylko od aplikacji spełniającej wymaganie podpisu (Info.plist: BifoldClientRequirement)
// i wykonuje wyłącznie operacje z `HelperOperation`, każdą po weryfikacji autoryzacji.

final class HelperService: NSObject, BifoldHelperProtocol {
    func perform(_ request: Data, authorization: Data, reply: @escaping @Sendable (Data) -> Void) {
        let result: HelperReply
        do {
            let r = try JSONDecoder().decode(HelperRequest.self, from: request)
            _ = try HelperOperations.check(r)
            guard HelperOperations.verify(authorization: authorization, for: r.operation) else { throw HelperError.notAuthorized }
            result = HelperReply(ok: true, message: try HelperOperations.execute(r))
        } catch {
            result = HelperReply(ok: false, message: error.localizedDescription)
        }
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperConstants.protocolVersion)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: String

    init(requirement: String) {
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Weryfikacja podpisu klienta przez system (audit token połączenia).
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: BifoldHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

let requirement = Bundle.main.object(forInfoDictionaryKey: "BifoldClientRequirement") as? String
    ?? "identifier \"local.aoles.bifold\""
let delegate = ListenerDelegate(requirement: requirement)
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
