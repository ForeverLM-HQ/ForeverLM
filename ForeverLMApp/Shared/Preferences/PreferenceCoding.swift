import Foundation

/// The property-list shape a preference is stored in. The Mac's sync rail
/// carries the stored object as it is (`PreferenceStore.encodePlist`), so the
/// shape is part of a key's contract: a `Bool` is stored as a `Bool`.
enum PreferencePlistKind: String, Sendable {
    case bool, int, double, float, string, strings, data, date
    /// A property-list dictionary (`[String: Any]`).
    case dictionary
    /// A property-list array of mixed members (`[Any]`).
    case array
    /// No reader names a type: the stored object as it is.
    case any
}

/// What a value becomes when it is written.
enum PreferenceStoredValue {
    /// The property-list object to store.
    case value(Any)
    /// The key is cleared: an optional key set to nil.
    case absent
    /// The value has no stored form (a JSON encoding that failed). Nothing is
    /// written, and the writer reports it.
    case unencodable(Error)
}

/// How one key's value goes to and from its stored property-list object.
///
/// `decode` answers nil when nothing is stored or when what is stored has
/// another type, and the reader then takes the key's default: what every
/// `as? T ?? fallback` reader did before the keys were typed. Numbers read
/// through `NSNumber`, as `SyncedStorage` and `AppStorage` read them, so a
/// value stored as an `Int` reads as a `Double` and the reverse.
struct PreferenceCoding<Value>: @unchecked Sendable {
    let kind: PreferencePlistKind
    let decode: (Any?) -> Value?
    let encode: (Value) -> PreferenceStoredValue

    init(kind: PreferencePlistKind, decode: @escaping (Any?) -> Value?, encode: @escaping (Value) -> PreferenceStoredValue) {
        self.kind = kind
        self.decode = decode
        self.encode = encode
    }
}

extension PreferenceCoding where Value == Bool {
    static var bool: PreferenceCoding<Bool> {
        PreferenceCoding(kind: .bool, decode: { ($0 as? NSNumber)?.boolValue }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == Int {
    static var int: PreferenceCoding<Int> {
        PreferenceCoding(kind: .int, decode: { ($0 as? NSNumber)?.intValue }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == Double {
    static var double: PreferenceCoding<Double> {
        PreferenceCoding(kind: .double, decode: { ($0 as? NSNumber)?.doubleValue }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == Float {
    static var float: PreferenceCoding<Float> {
        PreferenceCoding(kind: .float, decode: { ($0 as? NSNumber)?.floatValue }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == String {
    static var string: PreferenceCoding<String> {
        PreferenceCoding(kind: .string, decode: { $0 as? String }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == [String] {
    static var strings: PreferenceCoding<[String]> {
        PreferenceCoding(kind: .strings, decode: { $0 as? [String] }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == Data {
    static var data: PreferenceCoding<Data> {
        PreferenceCoding(kind: .data, decode: { $0 as? Data }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == Date {
    static var date: PreferenceCoding<Date> {
        PreferenceCoding(kind: .date, decode: { $0 as? Date }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == [String: Any] {
    static var dictionary: PreferenceCoding<[String: Any]> {
        PreferenceCoding(kind: .dictionary, decode: { $0 as? [String: Any] }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == [Any] {
    static var array: PreferenceCoding<[Any]> {
        PreferenceCoding(kind: .array, decode: { $0 as? [Any] }, encode: { .value($0) })
    }
}

extension PreferenceCoding where Value == Any {
    /// The stored object as it is, for a key no reader gives a type.
    static var any: PreferenceCoding<Any> {
        PreferenceCoding(kind: .any, decode: { $0 }, encode: { .value($0) })
    }
}

extension PreferenceCoding {
    /// A key that may be absent: nil reads as nil and writes as a removal.
    static func optional<Wrapped>(_ base: PreferenceCoding<Wrapped>) -> PreferenceCoding<Wrapped?> where Value == Wrapped? {
        PreferenceCoding<Wrapped?>(
            kind: base.kind,
            decode: { stored in base.decode(stored).map(Optional.some) },
            encode: { value in
                guard let value else { return .absent }
                return base.encode(value)
            }
        )
    }

    /// An enum (or any raw-representable value) stored as its raw string.
    static func raw(_ type: Value.Type = Value.self) -> PreferenceCoding<Value>
    where Value: RawRepresentable, Value.RawValue == String {
        PreferenceCoding(
            kind: .string,
            decode: { ($0 as? String).flatMap(Value.init(rawValue:)) },
            encode: { .value($0.rawValue) }
        )
    }

    /// An enum (or any raw-representable value) stored as its raw whole number.
    static func raw(_ type: Value.Type = Value.self) -> PreferenceCoding<Value>
    where Value: RawRepresentable, Value.RawValue == Int {
        PreferenceCoding(
            kind: .int,
            decode: { ($0 as? NSNumber).flatMap { Value(rawValue: $0.intValue) } },
            encode: { .value($0.rawValue) }
        )
    }

    /// A `Codable` value stored as JSON `Data`, as `chatModels.openRouterCustom`
    /// is. The encoder and decoder are the caller's, so a key keeps the date and
    /// key strategies its reader already uses.
    static func json(
        _ type: Value.Type = Value.self,
        encoder: @escaping @autoclosure () -> JSONEncoder = JSONEncoder(),
        decoder: @escaping @autoclosure () -> JSONDecoder = JSONDecoder()
    ) -> PreferenceCoding<Value> where Value: Codable {
        PreferenceCoding(
            kind: .data,
            decode: { stored in
                guard let data = stored as? Data else { return nil }
                return try? decoder().decode(Value.self, from: data)
            },
            encode: { value in
                do {
                    return .value(try encoder().encode(value))
                } catch {
                    return .unencodable(error)
                }
            }
        )
    }
}

/// A value type with one obvious stored shape, so a key of that type needs no
/// coding spelled out.
protocol PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Self> { get }
}

extension Bool: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Bool> { .bool }
}

extension Int: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Int> { .int }
}

extension Double: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Double> { .double }
}

extension Float: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Float> { .float }
}

extension String: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<String> { .string }
}

extension Data: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Data> { .data }
}

extension Date: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Date> { .date }
}

extension Array: PreferenceValue where Element == String {
    static var preferenceCoding: PreferenceCoding<[String]> { .strings }
}

extension Optional: PreferenceValue where Wrapped: PreferenceValue {
    static var preferenceCoding: PreferenceCoding<Wrapped?> { .optional(Wrapped.preferenceCoding) }
}
