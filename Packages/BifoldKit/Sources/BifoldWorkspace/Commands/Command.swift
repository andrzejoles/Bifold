import BifoldCore
import Foundation

/// Poziom dostępu agenta AI do komendy (PROMPT.md, sekcja 5.4).
public enum AgentAccess: Int, Comparable, Codable, Sendable, CaseIterable {
    /// Narzędzie nie istnieje dla agenta.
    case none = 0
    /// Agent widzi stan lub wynik, nic nie zmienia.
    case read = 1
    /// Agent zgłasza operację, użytkownik zatwierdza po podglądzie.
    case approval = 2
    /// Agent wykonuje bez pytania; wszystko trafia do dziennika i da się cofnąć.
    case full = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var displayName: String {
        switch self {
        case .none: L10n.tr("Brak")
        case .read: L10n.tr("Odczyt")
        case .approval: L10n.tr("Za zgodą")
        case .full: L10n.tr("Pełny")
        }
    }
}

public struct CommandID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible, Comparable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public enum CommandCategory: String, Sendable, Codable, CaseIterable {
    case panel, tabs, view, selection, file, clipboard, edit, queue, tools, agent, help

    public var displayName: String {
        switch self {
        case .panel: L10n.tr("Panel")
        case .tabs: L10n.tr("Karty")
        case .view: L10n.tr("Widok")
        case .selection: L10n.tr("Zaznaczanie")
        case .file: L10n.tr("Plik")
        case .clipboard: L10n.tr("Schowek")
        case .edit: L10n.tr("Edycja")
        case .queue: L10n.tr("Kolejka")
        case .tools: L10n.tr("Narzędzia")
        case .agent: L10n.tr("Agent")
        case .help: L10n.tr("Pomoc")
        }
    }
}

/// Rodzaj skutków komendy (do podglądu i polityki uprawnień).
public enum CommandEffect: String, Sendable, Codable {
    /// Tylko odczyt stanu lub danych.
    case none
    /// Zmienia stan interfejsu (ścieżki, karty, zaznaczenie, widok).
    case uiState
    /// Zmienia pliki (wymaga dziennika i podglądu).
    case modifiesFiles
    /// Uruchamia zewnętrzny program, terminal lub powłokę.
    case external
    /// Zmienia ustawienia aplikacji.
    case settings
}

public enum ParameterType: String, Sendable, Codable {
    case string, path, paths, integer, boolean, object
}

public struct CommandParameter: Sendable, Hashable {
    public var name: String
    public var type: ParameterType
    public var required: Bool
    public var description: String
    public var allowedValues: [String]?

    public init(_ name: String, _ type: ParameterType, required: Bool = false, _ description: String, allowed: [String]? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        allowedValues = allowed
    }
}

public enum ShortcutProfile: String, Codable, Sendable, CaseIterable {
    /// Klawisze funkcyjne jak w Total Commanderze.
    case totalCommander
    /// Zamienniki z Cmd (gdy F1–F12 wymagają klawisza fn).
    case command

    public var displayName: String {
        switch self {
        case .totalCommander: L10n.tr("Total Commander (F1–F12)")
        case .command: L10n.tr("macOS (Cmd)")
        }
    }
}

public struct CommandDescriptor: Sendable {
    public let id: CommandID
    public let title: String
    public let category: CommandCategory
    public let shortcuts: [ShortcutProfile: [KeyChord]]
    public let parameters: [CommandParameter]
    public let agentAccess: AgentAccess
    public let effect: CommandEffect
    /// Opis skutków dla człowieka i dla agenta (opis narzędzia MCP).
    public let summary: String
    /// Czy pokazywać w menu (komendy pomocnicze typu `selection.toggle` tylko w palecie).
    public let inMenu: Bool

    public init(
        id: CommandID, title: String, category: CommandCategory, tc: [String] = [], cmd: [String]? = nil,
        parameters: [CommandParameter] = [], agent: AgentAccess, effect: CommandEffect, summary: String, inMenu: Bool = true
    ) {
        self.id = id
        self.title = title
        self.category = category
        // Profil Cmd: najpierw zamienniki z Cmd, potem te same skróty co w TC (F-klawisze
        // działają też z klawiszem fn).
        let tcChords = tc.compactMap(KeyChord.init(string:))
        var cmdChords: [KeyChord] = []
        for chord in (cmd ?? []).compactMap(KeyChord.init(string:)) + tcChords where !cmdChords.contains(chord) {
            cmdChords.append(chord)
        }
        shortcuts = [.totalCommander: tcChords, .command: cmdChords]
        self.parameters = parameters
        agentAccess = agent
        self.effect = effect
        self.summary = summary
        self.inMenu = inMenu
    }
}

/// Wynik komendy.
public struct CommandResult: Sendable {
    public var message: String?
    public var value: JSONValue?

    public init(message: String? = nil, value: JSONValue? = nil) {
        self.message = message
        self.value = value
    }

    public static let ok = CommandResult()
}

/// Skutki komendy policzone „na sucho”.
public struct EffectPreview: Sendable, Hashable, Codable {
    public var summary: String
    public var operations: [PlannedOperation]
    public var fileCount: Int
    public var totalBytes: Int64
    public var conflicts: [String]

    public init(summary: String, operations: [PlannedOperation] = [], fileCount: Int = 0, totalBytes: Int64 = 0, conflicts: [String] = []) {
        self.summary = summary
        self.operations = operations
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.conflicts = conflicts
    }
}

public enum CommandError: Error, LocalizedError, Sendable, Equatable {
    case unknownCommand(CommandID)
    case missingArgument(String)
    case invalidArgument(String, String)
    case nothingSelected
    case notAvailable(String)
    case cancelledByUser

    public var errorDescription: String? {
        switch self {
        case .unknownCommand(let id): L10n.tr("Nieznana komenda: \(id.rawValue)")
        case .missingArgument(let n): L10n.tr("Brak argumentu: \(n)")
        case .invalidArgument(let n, let why): L10n.tr("Nieprawidłowy argument \(n): \(why)")
        case .nothingSelected: L10n.tr("Nic nie zaznaczono")
        case .notAvailable(let why): why
        case .cancelledByUser: L10n.tr("Anulowano")
        }
    }
}

/// Kontekst wywołania: model, usługi interfejsu i kto wywołuje.
@MainActor
public struct CommandContext {
    public let workspace: Workspace
    public let invoker: Invoker
    public let arguments: CommandArguments

    public var ui: (any UIServices)? { workspace.ui }
    public var isAgent: Bool { invoker.isAgent }
}

public typealias CommandHandler = @MainActor @Sendable (CommandContext) async throws -> CommandResult
public typealias PreviewHandler = @MainActor @Sendable (CommandContext) async throws -> EffectPreview

public struct Command: Sendable {
    public let descriptor: CommandDescriptor
    let run: CommandHandler
    let preview: PreviewHandler?

    public init(_ descriptor: CommandDescriptor, preview: PreviewHandler? = nil, run: @escaping CommandHandler) {
        self.descriptor = descriptor
        self.run = run
        self.preview = preview
    }

    public var id: CommandID { descriptor.id }
}
