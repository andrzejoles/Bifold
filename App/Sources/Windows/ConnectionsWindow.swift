import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftUI

/// Menedżer połączeń: SFTP, SCP, FTP/FTPS, WebDAV, SMB, Google Drive, Dropbox, OneDrive.
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
    /// Formularz pokazuje zapisane połączenie — alias jest wtedy zablokowany (zmiana tworzyłaby
    /// duplikat bez hasła, a stary wpis z hasłem w Pęku kluczy zostawałby).
    @State private var editingExisting = false

    private var remotes: RemoteManager { workspace.remotes }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(remotes.connections, selection: $selection) { c in
                    HStack {
                        Image(systemName: c.kind.usesOAuth ? "cloud" : "server.rack")
                        VStack(alignment: .leading) {
                            Text(c.alias)
                            Text(c.kind.displayName + (c.kind.agentLevelIsApproval ? L10n.tr(" · agent: za zgodą") : L10n.tr(" · agent: odczyt"))
                                 + (remotes.connected.contains(c.alias) ? L10n.tr(" · połączono") : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(c.alias)
                }
                HStack {
                    Button(L10n.tr("Nowe")) {
                        selection = nil
                        select(nil)
                    }
                    Button(L10n.tr("Usuń")) {
                        if let s = selection { confirmRemove(s) }
                    }
                    .disabled(selection == nil)
                }
                .padding(6)
            }
            .frame(minWidth: 220)

            Form {
                TextField(L10n.tr("Alias (widoczny dla agenta)"), text: $draft.alias, prompt: Text("prod-logi"))
                    .disabled(editingExisting)
                    .help(editingExisting ? L10n.tr("Aliasu zapisanego połączenia nie można zmienić — utwórz nowe połączenie i usuń stare.") : "")
                Picker(L10n.tr("Rodzaj"), selection: $draft.kind) {
                    ForEach(RemoteKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if !draft.kind.usesOAuth {
                    TextField(draft.kind == .webdav ? L10n.tr("Adres URL") : L10n.tr("Serwer"), text: $draft.host, prompt: Text(draft.kind == .webdav ? "https://dav.example.com/remote.php/dav" : "serwer.example.com"))
                    if draft.kind != .webdav { TextField(L10n.tr("Port (puste = domyślny)"), text: $portText, prompt: Text(draft.kind.usesSSH ? "22" : (draft.kind == .smb ? "445" : "21"))) }
                    TextField(L10n.tr("Użytkownik"), text: $draft.user, prompt: Text("login"))
                    SecureField(draft.kind.usesSSH && !draft.keyFile.isEmpty ? L10n.tr("Hasło klucza (opcjonalnie)") : L10n.tr("Hasło (zapis w Keychain)"), text: $secret, prompt: Text(L10n.tr("bez zmian")))
                    if draft.kind.usesSSH {
                        HStack {
                            TextField(L10n.tr("Plik klucza SSH (puste = agent SSH lub hasło)"), text: $draft.keyFile, prompt: Text("~/.ssh/id_ed25519"))
                            Button(L10n.tr("Wybierz…")) { chooseKey() }
                        }
                        Toggle(L10n.tr("Zgodność ze starymi serwerami (AIX, stary OpenSSH)"), isOn: Binding(
                            get: { draft.legacyAlgorithms ?? false }, set: { draft.legacyAlgorithms = $0 ? true : nil }))
                        Text(L10n.tr("Włącza algorytmy diffie-hellman-group1/14-sha1, ssh-rsa i szyfry CBC — tylko dla serwerów, które nie znają nowszych."))
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle(L10n.tr("Przy otwarciu: terminal SSH w drugim panelu"), isOn: Binding(
                            get: { draft.openTerminal ?? true }, set: { draft.openTerminal = $0 ? nil : false }))
                        Picker(L10n.tr("Typ terminala (TERM)"), selection: Binding(
                            get: { draft.effectiveTerminalType },
                            set: { draft.terminalType = $0 == RemoteConnection.defaultTerminalType ? nil : $0 })) {
                            ForEach(terminalTypeChoices, id: \.self) { Text($0).tag($0) }
                        }
                        Text(L10n.tr("Gdy programy na serwerze (mc, vi, smitty) źle rysują ekran, nie mają kolorów albo nie reagują na klawisze F1–F10, wybierz typ, który serwer zna — na starym AIX zwykle xterm. Zmiana działa od następnego otwarcia terminala."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.kind == .scp {
                        Picker(L10n.tr("Kodowanie nazw na serwerze"), selection: Binding(
                            get: { draft.nameEncoding ?? .utf8 }, set: { draft.nameEncoding = $0 == .utf8 ? nil : $0 })) {
                            ForEach(NameEncoding.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Text(L10n.tr("Klasyczny protokół SCP (scp -O) i polecenia powłoki przez SSH — dla serwerów bez SFTP. Klucz serwera zapamiętywany w ~/.ssh/known_hosts przy pierwszym połączeniu."))
                            .font(.caption).foregroundStyle(.secondary)
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
                    if draft.kind.usesSSH {
                        Button(L10n.tr("Terminal SSH")) {
                            save()
                            workspace.perform("remote.terminal", CommandArguments(["alias": .string(draft.alias)]))
                        }
                        .disabled(draft.alias.isEmpty)
                    }
                    if remotes.connected.contains(draft.alias) {
                        Button(L10n.tr("Rozłącz")) {
                            workspace.perform("remote.disconnect", CommandArguments(["alias": .string(draft.alias)]))
                            status = L10n.tr("Rozłączono \(draft.alias)")
                        }
                    }
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

    /// Typy z listy plus typ wpisany ręcznie w `connections.json`.
    private var terminalTypeChoices: [String] {
        let t = draft.effectiveTerminalType
        return RemoteConnection.terminalTypes.contains(t) ? RemoteConnection.terminalTypes : RemoteConnection.terminalTypes + [t]
    }

    private func select(_ alias: String?) {
        if let alias, let c = remotes.connection(alias) {
            draft = c
            portText = c.port.map(String.init) ?? ""
            editingExisting = true
        } else {
            draft = RemoteConnection(alias: "", kind: .sftp)
            portText = ""
            editingExisting = false
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

    /// Usunięcie kasuje też hasło lub token z Pęku kluczy — tylko po potwierdzeniu; domyślny przycisk
    /// (Return) to „Anuluj”, „Usuń” wymaga kliknięcia (jak D23).
    private func confirmRemove(_ alias: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Usunąć połączenie „\(alias)”?")
        alert.informativeText = L10n.tr("Z Pęku kluczy zostaną też usunięte zapisane dane logowania (hasło lub token).")
        alert.addButton(withTitle: L10n.tr("Anuluj"))
        let remove = alert.addButton(withTitle: L10n.tr("Usuń"))
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else { return }
            do {
                try remotes.remove(alias)
                selection = nil
                select(nil)
            } catch {
                status = "✕ " + error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
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
