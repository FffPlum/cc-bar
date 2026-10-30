import XCTest
@testable import ccbar

final class CurrencyTests: XCTestCase {
    private let rates: [String: Decimal] = [
        "USD": 1,
        "CNY": Decimal(string: "6.68")!,
        "JPY": 158,
        "KRW": 1340,
        "HKD": Decimal(string: "7.85")!,
        "AUD": Decimal(string: "1.42")!,
        "SGD": Decimal(string: "1.28")!,
        "GBP": Decimal(string: "0.75")!,
    ]

    func testSupportedCurrencies() {
        XCTAssertEqual(
            DisplayCurrency.allCases.map(\.code),
            ["USD", "CNY", "JPY", "KRW", "HKD", "AUD", "SGD", "GBP"]
        )
    }

    func testConversionBetweenCurrenciesUsesCurrentUSDBasedRates() {
        XCTAssertEqual(
            CurrencyConverter.convert(10, from: "USD", to: "CNY", rates: rates),
            Decimal(string: "66.8")
        )
        XCTAssertEqual(
            CurrencyConverter.convert(66.8, from: "CNY", to: "USD", rates: rates),
            10
        )
        XCTAssertEqual(
            CurrencyConverter.convert(Decimal(string: "13.36")!, from: "CNY", to: "GBP", rates: rates),
            Decimal(string: "1.5")
        )
    }

    func testConversionDoesNotGuessMissingOrInvalidRates() {
        XCTAssertNil(CurrencyConverter.convert(10, from: "USD", to: "EUR", rates: rates))
        XCTAssertNil(CurrencyConverter.convert(10, from: "USD", to: "CNY", rates: ["USD": 1, "CNY": 0]))
        XCTAssertEqual(CurrencyConverter.convert(10, from: "CNY", to: "CNY", rates: [:]), 10)
    }

    func testExchangeRateResponseParsing() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try CurrencyClient.parse(Self.responseData, fetchedAt: fetchedAt)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        XCTAssertEqual(snapshot.sourceUpdatedAt, Date(timeIntervalSince1970: 1_793_232_151))
        XCTAssertEqual(snapshot.rates["USD"], 1)
        XCTAssertEqual(snapshot.rates["CNY"], Decimal(string: "6.680538"))
        XCTAssertEqual(snapshot.rates["KRW"], Decimal(string: "1340.24082"))
    }

    func testExchangeRateResponseRejectsMissingSupportedCurrency() {
        let data = Data(#"{"result":"success","time_last_update_unix":1793232151,"rates":{"USD":1}}"#.utf8)
        XCTAssertThrowsError(try CurrencyClient.parse(data, fetchedAt: Date()))
    }

    private static let responseData = Data(#"""
    {
      "result": "success",
      "time_last_update_unix": 1793232151,
      "rates": {
        "CNY": 6.680538,
        "JPY": 157.90537,
        "KRW": 1340.24082,
        "HKD": 7.845294,
        "AUD": 1.419838,
        "SGD": 1.28178,
        "GBP": 0.751538
      }
    }
    """#.utf8)
}
