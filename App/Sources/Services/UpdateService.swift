import AppKit
import BifoldCore
import BifoldWorkspace
import Sparkle

/// Automatyczne aktualizacje (Sparkle, jak w CantatePresenter): sprawdzanie raz dziennie, pobieranie
/// i instalacja w tle (SUAutomaticallyUpdate), nowa wersja startuje przy następnym uruchomieniu.
/// Każde wydanie musi mieć ważny podpis EdDSA kluczem właściciela (docs/WYDANIA.md).
final class UpdateService: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?

    /// Bez klucza publicznego albo kanału (np. kompilacja ze źródeł bez konfiguracji) aktualizacje są wyłączone.
    var isAvailable: Bool { controller != nil }

    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let key = info["SUPublicEDKey"] as? String ?? ""
        let feed = ProcessInfo.processInfo.environment["BIFOLD_UPDATE_FEED"] ?? info["SUFeedURL"] as? String ?? ""
        guard !key.isEmpty, URL(string: feed)?.scheme.map({ ["https", "http"].contains($0) }) == true else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        // Próba aktualizacji z lokalnym kanałem (docs/WYDANIA.md): od razu, bez czekania doby.
        if ProcessInfo.processInfo.environment["BIFOLD_UPDATE_CHECK_NOW"] == "1" {
            controller?.updater.checkForUpdatesInBackground()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// Komendy „O programie” i „Sprawdź uaktualnienia…” (rejestr komend, poziom agenta „Brak”).
    func register(in workspace: Workspace) {
        workspace.register([
            Command(CommandDescriptor(
                id: "app.about", title: L10n.tr("O programie \(Brand.appName)"), category: .help, agent: .none, effect: .uiState,
                summary: L10n.tr("Wersja, autor i licencja."), inMenu: false)
            ) { _ in
                Self.showAbout()
                return .ok
            },
            Command(CommandDescriptor(
                id: "app.checkForUpdates", title: L10n.tr("Sprawdź uaktualnienia…"), category: .help, agent: .none, effect: .uiState,
                summary: L10n.tr("Sprawdza, czy jest nowa wersja (aktualizacje instalują się też same, raz dziennie)."), inMenu: false)
            ) { [weak self] _ in
                guard let self, self.isAvailable else {
                    throw CommandError.notAvailable(L10n.tr("Aktualizacje są wyłączone w tej kompilacji (brak klucza SUPublicEDKey)"))
                }
                self.checkForUpdates(nil)
                return .ok
            },
        ])
    }

    static func showAbout() {
        let repo = Bundle.main.object(forInfoDictionaryKey: "BifoldRepository") as? String ?? ""
        let credits = NSMutableAttributedString(
            string: L10n.tr("Autor: Andrzej Oleś w kooperacji z Claude AI") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        if !repo.isEmpty, let url = URL(string: "https://github.com/\(repo)") {
            credits.append(NSAttributedString(string: L10n.tr("Kod źródłowy (licencja MIT): "), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            credits.append(NSAttributedString(string: "github.com/\(repo)", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: url]))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["BIFOLD_UPDATE_FEED"]
    }
}
