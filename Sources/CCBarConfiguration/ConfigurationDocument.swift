import Foundation
import CoreFoundation
import TOMLKit
import Yams

/// All untyped parser output ends here; the adapters only work with value types.
indirect enum ConfigValue: Equatable, Sendable, Decodable {
    case object([String: ConfigValue]), array([ConfigValue]), string(String), number(Double), integerNumber(Int64), bool(Bool), null
    var object: [String: ConfigValue] { if case .object(let value) = self { value } else { [:] } }
    var array: [ConfigValue] { if case .array(let value) = self { value } else { [] } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? {
        if case .integerNumber(let value) = self { return Int(exactly: value) }
        guard case .number(let value) = self, value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
    subscript(_ key: String) -> ConfigValue {
        get { object[key] ?? .null }
        set { var values = object; values[key] = newValue == .null ? nil : newValue; self = .object(values) }
    }
    init(_ value: Any) throws {
        switch value {
        case let object as [String: Any]: self = .object(try object.mapValues(Self.init))
        case let array as [Any]: self = .array(try array.map(Self.init))
        case let string as String: self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if let integer = Int64(number.stringValue) { self = .integerNumber(integer) }
            else { self = .number(number.doubleValue) }
        case is NSNull: self = .null
        default: throw ConfigurationError.invalidFile
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: ConfigValue].self) { self = .object(object) }
        else if let array = try? value.decode([ConfigValue].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let integer = try? value.decode(Int64.self) { self = .integerNumber(integer) }
        else { self = .number(try value.decode(Double.self)) }
    }
    var foundation: Any {
        switch self {
        case .object(let value): value.mapValues(\.foundation)
        case .array(let value): value.map(\.foundation)
        case .string(let value): value
        case .number(let value): value
        case .integerNumber(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }
    var toml: any TOMLValueConvertible {
        switch self {
        case .object(let value): TOMLTable(value.mapValues(\.toml))
        case .array(let value): TOMLArray(value.map(\.toml))
        case .string(let value): value
        case .number(let value): value.rounded() == value && value >= Double(Int.min) && value < Double(Int.max) ? Int(value).tomlValue : value.tomlValue
        case .integerNumber(let value): Int(value)
        case .bool(let value): value
        case .null: "" // Removed by patch; TOML has no null.
        }
    }
}

struct ConfigurationDocument {
    enum Format { case json, jsonc, toml, yaml, environment }
    let text: String
    let format: Format
    var value: ConfigValue
    private let original: ConfigValue

    init(data: Data?, format: Format, emptyValue: ConfigValue = .object([:])) throws {
        self.format = format
        guard let text = String(data: data ?? Data(), encoding: .utf8) else { throw ConfigurationError.invalidFile }
        self.text = text
        do {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value = emptyValue
            } else {
                switch format {
                case .json: value = try ConfigValue(JSONSerialization.jsonObject(with: Data(text.utf8)))
                case .jsonc:
                    let decoder = JSONDecoder()
                    decoder.allowsJSON5 = true
                    value = try decoder.decode(ConfigValue.self, from: Data(text.utf8))
                case .toml:
                    let json = try TOMLTable(string: text).convert(to: .json)
                    value = try ConfigValue(JSONSerialization.jsonObject(with: Data(json.utf8)))
                case .yaml: value = try ConfigValue(Yams.load(yaml: text) ?? NSNull())
                case .environment: value = try Self.readEnvironment(text)
                }
            }
        } catch { throw ConfigurationError.invalidFile }
        original = value
    }

    func encoded() throws -> Data {
        guard original != value else { return Data(text.utf8) }
        try Self.validateContainers(before: original, after: value)
        let output: String
        switch format {
        case .json, .jsonc:
            return try JSONSerialization.data(withJSONObject: value.foundation, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case .yaml: output = try Yams.dump(object: value.foundation, sortKeys: true)
        case .toml:
            let table = try TOMLTable(string: text)
            Self.patch(table, before: original, after: value)
            output = table.convert(to: .toml)
        case .environment: output = try environmentText()
        }
        return Data((output.hasSuffix("\n") ? output : output + "\n").utf8)
    }

    // An unexpected scalar must never be silently replaced by a nested provider table.
    private static func validateContainers(before: ConfigValue, after: ConfigValue) throws {
        switch after {
        case .object(let values):
            guard before == .null || { if case .object = before { return true }; return false }() else {
                throw ConfigurationError.invalidFile
            }
            for (key, value) in values { try validateContainers(before: before[key], after: value) }
        case .array(let values):
            guard before == .null || { if case .array = before { return true }; return false }() else {
                throw ConfigurationError.invalidFile
            }
            for (old, new) in zip(before.array, values) { try validateContainers(before: old, after: new) }
        default: break
        }
    }

    private static func patch(_ table: TOMLTable, before: ConfigValue, after: ConfigValue) {
        for key in Set(before.object.keys).union(after.object.keys) where before[key] != after[key] {
            if after[key] == .null { table.remove(at: key) }
            else if case .object = after[key], let child = table[key]?.table {
                patch(child, before: before[key], after: after[key])
            } else { table[key] = after[key].toml }
        }
    }

    private static func readEnvironment(_ text: String) throws -> ConfigValue {
        var result: [String: ConfigValue] = [:]
        for line in text.components(separatedBy: .newlines) {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("#") else { continue }
            guard let index = cleaned.firstIndex(of: "=") else { continue }
            let key = cleaned[..<index].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            var value = String(cleaned[cleaned.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw ConfigurationError.invalidFile }
                value = decoded
            } else if value.hasPrefix("'") && value.hasSuffix("'") { value = String(value.dropFirst().dropLast()) }
            else { value = value.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces) }
            result[key] = .string(value)
        }
        return .object(result)
    }

    private func environmentText() throws -> String {
        let changed = Set(original.object.keys).union(value.object.keys).filter { original[$0] != value[$0] }
        var lines = text.components(separatedBy: .newlines).filter { line in
            guard let index = line.firstIndex(of: "=") else { return true }
            let key = line[..<index].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            return !changed.contains(key)
        }
        for key in changed.sorted() {
            if let string = value[key].string {
                let encoded = try JSONEncoder().encode(string)
                lines.append(key + "=" + String(decoding: encoded, as: UTF8.self))
            }
        }
        return lines.joined(separator: "\n")
    }
}
