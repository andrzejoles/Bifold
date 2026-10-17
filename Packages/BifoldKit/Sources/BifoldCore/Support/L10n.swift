import Foundation
import Synchronization

/// Teksty interfejsu. Kluczem jest polskie zdanie (język źródłowy); tłumaczenia leżą w
/// `Localizable.xcstrings` celu aplikacji albo w zaimportowanym języku (`Translations`).
/// Brak tłumaczenia = polski tekst.
public enum L10n {
    private static let selected = Mutex<Bundle?>(nil)

    public static func tr(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: selected.withLock { $0 } ?? .main)
    }

    /// Katalog `.lproj` języka wybranego w Ustawieniach (`nil` = język systemu przez `Bundle.main`).
    /// Ustawiany przy starcie, przed zbudowaniem komend i menu.
    public static func use(_ bundle: Bundle?) {
        selected.withLock { $0 = bundle }
    }
}
