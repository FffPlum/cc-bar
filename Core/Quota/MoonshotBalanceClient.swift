import Foundation

nonisolated struct MoonshotBalance: Codable, Equatable, Sendable {
    var available: Decimal
    var cash: Decimal
    var voucher: Decimal
    var currencyCode: String
    var fetchedAt: Date
    var keyFingerprint: String? = nil
}

nonisolated enum MoonshotBalanceClient {
    private struct Response: Decodable {
        struct DataPayload: Decodable {
            let availableBalance: Decimal
            let cashBalance: Decimal
            let voucherBalance: Decimal

            private enum CodingKeys: String, CodingKey {
                case availableBalance = "available_balance"
                case cashBalance = "cash_balance"
                case voucherBalance = "voucher_balance"
            }
        }
        let code: Int
        let status: Bool
        let data: DataPayload
    }

    static func fetch(account: MoonshotAccount, apiKey: String, session: URLSession? = nil) async -> Result<MoonshotBalance, QuotaError> {
        var request = URLRequest(url: account.balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await NetworkProxy.data(for: request, session: session)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http response")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode, String(data: data, encoding: .utf8) ?? "balance request failed"))
            }
            return .success(try parse(data: data, region: account.region))
        } catch let error as QuotaError {
            return .failure(error)
        } catch {
            return .failure(.from(transport: error))
        }
    }

    static func parse(data: Data, region: KimiRegion, fetchedAt: Date = Date()) throws -> MoonshotBalance {
        guard let payload = try? JSONDecoder().decode(Response.self, from: data),
              payload.code == 0,
              payload.status,
              payload.data.voucherBalance >= 0
        else { throw QuotaError.decode("invalid Moonshot balance response") }
        return MoonshotBalance(
            available: payload.data.availableBalance,
            cash: payload.data.cashBalance,
            voucher: payload.data.voucherBalance,
            currencyCode: region == .china ? "CNY" : "USD",
            fetchedAt: fetchedAt
        )
    }
}

nonisolated enum MoonshotBalanceFormatter {
    static func amount(_ value: Decimal, currencyCode: String, maximumFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.currencyCode = currencyCode
        formatter.currencySymbol = currencyCode == "CNY" ? "¥" : "$"
        formatter.positivePrefix = formatter.currencySymbol
        formatter.negativePrefix = "-" + formatter.currencySymbol
        formatter.positiveSuffix = ""
        formatter.negativeSuffix = ""
        let absolute = value < 0 ? -value : value
        formatter.maximumFractionDigits = absolute > 0 && absolute < Decimal(string: "0.01")!
            ? max(maximumFractionDigits, 8) : maximumFractionDigits
        formatter.minimumFractionDigits = 0
        let formatted = formatter.string(from: NSDecimalNumber(decimal: value))
            ?? "\(currencyCode == "CNY" ? "¥" : "$")\(value)"
        if absolute > 0 && absolute < Decimal(string: "0.00000001")! {
            return "\(value < 0 ? "−" : "")<\(currencyCode == "CNY" ? "¥" : "$")0.00000001"
        }
        return formatted
    }
}

nonisolated enum MoonshotBalanceCache {
    private struct Payload: Codable {
        var version = 1
        var balances: [String: MoonshotBalance]
    }

    static func load(from url: URL = fileURL()) -> [String: MoonshotBalance] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1
        else { return [:] }
        return payload.balances
    }

    static func save(_ balances: [String: MoonshotBalance], to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Payload(balances: balances)).write(to: url, options: .atomic)
    }

    static func fileURL() -> URL {
        ImportedCodexStore.fileURL().deletingLastPathComponent().appendingPathComponent("moonshot_balance_cache.json")
    }
}
