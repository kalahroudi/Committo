import Foundation

/// Minimal dynamic JSON used by the MCP layer and agent stream parsing.
public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public subscript(index: Int) -> JSONValue? { if case .array(let a) = self, a.indices.contains(index) { return a[index] }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public static func parse(_ s: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
    public func serialized(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? "null"
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
