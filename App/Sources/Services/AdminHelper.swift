import AppKit
import BifoldCore
import BifoldHelperKit
import BifoldWorkspace
import Security
import ServiceManagement

/// Klient pomocnika uprawnień administratora: rejestracja demona (SMAppService), autoryzacja
/// każdej operacji (Authorization Services — hasło administratora za każdym razem) i XPC.
final class AdminHelperClient {
    let workspace: Workspace
    private var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.plistName) }

    init(workspace: Workspace) {
        self.workspace = workspace
        workspace.register(commands())
    }

    var statusText: String {
        switch service.status {
        case .enabled: L10n.tr("zainstalowany")
        case .requiresApproval: L10n.tr("wymaga zatwierdzenia w Ustawieniach systemowych → Elementy logowania")
        case .notRegistered: L10n.tr("niezainstalowany")
        case .notFound: L10n.tr("brak w pakiecie aplikacji")
        @unknown default: L10n.tr("nieznany")
        }
    }

    func install() throws {
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return
            }
            throw CommandError.notAvailable(L10n.tr("Rejestracja pomocnika nie powiodła się: \(error.localizedDescription). Demony SMAppService wymagają podpisu z zespołem (DEVELOPMENT_TEAM w Config/Brand.xcconfig)."))
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() throws { try service.unregister() }

    /// Autoryzacja jednej operacji: prawo w bazie (tworzone przy pierwszym użyciu) i pytanie
    /// o hasło administratora (z dotkniętymi ścieżkami w treści pytania). Zwraca referencję i jej
    /// zewnętrzną formę dla demona — referencja musi żyć, dopóki demon jej nie sprawdzi (po
    /// `AuthorizationFree` demon nie odtworzy autoryzacji z formy zewnętrznej).
    func authorize(_ op: HelperOperation, paths: [String]) throws -> (AuthorizationRef, Data) {
        var created: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &created) == errAuthorizationSuccess, let ref = created else { throw HelperError.notAuthorized }
        do {
            if AuthorizationRightGet(op.right, nil) != errAuthorizationSuccess {
                let status = AuthorizationRightSet(ref, op.right, HelperOperations.rightRule as CFDictionary, op.prompt as CFString, nil, nil)
                guard status == errAuthorizationSuccess else { throw HelperError.failed("AuthorizationRightSet \(status)") }
            }
            let prompt = op.prompt + "\n\n" + paths.joined(separator: "\n")
            let status: OSStatus = op.right.withCString { name in
                kAuthorizationEnvironmentPrompt.withCString { promptKey in
                    prompt.withCString { promptText in
                        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                        var envItem = AuthorizationItem(name: promptKey, valueLength: strlen(promptText),
                                                        value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                        return withUnsafeMutablePointer(to: &item) { p in
                            withUnsafeMutablePointer(to: &envItem) { e in
                                var rights = AuthorizationRights(count: 1, items: p)
                                var environment = AuthorizationEnvironment(count: 1, items: e)
                                return AuthorizationCopyRights(ref, &rights, &environment, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                            }
                        }
                    }
                }
            }
            guard status == errAuthorizationSuccess else { throw status == errAuthorizationCanceled ? CommandError.cancelledByUser : HelperError.notAuthorized }
            var ext = AuthorizationExternalForm()
            guard AuthorizationMakeExternalForm(ref, &ext) == errAuthorizationSuccess else { throw HelperError.notAuthorized }
            return (ref, withUnsafeBytes(of: &ext) { Data($0) })
        } catch {
            AuthorizationFree(ref, [.destroyRights])
            throw error
        }
    }

    func perform(_ request: HelperRequest) async throws -> String {
        guard service.status == .enabled else {
            throw CommandError.notAvailable(L10n.tr("Pomocnik administratora: \(statusText). Użyj „Zainstaluj pomocnika administratora”."))
        }
        _ = try HelperOperations.check(request)
        let (ref, auth) = try authorize(request.operation, paths: request.paths)
        // Po odpowiedzi demona (albo błędzie) — prawa niszczone, żadna inna operacja z nich nie skorzysta.
        defer { AuthorizationFree(ref, [.destroyRights]) }
        let data = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: (any BifoldHelperProtocol).self)
        connection.resume()
        defer { connection.invalidate() }
        let replyData: Data = try await withCheckedThrowingContinuation { c in
            let proxy = connection.remoteObjectProxyWithErrorHandler { c.resume(throwing: $0) } as? any BifoldHelperProtocol
            guard let proxy else { c.resume(throwing: HelperError.failed("XPC")); return }
            proxy.perform(data, authorization: auth) { c.resume(returning: $0) }
        }
        let reply = try JSONDecoder().decode(HelperReply.self, from: replyData)
        guard reply.ok else { throw HelperError.failed(reply.message) }
        return reply.message
    }

    // MARK: Komendy (poziom agenta „Brak”)

    private func commands() -> [Command] {
        func cmd(_ id: String, _ title: String, _ summary: String, _ run: @escaping @MainActor @Sendable (CommandContext) async throws -> CommandResult) -> Command {
            Command(CommandDescriptor(id: CommandID(rawValue: id), title: title, category: .tools, agent: .none, effect: .modifiesFiles, summary: summary), run: run)
        }
        func target(_ ctx: CommandContext) throws -> FileItem {
            guard let item = ctx.tab.cursorItem, !item.isParentLink, item.path.isLocal else { throw CommandError.nothingSelected }
            return item
        }
        return [
            Command(CommandDescriptor(
                id: "admin.install", title: L10n.tr("Zainstaluj pomocnika administratora"), category: .tools,
                agent: .none, effect: .settings, summary: L10n.tr("Rejestruje demona uprawnień administratora (SMAppService)."))
            ) { [weak self] ctx in
                try self?.install()
                return CommandResult(message: self?.statusText)
            },
            cmd("admin.setOwner", L10n.tr("Jako administrator: zmień właściciela…"), L10n.tr("Zmienia właściciela elementu (uid:gid lub nazwa:grupa).")) { [weak self] ctx in
                let item = try target(ctx)
                let text = try await ctx.textPublic("owner", title: L10n.tr("Nowy właściciel \(item.name)"), message: L10n.tr("np. root:wheel albo 501:20"), default: "root:wheel")
                let parts = text.split(separator: ":").map(String.init)
                func uid(_ s: String) -> UInt32? { UInt32(s) ?? getpwnam(s).map { $0.pointee.pw_uid } }
                func gid(_ s: String) -> UInt32? { UInt32(s) ?? getgrnam(s).map { $0.pointee.gr_gid } }
                let req = HelperRequest(operation: .setOwner, paths: [item.path.path], owner: parts.first.flatMap(uid), group: parts.count > 1 ? gid(parts[1]) : nil)
                let msg = try await self?.perform(req)
                await ctx.tab.reload()
                return CommandResult(message: msg)
            },
            cmd("admin.setPermissions", L10n.tr("Jako administrator: zmień uprawnienia…"), L10n.tr("Zmienia prawa dostępu (ósemkowo).")) { [weak self] ctx in
                let item = try target(ctx)
                let text = try await ctx.textPublic("mode", title: L10n.tr("Uprawnienia \(item.name)"), message: L10n.tr("ósemkowo, np. 644"), default: String(item.permissions, radix: 8))
                guard let mode = UInt16(text, radix: 8) else { throw CommandError.invalidArgument("mode", text) }
                let msg = try await self?.perform(HelperRequest(operation: .setPermissions, paths: [item.path.path], mode: mode))
                await ctx.tab.reload()
                return CommandResult(message: msg)
            },
            cmd("admin.remove", L10n.tr("Jako administrator: usuń trwale…"), L10n.tr("Trwale usuwa element, do którego nie masz uprawnień.")) { [weak self] ctx in
                let item = try target(ctx)
                guard await ctx.ui?.confirm(title: L10n.tr("Usunąć trwale jako administrator?"), message: item.path.path, confirmTitle: L10n.tr("Usuń"), destructive: true) == true else {
                    throw CommandError.cancelledByUser
                }
                let msg = try await self?.perform(HelperRequest(operation: .remove, paths: [item.path.path]))
                await ctx.tab.reload()
                return CommandResult(message: msg)
            },
            cmd("admin.createDirectory", L10n.tr("Jako administrator: nowy katalog…"), L10n.tr("Tworzy katalog w chronionym miejscu.")) { [weak self] ctx in
                let name = try await ctx.textPublic("name", title: L10n.tr("Nowy katalog (administrator)"), message: nil, default: "")
                let msg = try await self?.perform(HelperRequest(operation: .createDirectory, paths: [ctx.tab.path.appending(name).path]))
                await ctx.tab.reload()
                return CommandResult(message: msg)
            },
            cmd("admin.copy", L10n.tr("Jako administrator: kopiuj do drugiego panelu"), L10n.tr("Kopiuje element do katalogu drugiego panelu z uprawnieniami administratora.")) { [weak self] ctx in
                let item = try target(ctx)
                let msg = try await self?.perform(HelperRequest(operation: .copy, paths: [item.path.path, ctx.otherTab.path.appending(item.name).path]))
                await ctx.otherTab.reload()
                return CommandResult(message: msg)
            },
            cmd("admin.move", L10n.tr("Jako administrator: przenieś do drugiego panelu"), L10n.tr("Przenosi element do katalogu drugiego panelu z uprawnieniami administratora.")) { [weak self] ctx in
                let item = try target(ctx)
                let msg = try await self?.perform(HelperRequest(operation: .move, paths: [item.path.path, ctx.otherTab.path.appending(item.name).path]))
                await ctx.tab.reload()
                await ctx.otherTab.reload()
                return CommandResult(message: msg)
            },
        ]
    }
}
