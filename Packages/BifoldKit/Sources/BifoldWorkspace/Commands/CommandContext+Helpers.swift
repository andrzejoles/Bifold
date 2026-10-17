import BifoldCore
import Foundation

extension CommandContext {
    public var tab: Tab { workspace.activeTab }
    public var otherTab: Tab { workspace.otherTab }

    /// Elementy, na których działa komenda: argument `paths` (agent, paleta) albo zaznaczenie /
    /// element pod kursorem aktywnej karty.
    public func targets(allowEmpty: Bool = false) throws -> [FileItem] {
        if let paths = arguments.paths("paths", relativeTo: tab.path) {
            let fs = LocalFS()
            let items = try paths.map { try fs.itemSync(at: $0) }
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

    func conflictPolicy() throws -> ConflictResolution? {
        guard let raw = arguments.string("conflict") else { return nil }
        guard let r = ConflictResolution(rawValue: raw), r != .cancel else {
            throw CommandError.invalidArgument("conflict", "skip | overwrite | rename | overwriteOlder")
        }
        return r
    }

    func requireUI() throws -> any UIServices {
        guard let ui else { throw CommandError.notAvailable(L10n.tr("Ta komenda wymaga interfejsu")) }
        return ui
    }
}

/// Formatowanie rozmiarów i liczb w tekstach komend.
public enum Format {
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
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
