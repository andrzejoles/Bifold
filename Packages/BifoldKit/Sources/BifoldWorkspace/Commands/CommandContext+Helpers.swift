import BifoldCore
import Foundation

extension CommandContext {
    public var tab: Tab { workspace.activeTab }
    public var otherTab: Tab { workspace.otherTab }

    /// Elementy, na których działa komenda: argument `paths` (agent, paleta) albo zaznaczenie /
    /// element pod kursorem aktywnej karty.
    /// - Parameter allowNonLocal: elementy z archiwum/wyników innego dostawcy (kopiowanie, podgląd).
    ///   Domyślnie odrzucane — komendy zmieniające pliki działają tylko na plikach lokalnych.
    public func targets(allowEmpty: Bool = false, allowNonLocal: Bool = false) throws -> [FileItem] {
        let items = try rawTargets(allowEmpty: allowEmpty)
        if !allowNonLocal, items.contains(where: { !$0.path.isLocal }) {
            throw CommandError.notAvailable(L10n.tr("Archiwum jest tylko do odczytu — skopiuj elementy na dysk (F5)"))
        }
        return items
    }

    /// Minimalny opis elementu innego dostawcy; komendy zdalne uzupełniają typ i rozmiar z serwera.
    private func remoteItemSync(_ p: VFSPath) throws -> FileItem {
        FileItem(path: p, kind: .file, size: 0)
    }

    private func rawTargets(allowEmpty: Bool) throws -> [FileItem] {
        if let raw = arguments.strings("paths") {
            let fs = LocalFS()
            var items: [FileItem] = []
            for p in raw.map({ workspace.parsePath($0, relativeTo: tab.path) }) {
                if p.isLocal {
                    items.append(try fs.itemSync(at: p))
                } else if let item = tab.visibleItems.first(where: { $0.path == p }) {
                    items.append(item)
                } else {
                    // Element zdalny lub z archiwum spoza bieżącego listingu — z dostawcy.
                    items.append(try remoteItemSync(p))
                }
            }
            if items.isEmpty && !allowEmpty { throw CommandError.nothingSelected }
            return items
        }
        let items = tab.targets
        if items.isEmpty && !allowEmpty { throw CommandError.nothingSelected }
        return items
    }

    /// Wartość tekstowa z argumentu albo z okna dialogowego (tylko użytkownik).
    func text(_ key: String, title: String, message: String? = nil, default defaultValue: String = "", selectStem: Bool = false) async throws -> String {
        if let v = arguments.string(key) { return v }
        if isAgent { throw CommandError.missingArgument(key) }
        guard let ui, let v = await ui.promptText(title: title, message: message, defaultValue: defaultValue, selectStem: selectStem) else {
            throw CommandError.cancelledByUser
        }
        return v
    }

    /// Wersja publiczna (komendy rejestrowane przez aplikację).
    public func textPublic(_ key: String, title: String, message: String?, default defaultValue: String) async throws -> String {
        try await text(key, title: title, message: message, default: defaultValue)
    }

    func conflictPolicy() throws -> ConflictResolution? {
        guard let raw = arguments.string("conflict") else { return nil }
        guard let r = ConflictResolution(rawValue: raw), r != .cancel else {
            throw CommandError.invalidArgument("conflict", "skip | overwrite | rename | overwriteOlder")
        }
        return r
    }

    /// Bieżący katalog musi być lokalny (nie np. wyniki wyszukiwania) dla operacji tworzących pliki.
    func requireLocalDirectory() throws -> VFSPath {
        guard tab.path.isLocal else { throw CommandError.notAvailable(L10n.tr("Ta operacja wymaga zwykłego katalogu, nie listy wyników")) }
        return tab.path
    }

    func requireUI() throws -> any UIServices {
        guard let ui else { throw CommandError.notAvailable(L10n.tr("Ta komenda wymaga interfejsu")) }
        return ui
    }
}

/// Formatowanie rozmiarów i liczb w tekstach komend.
public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    public static func items(_ n: Int) -> String {
        switch n {
        case 1: L10n.tr("1 element")
        case 2...4: L10n.tr("\(n) elementy")
        default:
            (n % 10 >= 2 && n % 10 <= 4 && !(12...14).contains(n % 100)) ? L10n.tr("\(n) elementy") : L10n.tr("\(n) elementów")
        }
    }

    /// Opis elementów: „plik.txt” albo „3 elementy”.
    public static func describe(_ items: [FileItem]) -> String {
        items.count == 1 ? "„\(items[0].name)”" : Format.items(items.count)
    }
}
