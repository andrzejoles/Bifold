import AppKit
import BifoldCore

/// Wykrywanie pełnego dostępu do dysku (brak oficjalnego API — próba odczytu pliku
/// chronionego przez TCC, patrz DECISIONS.md D9).
enum FullDiskAccess {
    static var isGranted: Bool {
        let protected = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(protected, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        // Brak pliku (inne wersje systemu) — próba katalogu Safari.
        if errno == ENOENT {
            return (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
        }
        return false
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static let suppressKey = "FullDiskAccessInstructionsSuppressed"

    static func showInstructions(for window: NSWindow?, force: Bool = false) {
        if !force && UserDefaults.standard.bool(forKey: suppressKey) { return }
        let alert = NSAlert()
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.tr("Nie pokazuj przy starcie (instrukcja jest w Ustawieniach → Ogólne)")
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("\(Brand.appName) potrzebuje pełnego dostępu do dysku")
        alert.informativeText = L10n.tr("""
        Bez niego część katalogów (Poczta, Wiadomości, Safari, Kosz innych woluminów, katalogi innych aplikacji) będzie niewidoczna lub niedostępna.

        1. Kliknij „Otwórz Ustawienia systemowe”.
        2. W sekcji Prywatność i ochrona → Pełny dostęp do dysku kliknij „+” i wybierz \(Brand.appName) (albo włącz przełącznik, jeśli aplikacja jest już na liście).
        3. Uruchom \(Brand.appName) ponownie.
        """)
        alert.addButton(withTitle: L10n.tr("Otwórz Ustawienia systemowe"))
        alert.addButton(withTitle: L10n.tr("Później"))
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(settingsURL)
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}
