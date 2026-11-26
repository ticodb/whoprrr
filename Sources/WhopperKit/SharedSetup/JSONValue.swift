import Foundation

/// A JSON document as plain data: what a JavaScript checker sees. The shared-setup checker, the export and the fitting all
/// walk this instead of Swift types, so the rules read the same on the Mac and on the server.
///
/// Numbers are doubles, exactly like JavaScript: `6` and `6.0` are the same number, and a number is "whole" when it has no
/// fractional part.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading

    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    /// A number with no fractional part (JavaScript's `Number.isInteger`).
    public var integer: Int? {
        guard case .number(let n) = self, n.isFinite, n == n.rounded(), abs(n) <= 9_007_199_254_740_991 else { return nil }
        return Int(n)
    }

    public subscript(key: String) -> JSONValue? { object?[key] }

    // MARK: Building

    public static func int(_ i: Int) -> JSONValue { .number(Double(i)) }
    public static func strings(_ s: [String]) -> JSONValue { .array(s.map { .string($0) }) }

    // MARK: Bytes

    /// Parses UTF-8 JSON. Nil when it is not valid JSON or its top level is not an object or array.
    public static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return from(any)
    }

    private static func from(_ any: Any) -> JSONValue? {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case is NSNull: return .null
        case let a as [Any]:
            var out: [JSONValue] = []
            for x in a { guard let v = from(x) else { return nil }; out.append(v) }
            return .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, x) in o { guard let v = from(x) else { return nil }; out[k] = v }
            return .object(out)
        default: return nil
        }
    }

    private var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? NSNumber(value: Int64(n)) : NSNumber(value: n)
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    /// Compact UTF-8 JSON with sorted keys, so equal documents give equal bytes.
    public func encoded(pretty: Bool = false) -> Data {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { opts.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: foundation, options: opts)) ?? Data()
    }

    // MARK: Codable values

    /// Converts any encodable value (as the app's own settings do) to a JSON value.
    public static func of<T: Encodable>(_ v: T) -> JSONValue? {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(v) else { return nil }
        return parse(d)
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: encoded()) }
}

extension JSONValue: Codable {
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
}
