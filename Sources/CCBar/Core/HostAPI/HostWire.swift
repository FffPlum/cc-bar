import Foundation

/// JSON values shared by all host adapters. Numbers are kept as Decimal to avoid
/// changing the wire value when requests pass through the native host.
enum HostJSON: Codable, Equatable {
    case null, bool(Bool), number(Decimal), string(String)
    case array([HostJSON]), object([String: HostJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Decimal.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([HostJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: HostJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }
}

struct HostRequest: Codable {
    let version: Int
    let id: String
    let method: String
    let params: [String: HostJSON]
}

struct HostError: Error, Codable, Equatable {
    let code: String
    let message: String
}

struct HostResponse: Codable {
    let version: Int
    let id: String
    let result: HostJSON?
    let error: HostError?

    init(id: String, result: HostJSON) {
        self.version = 1; self.id = id; self.result = result; self.error = nil
    }

    init(id: String, error: HostError) {
        self.version = 1; self.id = id; self.result = nil; self.error = error
    }
}

struct HostEvent: Codable {
    let version = 1
    let event = "state.changed"
    let revision: String
    let domains: [String]
}
