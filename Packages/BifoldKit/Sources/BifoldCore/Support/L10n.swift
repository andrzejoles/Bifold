import Foundation

/// Teksty interfejsu. Kluczem jest polskie zdanie (język źródłowy); tłumaczenia leżą w
/// `Localizable.xcstrings` celu aplikacji, dlatego szukamy w `Bundle.main`.
public enum L10n {
    public static func tr(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .main)
    }
}

