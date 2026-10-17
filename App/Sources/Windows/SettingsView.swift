import AppKit
import BifoldCore
import BifoldWorkspace
import SwiftUI

/// Ustawienia (SwiftUI): ogólne, skróty, reguły kolorów, narzędzia, agenci AI.
struct SettingsView: View {
    let workspace: Workspace

    var body: some View {
        TabView {
            GeneralSettings(workspace: workspace).tabItem { Label(L10n.tr("Ogólne"), systemImage: "gearshape") }
            ShortcutSettings(workspace: workspace).tabItem { Label(L10n.tr("Skróty"), systemImage: "keyboard") }
            ColorRuleSettings(workspace: workspace).tabItem { Label(L10n.tr("Kolory"), systemImage: "paintpalette") }
            ToolSettings(workspace: workspace).tabItem { Label(L10n.tr("Narzędzia"), systemImage: "wrench.and.screwdriver") }
            AgentSettingsView(workspace: workspace).tabItem { Label(L10n.tr("Agenci AI"), systemImage: "cpu") }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }
}

/// Język interfejsu, eksport i import tłumaczeń (jak w CantatePresenter).
private struct LanguageSection: View {
    @Bindable var service = LanguageService.shared!

    var body: some View {
        Section(L10n.tr("Język interfejsu")) {
            Picker(L10n.tr("Język"), selection: Binding(get: { service.preference }, set: { service.setPreference($0) })) {
                Text(L10n.tr("Jak w systemie")).tag("system")
                ForEach(service.languages) { l in
                    Text("\(l.flag) \(l.name)" + (l.isCustom ? " · " + L10n.tr("zaimportowany") : "")).tag(l.code)
                }
            }
            if service.needsRestart {
                HStack {
                    Text(L10n.tr("Nowy język zadziała po ponownym uruchomieniu.")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("Uruchom ponownie")) { service.restart() }
                }
            }
            HStack {
                Button(L10n.tr("Eksportuj plik do tłumaczenia…")) { run { try service.exportFile() } }
                Button(L10n.tr("Importuj tłumaczenie…")) { run { try service.importFile() } }
                if let custom = service.languages.first(where: { $0.isCustom && $0.code == service.translations.resolve(service.preference) }) {
                    Button(L10n.tr("Usuń \(custom.name)")) { service.remove(custom.code) }
                }
            }
            Text(L10n.tr("Plik JSON zawiera wszystkie teksty po polsku z angielską podpowiedzią i instrukcją dla AI. Po przetłumaczeniu (pola „translation”) zaimportuj go — język pojawi się na liście. Eksport w wybranym języku pozwala poprawić istniejące tłumaczenie."))
                .font(.caption).foregroundStyle(.secondary)
            if !service.notice.isEmpty {
                Text(service.notice).font(.caption)
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { service.notice = "✕ " + error.localizedDescription }
    }
}

private struct GeneralSettings: View {
    @Bindable var workspace: Workspace

    var body: some View {
        Form {
            LanguageSection()
            Picker(L10n.tr("Motyw"), selection: $workspace.settings.theme) {
                ForEach(AppTheme.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Stepper(value: $workspace.settings.fontSize, in: 10...20, step: 1) {
                Text(L10n.tr("Rozmiar czcionki list: \(Int(workspace.settings.fontSize))"))
            }
            Toggle(L10n.tr("Pokazuj pliki ukryte"), isOn: $workspace.settings.showHiddenFiles)
            Toggle(L10n.tr("Pytaj przed przeniesieniem do Kosza (F8)"), isOn: $workspace.settings.confirmTrash)
            Toggle(L10n.tr("Drzewo katalogów w nowych panelach"), isOn: $workspace.settings.showTreeByDefault)
            Section(L10n.tr("Edytor (F4)")) {
                HStack {
                    TextField(L10n.tr("Aplikacja"), text: $workspace.settings.editorPath)
                    Button(L10n.tr("Wybierz…")) { chooseEditor() }
                }
                TextField(L10n.tr("Bundle id (gdy aplikacji nie ma pod ścieżką)"), text: $workspace.settings.editorBundleID)
            }
            Section(L10n.tr("Pełny dostęp do dysku")) {
                HStack {
                    Image(systemName: FullDiskAccess.isGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(FullDiskAccess.isGranted ? .green : .orange)
                    Text(FullDiskAccess.isGranted ? L10n.tr("Nadany") : L10n.tr("Brak — część katalogów jest niedostępna"))
                    Spacer()
                    Button(L10n.tr("Otwórz Ustawienia systemowe")) { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            workspace.settings.editorPath = url.path
            workspace.settings.editorBundleID = Bundle(url: url)?.bundleIdentifier ?? workspace.settings.editorBundleID
        }
    }
}

private struct ShortcutSettings: View {
    @Bindable var workspace: Workspace
    @State private var query = ""
    @State private var editing: CommandID?
    @State private var draft = ""
    @State private var error: String?

    private var commands: [CommandDescriptor] {
        workspace.registry.descriptors.filter {
            query.isEmpty || "\($0.title) \($0.id.rawValue)".range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L10n.tr("Profil"), selection: $workspace.settings.shortcutProfile) {
                    ForEach(ShortcutProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 360)
                Spacer()
                Button(L10n.tr("Przywróć domyślne")) { workspace.settings.keyOverrides = [:] }
            }
            Text(L10n.tr("F1–F12 na MacBooku wymagają klawisza fn (albo włącz „Używaj klawiszy F1, F2 itd. jako standardowych klawiszy funkcyjnych”). Profil macOS dodaje zamienniki z Cmd."))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L10n.tr("Szukaj komendy"), text: $query)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            List(commands, id: \.id) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.title)
                        Text(c.id.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if editing == c.id {
                        TextField("ctrl+shift+k", text: $draft).frame(width: 160).onSubmit { save(c.id) }
                        Button(L10n.tr("Zapisz")) { save(c.id) }
                        Button(L10n.tr("Anuluj")) { editing = nil }
                    } else {
                        Text(workspace.keymap.chords(for: c.id).map(\.displayString).joined(separator: "  "))
                            .foregroundStyle(.secondary)
                        Button(L10n.tr("Zmień")) {
                            editing = c.id
                            draft = workspace.keymap.chords(for: c.id).first?.description ?? ""
                            error = nil
                        }
                    }
                }
            }
        }
    }

    private func save(_ id: CommandID) {
        var overrides = workspace.settings.keyOverrides
        // Usuń dotychczasowe skróty tej komendy, dodaj nowy.
        for chord in workspace.keymap.chords(for: id) { overrides[chord.description] = "" }
        let text = draft.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            guard let chord = KeyChord(string: text) else {
                error = L10n.tr("Nieprawidłowy skrót: \(text) (np. ctrl+shift+k, cmd+alt+f5)")
                return
            }
            overrides[chord.description] = id.rawValue
        }
        workspace.settings.keyOverrides = overrides
        editing = nil
        error = nil
    }
}

private struct ColorRuleSettings: View {
    @Bindable var workspace: Workspace
    @State private var json = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("Reguły kolorowania plików — pierwsza pasująca reguła wygrywa. Warunki: olderThan / newerThan (amount, unit: minutes|hours|days|weeks|months|years, field: modified|created), largerThan / smallerThan (bytes), extensions (list), nameMask (mask), nameRegex (pattern), attribute (directory|file|symlink|hidden|executable|readOnly|locked, value). Styl: textColor, backgroundColor (#RRGGBB), bold, italic, strikethrough."))
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(workspace.colorRules.rules.enumerated()), id: \.element.id) { index, rule in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { workspace.colorRules.rules[index].enabled },
                            set: { workspace.colorRules.rules[index].enabled = $0 })).labelsHidden()
                        Text(rule.name.isEmpty ? L10n.tr("(bez nazwy)") : rule.name)
                            .foregroundStyle(rule.style.textColor.map { Color(nsColor: Theme.color($0)) } ?? .primary)
                            .bold(rule.style.bold).italic(rule.style.italic)
                        Spacer()
                        Text(L10n.tr("\(rule.conditions.count) warunków")).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 140)
            TextEditor(text: $json)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(L10n.tr("Zastosuj JSON")) { apply() }
                Button(L10n.tr("Przywróć domyślne")) {
                    workspace.colorRules = .defaults
                    reload()
                }
                Spacer()
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        json = (try? workspace.colorRules.encodedJSON()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        error = nil
    }

    private func apply() {
        do {
            workspace.colorRules = try ColorRuleSet.decode(json: Data(json.utf8))
            error = nil
            reload()
        } catch {
            self.error = L10n.tr("Błąd JSON: \(String(describing: error))")
        }
    }
}

private struct ToolSettings: View {
    @Bindable var workspace: Workspace

    private let tools: [(String, String, String)] = [
        ("rg", "ripgrep", L10n.tr("wyszukiwanie w treści")),
        ("7zz", "sevenzip", L10n.tr("archiwa")),
        ("rclone", "rclone", L10n.tr("serwery, chmury, synchronizacja")),
        ("mtp-detect", "libmtp", L10n.tr("telefony z Androidem")),
        ("idevice_id", "libimobiledevice", L10n.tr("iPhone")),
    ]

    var body: some View {
        Form {
            TextField(L10n.tr("Katalog narzędzi"), text: $workspace.settings.toolsDirectory)
            Section(L10n.tr("Narzędzia (Homebrew)")) {
                ForEach(tools, id: \.0) { tool in
                    HStack {
                        let path = workspace.settings.toolPath(tool.0)
                        Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(path != nil ? .green : .secondary)
                        Text("\(tool.0) — \(tool.2)")
                        Spacer()
                        if path == nil {
                            Text("brew install \(tool.1)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettingsView: View {
    @Bindable var workspace: Workspace
    @State private var blocked = ""

    var body: some View {
        Form {
            Toggle(L10n.tr("Tryb ścisły (CLI agenta bez własnej powłoki i edycji plików)"), isOn: $workspace.settings.agent.strictMode)
            Stepper(value: $workspace.settings.agent.maxReadBytes, in: 64 * 1024...64 * 1024 * 1024, step: 512 * 1024) {
                Text(L10n.tr("Maks. rozmiar odczytu pliku: \(Format.bytes(workspace.settings.agent.maxReadBytes))"))
            }
            Stepper(value: $workspace.settings.agent.callsPerMinute, in: 10...2000, step: 10) {
                Text(L10n.tr("Limit wywołań na minutę: \(workspace.settings.agent.callsPerMinute)"))
            }
            Section(L10n.tr("Zablokowane ścieżki (jedna w wierszu)")) {
                TextEditor(text: $blocked)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                HStack {
                    Button(L10n.tr("Zapisz listę")) {
                        workspace.settings.agent.blockedPaths = blocked.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    Button(L10n.tr("Przywróć domyślne")) {
                        workspace.settings.agent.blockedPaths = AgentSettings.defaultBlockedPaths
                        blocked = AgentSettings.defaultBlockedPaths.joined(separator: "\n")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { blocked = workspace.settings.agent.blockedPaths.joined(separator: "\n") }
    }
}

/// Edytor atrybutów i uprawnień (arkusz).
struct AttributesEditor: View {
    let items: [FileItem]
    let done: (AttributeChange?) -> Void
    @State private var bits: [Bool]
    @State private var changePermissions = false
    @State private var modified: Date
    @State private var changeModified = false
    @State private var created: Date
    @State private var changeCreated = false
    @State private var hidden: Bool
    @State private var locked: Bool

    init(items: [FileItem], done: @escaping (AttributeChange?) -> Void) {
        self.items = items
        self.done = done
        let first = items.first
        let p = first?.permissions ?? 0o644
        _bits = State(initialValue: (0..<9).map { p >> UInt16(8 - $0) & 1 == 1 })
        _modified = State(initialValue: first?.modified ?? Date())
        _created = State(initialValue: first?.created ?? Date())
        _hidden = State(initialValue: first?.flags.contains(.hidden) ?? false)
        _locked = State(initialValue: first?.flags.contains(.locked) ?? false)
    }

    private var octal: UInt16 {
        bits.enumerated().reduce(0) { $0 | ($1.element ? 1 << UInt16(8 - $1.offset) : 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Atrybuty: \(Format.describe(items))")).font(.headline)
            GroupBox {
                Toggle(L10n.tr("Zmień prawa dostępu"), isOn: $changePermissions)
                Grid(alignment: .leading) {
                    GridRow {
                        Text("")
                        Text(L10n.tr("odczyt")); Text(L10n.tr("zapis")); Text(L10n.tr("wykonanie"))
                    }
                    ForEach(0..<3, id: \.self) { who in
                        GridRow {
                            Text([L10n.tr("Właściciel"), L10n.tr("Grupa"), L10n.tr("Pozostali")][who])
                            ForEach(0..<3, id: \.self) { what in
                                Toggle("", isOn: $bits[who * 3 + what]).labelsHidden()
                            }
                        }
                    }
                }
                .disabled(!changePermissions)
                Text(String(octal, radix: 8)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            GroupBox {
                HStack {
                    Toggle(L10n.tr("Data modyfikacji"), isOn: $changeModified)
                    DatePicker("", selection: $modified).labelsHidden().disabled(!changeModified)
                }
                HStack {
                    Toggle(L10n.tr("Data utworzenia"), isOn: $changeCreated)
                    DatePicker("", selection: $created).labelsHidden().disabled(!changeCreated)
                }
            }
            HStack {
                Toggle(L10n.tr("Ukryty"), isOn: $hidden)
                Toggle(L10n.tr("Zablokowany"), isOn: $locked)
            }
            HStack {
                Spacer()
                Button(L10n.tr("Anuluj")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Zastosuj")) {
                    let first = items.first
                    done(AttributeChange(
                        permissions: changePermissions ? octal : nil,
                        modified: changeModified ? modified : nil,
                        created: changeCreated ? created : nil,
                        hidden: hidden != (first?.flags.contains(.hidden) ?? false) ? hidden : nil,
                        locked: locked != (first?.flags.contains(.locked) ?? false) ? locked : nil))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
