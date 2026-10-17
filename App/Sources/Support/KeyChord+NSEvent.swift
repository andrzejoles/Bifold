import AppKit
import BifoldWorkspace

extension KeyChord {
    private static let specialKeys: [UInt16: String] = [
        48: "tab", 36: "enter", 76: "enter", 49: "space", 51: "backspace", 117: "delete", 53: "escape",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17",
        79: "f18", 80: "f19", 90: "f20",
    ]

    /// Kombinacja z zdarzenia klawiatury. Znak bez modyfikatorów (np. Shift+8 → „8” + shift),
    /// żeby skróty nie zależały od tego, co Shift/Option wpisuje w danym układzie klawiatury.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: KeyModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if let special = KeyChord.specialKeys[event.keyCode] {
            self.init(key: special, modifiers: mods)
            return
        }
        guard let chars = event.characters(byApplyingModifiers: []), let first = chars.first else { return nil }
        self.init(key: String(first).lowercased(), modifiers: mods)
    }

    /// Odpowiednik dla `NSMenuItem.keyEquivalent` (tylko skróty, które nie kolidują z pisaniem
    /// tekstu: z Cmd albo Ctrl, oraz klawisze funkcyjne).
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        let isFunction = key.hasPrefix("f") && key.count > 1 && Int(key.dropFirst()) != nil
        guard isFunction || modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        let named: [String: Int] = [
            "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey, "left": NSLeftArrowFunctionKey,
            "right": NSRightArrowFunctionKey, "home": NSHomeFunctionKey, "end": NSEndFunctionKey,
            "pageup": NSPageUpFunctionKey, "pagedown": NSPageDownFunctionKey, "delete": NSDeleteFunctionKey,
        ]
        if isFunction, let n = Int(key.dropFirst()) {
            return (String(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!)), flags)
        }
        if let code = named[key] { return (String(Character(UnicodeScalar(code)!)), flags) }
        switch key {
        case "tab": return ("\t", flags)
        case "enter": return ("\r", flags)
        case "space": return (" ", flags)
        case "backspace": return (String(Character(UnicodeScalar(8))), flags)
        case "escape": return (String(Character(UnicodeScalar(27))), flags)
        default: return key.count == 1 ? (key, flags) : nil
        }
    }
}
