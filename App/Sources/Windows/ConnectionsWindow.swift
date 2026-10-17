import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftUI

/// Menedżer połączeń: SFTP, FTP/FTPS, WebDAV, SMB, Google Drive, Dropbox, OneDrive.
/// Hasła i tokeny w Keychain; agent widzi wyłącznie aliasy.
struct ConnectionsView: View {
    let workspace: Workspace
    var openTerminal: (String) -> Void
    @State private var selection: String?
    @State private var draft = RemoteConnection(alias: "", kind: .sftp)
    @State private var secret = ""
    @State private var portText = ""
    @State private var status = ""
    @State private var testing = false

    private var remotes: RemoteManager { workspace.remotes }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(remotes.connections, selection: $selection) { c in
                    HStack {
                        Image(systemName: c.kind.usesOAuth ? "cloud" : "server.rack")
                        VStack(alignment: .leading) {
                            Text(c.alias)
                            Text(c.kind.displayName + (c.kind.agentLevelIsApproval ? L10n.tr(" · agent: za zgodą") : L10n.tr(" · agent: odczyt")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(c.alias)
                }
                HStack {
                    Button(L10n.tr("Nowe")) { select(nil) }
                    Button(L10n.tr("Usuń")) {
                        if let s = selection { try? remotes.remove(s); select(nil) }
                    }
                    .disabled(selection == nil)
                }
                .padding(6)
            }
            .frame(minWidth: 220)

            Form {
                TextField(L10n.tr("Alias (widoczny dla agenta)"), text: $draft.alias, prompt: Text("prod-logi"))
                Picker(L10n.tr("Rodzaj"), selection: $draft.kind) {
                    ForEach(RemoteKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if !draft.kind.usesOAuth {
                    TextField(draft.kind == .webdav ? L10n.tr("Adres URL") : L10n.tr("Serwer"), text: $draft.host, prompt: Text(draft.kind == .webdav ? "https://dav.example.com/remote.php/dav" : "serwer.example.com"))
                    if draft.kind != .webdav { TextField(L10n.tr("Port (puste = domyślny)"), text: $portText, prompt: Text(draft.kind == .sftp ? "22" : (draft.kind == .smb ? "445" : "21"))) }
                    TextField(L10n.tr("Użytkownik"), text: $draft.user, prompt: Text("login"))
                    SecureField(draft.kind == .sftp && !draft.keyFile.isEmpty ? L10n.tr("Hasło klucza (opcjonalnie)") : L10n.tr("Hasło (zapis w Keychain)"), text: $secret, prompt: Text(L10n.tr("bez zmian")))
                    if draft.kind == .sftp {
                        HStack {
                            TextField(L10n.tr("Plik klucza SSH (puste = agent SSH lub hasło)"), text: $draft.keyFile, prompt: Text("~/.ssh/id_ed25519"))
                            Button(L10n.tr("Wybierz…")) { chooseKey() }
                        }
                    }
                } else {
                    Text(L10n.tr("Logowanie OAuth wykonujesz sam: „Autoryzuj w terminalu” uruchamia rclone authorize; skopiuj wypisany token (JSON) do pola poniżej."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("Autoryzuj w terminalu")) { openTerminal("rclone authorize \(draft.kind.rawValue)") }
                    TextField(L10n.tr("Token (JSON) — zapis w Keychain"), text: $secret, axis: .vertical).lineLimit(3...6)
                }
                TextField(L10n.tr("Katalog startowy na serwerze"), text: $draft.path, prompt: Text("/var/log"))
                HStack {
                    Button(L10n.tr("Zapisz")) { save() }.keyboardShortcut(.defaultAction).disabled(draft.alias.isEmpty)
                    Button(L10n.tr("Testuj połączenie")) { test() }.disabled(draft.alias.isEmpty || testing)
                    Button(L10n.tr("Otwórz w panelu")) {
                        save()
                        workspace.perform("remote.open", CommandArguments(["alias": .string(draft.alias)]))
                    }
                    .disabled(draft.alias.isEmpty)
                    if draft.kind == .smb {
                        Button(L10n.tr("Zamontuj (NetFS)")) {
                            save()
                            workspace.perform("remote.mount", CommandArguments(["alias": .string(draft.alias)]))
                        }
                    }
                }
                Text(status).font(.caption).foregroundStyle(status.hasPrefix("✓") ? .green : .secondary)
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)
        }
        .frame(minWidth: 760, minHeight: 460)
        .onChange(of: selection) { select($1) }
    }

    private func select(_ alias: String?) {
        if let alias, let c = remotes.connection(alias) {
            draft = c
            portText = c.port.map(String.init) ?? ""
        } else {
            draft = RemoteConnection(alias: "", kind: .sftp)
            portText = ""
        }
        secret = ""
        status = ""
    }

    private func save() {
        draft.port = Int(portText)
        do {
            try remotes.save(draft, secret: secret.isEmpty ? nil : secret)
            selection = draft.alias
            status = L10n.tr("Zapisano")
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() {
        save()
        testing = true
        status = L10n.tr("Łączenie…")
        let alias = draft.alias
        Task {
            defer { testing = false }
            do {
                let fs = try await remotes.provider(alias)
                let items = try await fs.list(fs.root, options: ListOptions(includeHidden: true))
                status = L10n.tr("✓ Połączono — elementów w katalogu startowym: \(items.count)")
            } catch {
                status = "✕ " + error.localizedDescription
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: NSHomeDirectory() + "/.ssh")
        if panel.runModal() == .OK, let url = panel.url { draft.keyFile = (url.path as NSString).abbreviatingWithTildeInPath }
    }
}

final class ConnectionsWindowController: NSWindowController {
    init(workspace: Workspace, openTerminal: @escaping (String) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Połączenia")
        window.setFrameAutosaveName("ConnectionsWindow")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ConnectionsView(workspace: workspace, openTerminal: openTerminal))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
