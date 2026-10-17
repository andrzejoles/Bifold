import BifoldCore
import Foundation

/// Wartość JSON — argumenty komend i wyniki (wspólne dla klawiatury, palety i API agenta).
public enum JSONValue: Codable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, CustomStringConvertible
{
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var intValue: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d): Int64(exactly: d.rounded())
        case .string(let s): Int64(s)
        default: nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Dowolna wartość Codable → JSONValue.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: JSONEncoder().encode(self))
    }

    public var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "?"
    }
}

/// Argumenty wywołania komendy.
public struct CommandArguments: Sendable, Hashable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) { self.values = values }

    public static let empty = CommandArguments()

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }

    public func string(_ key: String) -> String? { values[key]?.stringValue }
    public func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    public func int(_ key: String) -> Int64? { values[key]?.intValue }

    public func strings(_ key: String) -> [String]? {
        if let a = values[key]?.arrayValue { return a.compactMap(\.stringValue) }
        if let s = values[key]?.stringValue { return [s] }
        return nil
    }

    /// Ścieżka lokalna (rozwija `~`, względna = względem `base`).
    public func path(_ key: String, relativeTo base: VFSPath? = nil) -> VFSPath? {
        string(key).map { resolvePath($0, relativeTo: base) }
    }

    public func paths(_ key: String, relativeTo base: VFSPath? = nil) -> [VFSPath]? {
        strings(key).map { $0.map { resolvePath($0, relativeTo: base) } }
    }
}

public func resolvePath(_ raw: String, relativeTo base: VFSPath?) -> VFSPath {
    let expanded = expandTilde(raw)
    if expanded.hasPrefix("/") { return .local(expanded) }
    guard let base else { return .local("/" + expanded) }
    return VFSPath(provider: base.provider, path: base.path + "/" + expanded)
}
