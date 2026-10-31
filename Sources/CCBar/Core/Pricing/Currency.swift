import Foundation
import Observation

nonisolated enum DisplayCurrency: String, CaseIterable, Identifiable, Codable, Sendable {
    case usd = "USD"
    case cny = "CNY"
    case jpy = "JPY"
    case krw = "KRW"
    case hkd = "HKD"
    case aud = "AUD"
    case sgd = "SGD"
    case gbp = "GBP"

    var id: String { rawValue }
    var code: String { rawValue }

    var symbol: String {
        switch self {
        case .usd: "$"
        case .cny, .jpy: "¥"
        case .krw: "₩"
        case .hkd: "HK$"
        case .aud: "A$"
        case .sgd: "S$"
        case .gbp: "£"
        }
    }

    var defaultFractionDigits: Int {
        switch self {
        case .jpy, .krw: 0
        default: 2
        }
    }

    @MainActor
    var displayName: String {
        switch self {
        case .usd: tr("US Dollar", "美元")
        case .cny: tr("Chinese Yuan", "人民币")
        case .jpy: tr("Japanese Yen", "日元")
        case .krw: tr("South Korean Won", "韩元")
        case .hkd: tr("Hong Kong Dollar", "港币")
        case .aud: tr("Australian Dollar", "澳元")
        case .sgd: tr("Singapore Dollar", "新加坡元")
        case .gbp: tr("British Pound", "英镑")
        }
    }
}

nonisolated struct ExchangeRateSnapshot: Sendable, Codable {
    var version = 1
    var fetchedAt: Date
    var sourceUpdatedAt: Date?
    var rates: [String: Decimal]
}

nonisolated enum CurrencyConverter {
    static func convert(
        _ value: Decimal,
        from sourceCode: String,
        to targetCode: String,
        rates: [String: Decimal]
    ) -> Decimal? {
        if sourceCode == targetCode { return value }
        guard let sourceRate = rates[sourceCode], let targetRate = rates[targetCode],
              sourceRate > 0, targetRate > 0
        else { return nil }
        return value / sourceRate * targetRate
    }
}

@Observable
@MainActor
final class CurrencyStore {
    static let shared = CurrencyStore()

    private(set) var snapshot: ExchangeRateSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastRefreshFailedAt: Date?
    private var lastAttemptAt: Date?

    private let automaticRefreshInterval: TimeInterval = 6 * 3600
    private let failureRetryInterval: TimeInterval = 15 * 60

    private init() {
        snapshot = AppRuntime.isRunningUnitTests ? nil : ExchangeRateCache.load()
    }

    var selectedCurrency: DisplayCurrency { SettingsStore.shared.displayCurrency }

    func rate(for currency: DisplayCurrency) -> Decimal? {
        if currency == .usd { return 1 }
        guard let rate = snapshot?.rates[currency.code], rate > 0 else { return nil }
        return rate
    }

    func convert(_ value: Decimal, from sourceCode: String = "USD", to target: DisplayCurrency? = nil) -> Decimal? {
        let target = target ?? selectedCurrency
        if sourceCode == target.code { return value }
        guard let snapshot else { return nil }
        var rates = snapshot.rates
        rates["USD"] = 1
        return CurrencyConverter.convert(value, from: sourceCode, to: target.code, rates: rates)
    }

    func refreshIfNeeded() {
        guard !AppRuntime.isRunningUnitTests, !isRefreshing else { return }
        let now = Date()
        if lastRefreshFailedAt != nil {
            if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < failureRetryInterval {
                return
            }
        } else if let fetchedAt = snapshot?.fetchedAt,
                  now.timeIntervalSince(fetchedAt) < automaticRefreshInterval {
            return
        }
        Task { await refresh() }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !AppRuntime.isRunningUnitTests, !isRefreshing else { return false }
        isRefreshing = true
        lastAttemptAt = Date()
        defer { isRefreshing = false }
        do {
            let snapshot = try await CurrencyClient.fetchLatest()
            self.snapshot = snapshot
            lastRefreshFailedAt = nil
            do {
                try ExchangeRateCache.save(snapshot)
            } catch {
                AppLog.error(.pricing, "exchange rate cache save failed: \(Redact.error(error))")
            }
            return true
        } catch {
            lastRefreshFailedAt = Date()
            AppLog.warn(.pricing, "exchange rate refresh failed, kept old cache: \(Redact.error(error))")
            return false
        }
    }
}

@MainActor
enum CurrencyFormatter {
    static func amount(
        _ value: Decimal,
        from sourceCode: String = "USD",
        minimumFractionDigits: Int = 0,
        maximumFractionDigits: Int? = nil
    ) -> String {
        let selected = SettingsStore.shared.displayCurrency
        if let converted = CurrencyStore.shared.convert(value, from: sourceCode, to: selected) {
            return format(
                converted,
                currency: selected,
                minimumFractionDigits: minimumFractionDigits,
                maximumFractionDigits: maximumFractionDigits ?? selected.defaultFractionDigits
            )
        }
        let fallback = DisplayCurrency(rawValue: sourceCode) ?? .usd
        return format(
            value,
            currency: fallback,
            minimumFractionDigits: minimumFractionDigits,
            maximumFractionDigits: maximumFractionDigits ?? fallback.defaultFractionDigits
        )
    }

    static func whole(_ value: Decimal) -> String {
        amount(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
    }

    static func compactWhole(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let selected = SettingsStore.shared.displayCurrency
        guard let converted = CurrencyStore.shared.convert(value) else { return whole(value) }
        let displayValue = converted < 1 && converted > 0 ? 1 : converted
        let formatted = format(
            displayValue,
            currency: selected,
            minimumFractionDigits: 0,
            maximumFractionDigits: 0
        )
        return converted > 0 && converted < 1 ? "<\(formatted)" : formatted
    }

    static func balance(_ value: Decimal, from sourceCode: String, maximumFractionDigits: Int = 2) -> String {
        let selected = SettingsStore.shared.displayCurrency
        guard let converted = CurrencyStore.shared.convert(value, from: sourceCode, to: selected) else {
            return MoonshotBalanceFormatter.amount(value, currencyCode: sourceCode, maximumFractionDigits: maximumFractionDigits)
        }
        let absolute = converted < 0 ? -converted : converted
        let digits = absolute > 0 && absolute < Decimal(string: "0.01")!
            ? max(maximumFractionDigits, 8) : maximumFractionDigits
        if absolute > 0 && absolute < Decimal(string: "0.00000001")! {
            return "\(converted < 0 ? "−" : "")<\(selected.symbol)0.00000001"
        }
        return amount(converted, from: selected.code, minimumFractionDigits: 0, maximumFractionDigits: digits)
    }

    static func precise(_ value: Decimal) -> String {
        amount(value, minimumFractionDigits: 4, maximumFractionDigits: 6)
    }

    static func axis(_ value: Decimal) -> String {
        let converted = CurrencyStore.shared.convert(value) ?? value
        let magnitude = abs(NSDecimalNumber(decimal: converted).doubleValue)
        if magnitude >= 10 {
            return amount(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
        }
        if magnitude >= 1 {
            return amount(value, minimumFractionDigits: 2, maximumFractionDigits: 2)
        }
        return amount(value, minimumFractionDigits: 2, maximumFractionDigits: 3)
    }

    static func pricePerMillion(_ value: Decimal) -> String {
        amount(value, minimumFractionDigits: 0, maximumFractionDigits: 4)
    }

    private static func format(
        _ value: Decimal,
        currency: DisplayCurrency,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        let number = NSDecimalNumber(decimal: value)
        let formatted = formatter.string(from: number) ?? number.stringValue
        return value < 0 ? "-\(currency.symbol)\(formatted.dropFirst())" : "\(currency.symbol)\(formatted)"
    }
}

nonisolated enum CurrencyClient {
    private struct Response: Decodable {
        let result: String
        let timeLastUpdateUnix: TimeInterval
        let rates: [String: Decimal]

        private enum CodingKeys: String, CodingKey {
            case result
            case timeLastUpdateUnix = "time_last_update_unix"
            case rates
        }
    }

    static func fetchLatest() async throws -> ExchangeRateSnapshot {
        var request = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await NetworkProxy.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try parse(data, fetchedAt: Date())
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> ExchangeRateSnapshot {
        let payload = try JSONDecoder().decode(Response.self, from: data)
        guard payload.result == "success" else { throw URLError(.cannotParseResponse) }
        var rates = payload.rates
        rates["USD"] = 1
        guard DisplayCurrency.allCases.allSatisfy({ rates[$0.code].map { $0 > 0 } == true }) else {
            throw URLError(.cannotParseResponse)
        }
        return ExchangeRateSnapshot(
            fetchedAt: fetchedAt,
            sourceUpdatedAt: Date(timeIntervalSince1970: payload.timeLastUpdateUnix),
            rates: rates
        )
    }
}

nonisolated enum ExchangeRateCache {
    static func load() -> ExchangeRateSnapshot? {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ExchangeRateSnapshot.self, from: data),
              snapshot.version == 1
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: ExchangeRateSnapshot) throws {
        let url = fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL {
        PricingCatalogCache.cacheFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("exchange-rates.json")
    }
}
