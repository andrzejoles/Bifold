import Foundation

/// Kolor zapisany jako `#RRGGBB` lub `#RRGGBBAA`.
public struct HexColor: Codable, Sendable, Hashable, CustomStringConvertible {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        } else {
            self.init(
                red: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
                blue: Double((v >> 8) & 0xFF) / 255, alpha: Double(v & 0xFF) / 255)
        }
    }

    public var hex: String {
        func c(_ x: Double) -> String { String(format: "%02X", Int((x * 255).rounded())) }
        return "#" + c(red) + c(green) + c(blue) + (alpha < 1 ? c(alpha) : "")
    }

    public var description: String { hex }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = HexColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Nieprawidłowy kolor: \(s)"))
        }
        self = c
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public static let red = HexColor(hex: "#D70015")!
}

/// Styl nazwy pliku wynikający z reguły.
public struct FileStyle: Codable, Sendable, Hashable {
    public var textColor: HexColor?
    public var backgroundColor: HexColor?
    public var bold: Bool
    public var italic: Bool
    public var strikethrough: Bool

    public init(textColor: HexColor? = nil, backgroundColor: HexColor? = nil, bold: Bool = false, italic: Bool = false, strikethrough: Bool = false) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
    }

    enum CodingKeys: String, CodingKey { case textColor, backgroundColor, bold, italic, strikethrough }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textColor = try c.decodeIfPresent(HexColor.self, forKey: .textColor)
        backgroundColor = try c.decodeIfPresent(HexColor.self, forKey: .backgroundColor)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
    }
}

public enum TimeUnit: String, Codable, Sendable, CaseIterable {
    case minutes, hours, days, weeks, months, years

    func date(byGoingBack amount: Int, from now: Date, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component = switch self {
        case .minutes: .minute
        case .hours: .hour
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        case .years: .year
        }
        return calendar.date(byAdding: component, value: -amount, to: now) ?? now
    }
}

public enum DateField: String, Codable, Sendable, CaseIterable { case modified, created }

public enum FileAttributeFlag: String, Codable, Sendable, CaseIterable {
    case directory, file, symlink, hidden, executable, readOnly, locked
}

/// Warunek reguły kolorowania.
public enum ColorCondition: Sendable, Hashable {
    case olderThan(amount: Int, unit: TimeUnit, field: DateField)
    case newerThan(amount: Int, unit: TimeUnit, field: DateField)
    case largerThan(bytes: Int64)
    case smallerThan(bytes: Int64)
    case extensions([String])
    case nameMask(String)
    case nameRegex(String)
    case attribute(FileAttributeFlag, Bool)

    func matches(_ item: FileItem, now: Date, cache: RegexCache) -> Bool {
        switch self {
        case let .olderThan(amount, unit, field):
            guard let d = field == .modified ? item.modified : item.created else { return false }
            return d < unit.date(byGoingBack: amount, from: now)
        case let .newerThan(amount, unit, field):
            guard let d = field == .modified ? item.modified : item.created else { return false }
            return d >= unit.date(byGoingBack: amount, from: now)
        case let .largerThan(bytes):
            return !item.isDirectory && item.size > bytes
        case let .smallerThan(bytes):
            return !item.isDirectory && item.size >= 0 && item.size < bytes
        case let .extensions(list):
            let ext = item.fileExtension.lowercased()
            return !ext.isEmpty && list.contains { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == ext }
        case let .nameMask(mask):
            return cache.mask(mask).matches(item)
        case let .nameRegex(pattern):
            return cache.regex(pattern).matches(item.name)
        case let .attribute(flag, expected):
            let actual: Bool = switch flag {
            case .directory: item.isNavigable
            case .file: item.kind == .file
            case .symlink: item.kind == .symlink
            case .hidden: item.isHidden
            case .executable: item.isExecutable
            case .readOnly: item.isReadOnly
            case .locked: item.flags.contains(.locked)
            }
            return actual == expected
        }
    }
}

extension ColorCondition: Codable {
    private enum Keys: String, CodingKey { case type, amount, unit, field, bytes, list, mask, pattern, attribute, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "olderThan", "newerThan":
            let amount = try c.decode(Int.self, forKey: .amount)
            let unit = try c.decode(TimeUnit.self, forKey: .unit)
            let field = try c.decodeIfPresent(DateField.self, forKey: .field) ?? .modified
            self = type == "olderThan" ? .olderThan(amount: amount, unit: unit, field: field) : .newerThan(amount: amount, unit: unit, field: field)
        case "largerThan": self = .largerThan(bytes: try c.decode(Int64.self, forKey: .bytes))
        case "smallerThan": self = .smallerThan(bytes: try c.decode(Int64.self, forKey: .bytes))
        case "extensions": self = .extensions(try c.decode([String].self, forKey: .list))
        case "nameMask": self = .nameMask(try c.decode(String.self, forKey: .mask))
        case "nameRegex": self = .nameRegex(try c.decode(String.self, forKey: .pattern))
        case "attribute":
            self = .attribute(try c.decode(FileAttributeFlag.self, forKey: .attribute), try c.decodeIfPresent(Bool.self, forKey: .value) ?? true)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Nieznany warunek: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .olderThan(amount, unit, field), let .newerThan(amount, unit, field):
            if case .olderThan = self { try c.encode("olderThan", forKey: .type) } else { try c.encode("newerThan", forKey: .type) }
            try c.encode(amount, forKey: .amount)
            try c.encode(unit, forKey: .unit)
            try c.encode(field, forKey: .field)
        case let .largerThan(bytes):
            try c.encode("largerThan", forKey: .type)
            try c.encode(bytes, forKey: .bytes)
        case let .smallerThan(bytes):
            try c.encode("smallerThan", forKey: .type)
            try c.encode(bytes, forKey: .bytes)
        case let .extensions(list):
            try c.encode("extensions", forKey: .type)
            try c.encode(list, forKey: .list)
        case let .nameMask(mask):
            try c.encode("nameMask", forKey: .type)
            try c.encode(mask, forKey: .mask)
        case let .nameRegex(pattern):
            try c.encode("nameRegex", forKey: .type)
            try c.encode(pattern, forKey: .pattern)
        case let .attribute(flag, value):
            try c.encode("attribute", forKey: .type)
            try c.encode(flag, forKey: .attribute)
            try c.encode(value, forKey: .value)
        }
    }
}

public enum MatchMode: String, Codable, Sendable { case all, any }

public struct ColorRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: MatchMode
    public var conditions: [ColorCondition]
    public var style: FileStyle

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, match: MatchMode = .all, conditions: [ColorCondition], style: FileStyle) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.conditions = conditions
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case id, name, enabled, match, conditions, style }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        match = try c.decodeIfPresent(MatchMode.self, forKey: .match) ?? .all
        conditions = try c.decode([ColorCondition].self, forKey: .conditions)
        style = try c.decode(FileStyle.self, forKey: .style)
    }

    func matches(_ item: FileItem, now: Date, cache: RegexCache) -> Bool {
        guard enabled, !conditions.isEmpty else { return false }
        switch match {
        case .all: return conditions.allSatisfy { $0.matches(item, now: now, cache: cache) }
        case .any: return conditions.contains { $0.matches(item, now: now, cache: cache) }
        }
    }
}

/// Uporządkowana lista reguł; wygrywa pierwsza pasująca.
public struct ColorRuleSet: Codable, Sendable, Hashable {
    public var version: Int
    public var rules: [ColorRule]
    let cache = RegexCache()

    public init(rules: [ColorRule] = []) {
        version = 1
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case version, rules }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rules = try c.decode([ColorRule].self, forKey: .rules)
    }

    public static func == (a: Self, b: Self) -> Bool { a.version == b.version && a.rules == b.rules }
    public func hash(into h: inout Hasher) { h.combine(version); h.combine(rules) }

    public func style(for item: FileItem, now: Date = Date()) -> FileStyle? {
        rules.first { $0.matches(item, now: now, cache: cache) }?.style
    }

    public static func decode(json: Data) throws -> ColorRuleSet {
        try JSONDecoder().decode(ColorRuleSet.self, from: json)
    }

    public func encodedJSON() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Przykład z PROMPT.md: nazwy plików starszych niż 3 miesiące na czerwono.
    public static let defaults = ColorRuleSet(rules: [
        ColorRule(
            name: L10n.tr("Pliki starsze niż 3 miesiące"),
            conditions: [.olderThan(amount: 3, unit: .months, field: .modified), .attribute(.file, true)],
            style: FileStyle(textColor: .red)),
        ColorRule(
            name: L10n.tr("Pliki ukryte"),
            conditions: [.attribute(.hidden, true)],
            style: FileStyle(textColor: HexColor(hex: "#8E8E93"), italic: true)),
    ])
}

/// Skompilowane maski i wyrażenia regularne współdzielone przez reguły.
final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var masks: [String: NameMask] = [:]
    private var regexes: [String: NameRegex] = [:]

    func mask(_ s: String) -> NameMask {
        lock.withLock {
            if let m = masks[s] { return m }
            let m = NameMask(s)
            masks[s] = m
            return m
        }
    }

    func regex(_ s: String) -> NameRegex {
        lock.withLock {
            if let r = regexes[s] { return r }
            let r = NameRegex(s)
            regexes[s] = r
            return r
        }
    }
}
