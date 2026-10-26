import AppKit
import BifoldCore
import BifoldWorkspace
import UniformTypeIdentifiers

/// Język interfejsu (jak w CantatePresenter): wybór w Ustawieniach, eksport pliku do tłumaczenia
/// (dla tłumacza lub AI) i import gotowego tłumaczenia. Zmiana języka działa po ponownym
/// uruchomieniu — komendy i menu powstają przy starcie.
@Observable
final class LanguageService {
    static var shared: LanguageService!

    let translations: Translations
    /// Kod języka albo „system”.
    private(set) var preference: String
    /// Język, w którym działa bieżące uruchomienie.
    let active: String
    var notice = ""
    private(set) var languages: [Translations.Language]

    init(paths: AppPaths) {
        let translations = Translations(appBundle: .main, directory: paths.root.appending(path: "languages", directoryHint: .isDirectory))
        let preference = UserDefaults.standard.string(forKey: Translations.preferenceKey) ?? "system"
        self.translations = translations
        self.preference = preference
        active = translations.resolve(preference)
        languages = translations.languages
        L10n.use(translations.bundle(for: active))
    }

    var needsRestart: Bool { translations.resolve(preference) != active }

    func setPreference(_ value: String) {
        preference = value
        UserDefaults.standard.set(value, forKey: Translations.preferenceKey)
    }

    func register(in workspace: Workspace) {
        workspace.register([
            Command(CommandDescriptor(
                id: "app.exportTranslation", title: L10n.tr("Eksportuj plik do tłumaczenia…"), category: .tools, agent: .none, effect: .none,
                summary: L10n.tr("Zapisuje wszystkie teksty interfejsu do pliku JSON dla tłumacza lub AI (z bieżącym tłumaczeniem do poprawek)."))
            ) { [weak self] _ in
                try self?.exportFile()
                return .ok
            },
            Command(CommandDescriptor(
                id: "app.importTranslation", title: L10n.tr("Importuj tłumaczenie…"), category: .tools, agent: .none, effect: .settings,
                summary: L10n.tr("Wczytuje przetłumaczony plik JSON i dodaje język do Ustawień."))
            ) { [weak self] _ in
                try self?.importFile()
                return .ok
            },
        ])
    }

    func exportFile() throws {
        let panel = NSSavePanel()
        panel.title = L10n.tr("Eksportuj plik do tłumaczenia")
        panel.allowedContentTypes = [.json]
        let code = active == Translations.sourceLanguage ? nil : active
        panel.nameFieldStringValue = "bifold-tlumaczenie-\(code ?? "szablon").json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try translations.exportPackage(prefill: code).write(to: url, options: .atomic)
        notice = L10n.tr("Zapisano \(url.lastPathComponent): \(translations.sourceKeys.count) tekstów. Uzupełnij pola „translation” i zaimportuj plik.")
    }

    func importFile() throws {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Importuj tłumaczenie")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = try translations.importPackage(try Data(contentsOf: url))
        languages = translations.languages
        setPreference(result.code)
        notice = L10n.tr("Zaimportowano \(result.name) (\(result.code)): \(result.imported) tekstów.")
            + (result.rejected.isEmpty ? "" : " " + L10n.tr("Pominięto \(result.rejected.count) z niezgodnymi znacznikami (%@, %lld)."))
    }

    func remove(_ code: String) {
        try? translations.remove(code)
        languages = translations.languages
        if preference == code { setPreference("system") }
        notice = L10n.tr("Usunięto zaimportowany język \(code).")
    }

    /// Prośba o ponowne uruchomienie; kasowana, gdy zamknięcie zostanie anulowane (np. trwające operacje).
    var relaunchRequested = false

    /// Ponowne uruchomienie: nowa kopia startuje po zakończeniu tej. Skrypt startuje dopiero
    /// w `applicationWillTerminate` (`launchRelaunchHelperIfRequested`) — gdyby zamknięcie anulowano,
    /// aplikacja nie uruchomiłaby się sama później.
    func restart() {
        relaunchRequested = true
        NSApp.terminate(nil)
    }

    func launchRelaunchHelperIfRequested() {
        guard relaunchRequested else { return }
        relaunchRequested = false
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? p.run()
    }
}
