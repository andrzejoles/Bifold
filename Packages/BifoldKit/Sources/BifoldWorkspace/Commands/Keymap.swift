import BifoldCore
import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// Kombinacja klawiszy, np. `shift+f6`, `ctrl+t`, `cmd+=`. Klawisz w postaci kanonicznej:
/// pojedynczy znak (małe litery) albo nazwa (`f1`…`f20`, `tab`, `enter`, `space`, `backspace`,
/// `delete`, `escape`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`).
public struct KeyChord: Hashable, Sendable, Codable, CustomStringConvertible {
    public var key: String
    public var modifiers: KeyModifiers

    public static let namedKeys: Set<String> = Set((1...20).map { "f\($0)" }).union([
        "tab", "enter", "space", "backspace", "delete", "escape", "up", "down", "left", "right",
        "home", "end", "pageup", "pagedown",
    ])

    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public init?(string: String) {
        let raw = string.lowercased()
        // „+” jako klawisz: „cmd++”.
        var parts = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if raw.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        var mods: KeyModifiers = []
        for p in parts {
            switch p {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "alt", "opt", "option", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            default: return nil
            }
        }
        guard key.count == 1 || KeyChord.namedKeys.contains(key) else { return nil }
        self.init(key: key, modifiers: mods)
    }

    /// Postać tekstowa do plików konfiguracyjnych.
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Postać do wyświetlania w menu i palecie, np. `⌃⇧T`, `⇧F6`.
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names: [String: String] = [
            "tab": "⇥", "enter": "↩", "space": L10n.tr("Spacja"), "backspace": "⌫", "delete": "⌦", "escape": "⎋",
            "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        ]
        s += names[key] ?? key.uppercased()
        return s
    }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = KeyChord(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Nieprawidłowy skrót: \(s)"))
        }
        self = c
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Aktywne przypisanie skrótów: profil domyślny z rejestru + nadpisania użytkownika.
public struct Keymap: Sendable {
    public private(set) var bindings: [KeyChord: CommandID] = [:]
    public private(set) var chordsByCommand: [CommandID: [KeyChord]] = [:]

    /// - Parameter overrides: skrót → id komendy; pusty id usuwa domyślne przypisanie skrótu.
    public init(commands: [CommandDescriptor], profile: ShortcutProfile, overrides: [String: String] = [:]) {
        for c in commands {
            for chord in c.shortcuts[profile] ?? [] where bindings[chord] == nil {
                bindings[chord] = c.id
            }
        }
        for (chordString, commandID) in overrides {
            guard let chord = KeyChord(string: chordString) else { continue }
            if commandID.isEmpty { bindings.removeValue(forKey: chord) } else { bindings[chord] = CommandID(rawValue: commandID) }
        }
        for (chord, id) in bindings {
            chordsByCommand[id, default: []].append(chord)
        }
        for id in chordsByCommand.keys {
            chordsByCommand[id]!.sort { $0.description.count < $1.description.count }
        }
    }

    public func command(for chord: KeyChord) -> CommandID? { bindings[chord] }

    public func chords(for id: CommandID) -> [KeyChord] { chordsByCommand[id] ?? [] }

    /// Skróty przypisane do więcej niż jednej komendy w definicjach (do diagnostyki).
    public static func conflicts(in commands: [CommandDescriptor], profile: ShortcutProfile) -> [KeyChord: [CommandID]] {
        var map: [KeyChord: [CommandID]] = [:]
        for c in commands {
            for chord in c.shortcuts[profile] ?? [] { map[chord, default: []].append(c.id) }
        }
        return map.filter { $0.value.count > 1 }
    }
}
