import Foundation

// JSON Schema for a Swift type, without macros and without a second model of
// your data. Python gets this from Pydantic; Swift already has `Decodable`, so
// loopl derives the schema by DECODING the type from a probing decoder: every
// key the synthesised `init(from:)` asks for is recorded with the type it
// asked for, `decodeIfPresent` marks the property optional, nested types and
// arrays recurse. Nothing is reflected, nothing is guessed from field names.
//
// It is honest about its limits: a type whose `init(from:)` validates its
// input (a raw-value enum, `URL`-like wrappers) cannot be probed, so those
// either conform to `SchemaEnum` or declare `JSONSchemaProviding`.

/// Declare the schema by hand when derivation cannot see it (validating
/// initialisers, unions, recursive types):
///
///     extension Weather: JSONSchemaProviding {
///         static var jsonSchema: JSONValue {
///             ToolSchema.object(["city": ToolSchema.string("City name")], required: ["city"])
///         }
///     }
public protocol JSONSchemaProviding {
    static var jsonSchema: JSONValue { get }
}

/// A `String`- or `Int`-backed enum the deriver can describe: conform (no
/// members needed) and the schema carries the `enum` list.
///
///     enum Condition: String, Codable, SchemaEnum { case sunny, cloudy, rain }
public protocol SchemaEnum: Decodable, CaseIterable, RawRepresentable {
    /// The `enum` values of the schema, in `allCases` order.
    static var schemaCaseValues: [JSONValue] { get }
    /// A sample case, used while probing an enclosing type (never returned to a caller).
    static var schemaProbeValue: Any { get }
}

public extension SchemaEnum {
    static var schemaCaseValues: [JSONValue] {
        allCases.map { c in
            switch c.rawValue {
            case let s as String: return .string(s)
            case let i as Int: return .number(Double(i))
            case let d as Double: return .number(d)
            default: return .string(String(describing: c.rawValue))
            }
        }
    }
    static var schemaProbeValue: Any { allCases.first as Any }
    /// `{"type": "string"|"integer", "enum": [...]}`.
    static var schemaForCases: JSONValue {
        let isNumber = allCases.first?.rawValue is Int || allCases.first?.rawValue is Double
        return .object(["type": .string(isNumber ? "integer" : "string"), "enum": .array(schemaCaseValues)])
    }
}

/// Derivation failed — the message says which type and what to do about it.
public struct SchemaDerivationError: LocalizedError, Sendable {
    public let type: String
    public let reason: String
    public init(type: String, reason: String) { self.type = type; self.reason = reason }
    public var errorDescription: String? {
        "cannot derive a JSON schema for \(type): \(reason). Declare it instead — "
        + "`extension \(type): JSONSchemaProviding { static var jsonSchema: JSONValue { … } }` "
        + "(or conform a raw-value enum to `SchemaEnum`)."
    }
}

/// JSON Schema derivation for `Decodable` types.
///
///     let schema = try JSONSchema.derive(Weather.self, describe: ["city": "City name"])
public enum JSONSchema {
    /// The schema of `type`: `{"type": "object", "properties": …, "required": […]}`.
    /// - Parameters:
    ///   - describe: descriptions by property path (`"city"`, `"address.city"`) — Swift has no
    ///     per-property doc comments at runtime, so this is where prose for the model goes.
    ///   - description: description of the object itself.
    public static func derive<T: Decodable>(_ type: T.Type,
                                            describe: [String: String] = [:],
                                            description: String? = nil) throws -> JSONValue {
        var schema: JSONValue
        if let provider = type as? any JSONSchemaProviding.Type {
            schema = provider.jsonSchema
        } else {
            schema = try SchemaProbe.probe(type, depth: 0).schema
        }
        for (path, text) in describe.sorted(by: { $0.key < $1.key }) {
            schema = annotate(schema, path: path.split(separator: ".").map(String.init), description: text)
        }
        if let description, var o = schema.objectValue {
            o["description"] = .string(description)
            schema = .object(o)
        }
        return schema
    }

    /// Attach a `description` to the property at `path` (silently ignored when the path is not there).
    static func annotate(_ schema: JSONValue, path: [String], description: String) -> JSONValue {
        guard var object = schema.objectValue, let head = path.first else { return schema }
        if var properties = object["properties"]?.objectValue, var child = properties[head] {
            if path.count == 1 {
                var c = child.objectValue ?? [:]
                c["description"] = .string(description)
                child = .object(c)
            } else {
                child = annotate(child, path: Array(path.dropFirst()), description: description)
            }
            properties[head] = child
            object["properties"] = .object(properties)
            return .object(object)
        }
        // arrays: describe the element through the same path
        if let items = object["items"] {
            object["items"] = annotate(items, path: path, description: description)
            return .object(object)
        }
        return schema
    }
}

// MARK: - the probing decoder

/// Collects what one probed type asked for. A class so nested containers can
/// fill it in after the enclosing property was recorded.
final class SchemaSink {
    struct Prop {
        var name: String
        var fixed: JSONValue?
        var nested: SchemaSink?
        var required: Bool
        var schema: JSONValue { fixed ?? nested?.schema ?? .object([:]) }
    }
    enum Shape {
        case unknown
        case scalar(JSONValue)
        case object([Prop])
        case array(JSONValue?, SchemaSink?)
    }
    var shape: Shape = .unknown

    func beginObject() { if case .object = shape {} else { shape = .object([]) } }
    func add(_ prop: Prop) {
        if case .object(var props) = shape {
            props.append(prop); shape = .object(props)
        } else {
            shape = .object([prop])
        }
    }
    func scalar(_ s: JSONValue) { shape = .scalar(s) }
    func beginArray() { if case .array = shape {} else { shape = .array(nil, nil) } }
    func element(fixed: JSONValue? = nil, nested: SchemaSink? = nil) { shape = .array(fixed, nested) }

    var schema: JSONValue {
        switch shape {
        case .unknown: return .object([:])
        case .scalar(let s): return s
        case .array(let fixed, let nested):
            return .object(["type": "array", "items": fixed ?? nested?.schema ?? .object([:])])
        case .object(let props):
            var properties: [String: JSONValue] = [:]
            var required: [JSONValue] = []
            for p in props {
                properties[p.name] = p.schema
                if p.required { required.append(.string(p.name)) }
            }
            return .object(["type": "object", "properties": .object(properties), "required": .array(required)])
        }
    }
}

enum SchemaScalar {
    static let string: JSONValue = ["type": "string"]
    static let number: JSONValue = ["type": "number"]
    static let integer: JSONValue = ["type": "integer"]
    static let boolean: JSONValue = ["type": "boolean"]
}

enum SchemaProbe {
    static let maxDepth = 8

    /// One probe: a dummy value of `T` (built out of placeholders) plus the schema it implies.
    static func probe<T: Decodable>(_ type: T.Type, depth: Int) throws -> (value: T, schema: JSONValue) {
        if depth > maxDepth {
            throw SchemaDerivationError(type: "\(type)", reason: "nested deeper than \(maxDepth) levels (recursive type?)")
        }
        // Foundation types whose decoders validate their input.
        if let special = known(type) { return special }
        if let e = type as? any SchemaEnum.Type {
            guard let value = e.schemaProbeValue as? T else {
                throw SchemaDerivationError(type: "\(type)", reason: "the enum has no cases")
            }
            return (value, e.schemaForCases)
        }
        let declared = (type as? any JSONSchemaProviding.Type)?.jsonSchema
        let sink = SchemaSink()
        do {
            let value = try type.init(from: SchemaDecoder(sink: sink, depth: depth))
            return (value, declared ?? sink.schema)
        } catch let error as SchemaDerivationError {
            throw error
        } catch {
            throw SchemaDerivationError(type: "\(type)",
                                        reason: "its initialiser rejected the probe (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))")
        }
    }

    private static func known<T: Decodable>(_ type: T.Type) -> (value: T, schema: JSONValue)? {
        func out(_ v: Any, _ s: JSONValue) -> (T, JSONValue)? { (v as? T).map { ($0, s) } }
        switch type {
        case is String.Type: return out("", SchemaScalar.string)
        case is Bool.Type: return out(false, SchemaScalar.boolean)
        case is Double.Type: return out(Double(0), SchemaScalar.number)
        case is Float.Type: return out(Float(0), SchemaScalar.number)
        case is Int.Type: return out(Int(0), SchemaScalar.integer)
        case is Int8.Type: return out(Int8(0), SchemaScalar.integer)
        case is Int16.Type: return out(Int16(0), SchemaScalar.integer)
        case is Int32.Type: return out(Int32(0), SchemaScalar.integer)
        case is Int64.Type: return out(Int64(0), SchemaScalar.integer)
        case is UInt.Type: return out(UInt(0), SchemaScalar.integer)
        case is UInt8.Type: return out(UInt8(0), SchemaScalar.integer)
        case is UInt16.Type: return out(UInt16(0), SchemaScalar.integer)
        case is UInt32.Type: return out(UInt32(0), SchemaScalar.integer)
        case is UInt64.Type: return out(UInt64(0), SchemaScalar.integer)
        case is URL.Type: return out(URL(string: "https://example.com")!, ["type": "string", "format": "uri"])
        case is UUID.Type: return out(UUID(), ["type": "string", "format": "uuid"])
        // `StructuredOutput` decodes dates as ISO-8601 (see `StructuredOutputOptions.decoder`).
        case is Date.Type: return out(Date(timeIntervalSince1970: 0), ["type": "string", "format": "date-time"])
        case is Data.Type: return out(Data(), ["type": "string", "contentEncoding": "base64"])
        case is Decimal.Type: return out(Decimal(0), SchemaScalar.number)
        case is JSONValue.Type: return out(JSONValue.object([:]), .object([:]))
        default: return nil
        }
    }
}

struct SchemaDecoder: Decoder {
    let sink: SchemaSink
    let depth: Int
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        sink.beginObject()
        return KeyedDecodingContainer(SchemaKeyedContainer<Key>(sink: sink, depth: depth))
    }
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        sink.beginArray()
        return SchemaUnkeyedContainer(sink: sink, depth: depth)
    }
    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SchemaSingleValueContainer(sink: sink, depth: depth)
    }
}

struct SchemaKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let sink: SchemaSink
    let depth: Int
    var codingPath: [any CodingKey] { [] }
    var allKeys: [Key] { [] }
    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    private func record(_ key: Key, _ schema: JSONValue, _ required: Bool) {
        sink.add(.init(name: key.stringValue, fixed: schema, nested: nil, required: required))
    }
    private func scalar<V>(_ key: Key, _ value: V, _ schema: JSONValue) -> V {
        record(key, schema, true); return value
    }
    private func optional<V>(_ key: Key, _ schema: JSONValue) -> V? {
        record(key, schema, false); return nil
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { scalar(key, false, SchemaScalar.boolean) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { scalar(key, "", SchemaScalar.string) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { scalar(key, 0, SchemaScalar.number) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { scalar(key, 0, SchemaScalar.number) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { scalar(key, 0, SchemaScalar.integer) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { scalar(key, 0, SchemaScalar.integer) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let probed = try SchemaProbe.probe(type, depth: depth + 1)
        record(key, probed.schema, true)
        return probed.value
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { optional(key, SchemaScalar.boolean) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { optional(key, SchemaScalar.string) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { optional(key, SchemaScalar.number) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { optional(key, SchemaScalar.number) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { optional(key, SchemaScalar.integer) }
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        let schema = (try? SchemaProbe.probe(type, depth: depth + 1).schema) ?? .object([:])
        record(key, schema, false)
        return nil
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let child = SchemaSink()
        child.beginObject()
        sink.add(.init(name: key.stringValue, fixed: nil, nested: child, required: true))
        return KeyedDecodingContainer(SchemaKeyedContainer<NestedKey>(sink: child, depth: depth + 1))
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let child = SchemaSink()
        child.beginArray()
        sink.add(.init(name: key.stringValue, fixed: nil, nested: child, required: true))
        return SchemaUnkeyedContainer(sink: child, depth: depth + 1)
    }
    func superDecoder() throws -> any Decoder { SchemaDecoder(sink: sink, depth: depth) }
    func superDecoder(forKey key: Key) throws -> any Decoder { SchemaDecoder(sink: sink, depth: depth) }
}

struct SchemaUnkeyedContainer: UnkeyedDecodingContainer {
    let sink: SchemaSink
    let depth: Int
    var codingPath: [any CodingKey] { [] }
    /// One element is probed: enough to describe `items`.
    var count: Int? { 1 }
    var currentIndex: Int = 0
    var isAtEnd: Bool { currentIndex >= 1 }

    private mutating func scalar<V>(_ value: V, _ schema: JSONValue) -> V {
        currentIndex += 1; sink.element(fixed: schema); return value
    }
    mutating func decodeNil() throws -> Bool { currentIndex += 1; return false }
    mutating func decode(_ type: Bool.Type) throws -> Bool { scalar(false, SchemaScalar.boolean) }
    mutating func decode(_ type: String.Type) throws -> String { scalar("", SchemaScalar.string) }
    mutating func decode(_ type: Double.Type) throws -> Double { scalar(0, SchemaScalar.number) }
    mutating func decode(_ type: Float.Type) throws -> Float { scalar(0, SchemaScalar.number) }
    mutating func decode(_ type: Int.Type) throws -> Int { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { scalar(0, SchemaScalar.integer) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { scalar(0, SchemaScalar.integer) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        currentIndex += 1
        let probed = try SchemaProbe.probe(type, depth: depth + 1)
        sink.element(fixed: probed.schema)
        return probed.value
    }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        currentIndex += 1
        let child = SchemaSink(); child.beginObject()
        sink.element(nested: child)
        return KeyedDecodingContainer(SchemaKeyedContainer<NestedKey>(sink: child, depth: depth + 1))
    }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        currentIndex += 1
        let child = SchemaSink(); child.beginArray()
        sink.element(nested: child)
        return SchemaUnkeyedContainer(sink: child, depth: depth + 1)
    }
    mutating func superDecoder() throws -> any Decoder { SchemaDecoder(sink: sink, depth: depth) }
}

struct SchemaSingleValueContainer: SingleValueDecodingContainer {
    let sink: SchemaSink
    let depth: Int
    var codingPath: [any CodingKey] { [] }
    func decodeNil() -> Bool { false }
    private func scalar<V>(_ value: V, _ schema: JSONValue) -> V { sink.scalar(schema); return value }
    func decode(_ type: Bool.Type) throws -> Bool { scalar(false, SchemaScalar.boolean) }
    func decode(_ type: String.Type) throws -> String { scalar("", SchemaScalar.string) }
    func decode(_ type: Double.Type) throws -> Double { scalar(0, SchemaScalar.number) }
    func decode(_ type: Float.Type) throws -> Float { scalar(0, SchemaScalar.number) }
    func decode(_ type: Int.Type) throws -> Int { scalar(0, SchemaScalar.integer) }
    func decode(_ type: Int8.Type) throws -> Int8 { scalar(0, SchemaScalar.integer) }
    func decode(_ type: Int16.Type) throws -> Int16 { scalar(0, SchemaScalar.integer) }
    func decode(_ type: Int32.Type) throws -> Int32 { scalar(0, SchemaScalar.integer) }
    func decode(_ type: Int64.Type) throws -> Int64 { scalar(0, SchemaScalar.integer) }
    func decode(_ type: UInt.Type) throws -> UInt { scalar(0, SchemaScalar.integer) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { scalar(0, SchemaScalar.integer) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { scalar(0, SchemaScalar.integer) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { scalar(0, SchemaScalar.integer) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { scalar(0, SchemaScalar.integer) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let probed = try SchemaProbe.probe(type, depth: depth + 1)
        sink.scalar(probed.schema)
        return probed.value
    }
}
