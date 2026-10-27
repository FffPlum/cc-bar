import XCTest
@testable import CCBar

final class MoonshotBalanceTests: XCTestCase {
    func testRegionalEndpointsAndCurrenciesStayBound() {
        let china = MoonshotAccount(id: "cn", name: "国内", region: .china)
        let global = MoonshotAccount(id: "global", name: "海外", region: .global)
        XCTAssertEqual(china.balanceURL.absoluteString, "https://api.moonshot.cn/v1/users/me/balance")
        XCTAssertEqual(global.balanceURL.absoluteString, "https://api.moonshot.ai/v1/users/me/balance")
        XCTAssertEqual(china.currencyCode, "CNY")
        XCTAssertEqual(global.currencyCode, "USD")
    }

    func testParsesDecimalBalancesWithoutLosingPrecision() throws {
        let balance = try MoonshotBalanceClient.parse(data: payload(
            available: "49.58894000000000001",
            cash: "3.00001000000000001",
            voucher: "46.58893"
        ), region: .china)
        XCTAssertEqual(balance.available, Decimal(string: "49.58894000000000001"))
        XCTAssertEqual(balance.cash, Decimal(string: "3.00001000000000001"))
        XCTAssertEqual(balance.voucher, Decimal(string: "46.58893"))
        XCTAssertEqual(balance.currencyCode, "CNY")
    }

    func testAcceptsNegativeCashAndUsesRegionalCurrency() throws {
        let balance = try MoonshotBalanceClient.parse(data: payload(
            available: "2.5",
            cash: "-3.75",
            voucher: "6.25"
        ), region: .global)
        XCTAssertEqual(balance.cash, Decimal(string: "-3.75"))
        XCTAssertEqual(balance.currencyCode, "USD")
    }

    func testRejectsBusinessFailures() {
        XCTAssertThrowsError(try MoonshotBalanceClient.parse(data: payload(code: 1, status: true), region: .china))
        XCTAssertThrowsError(try MoonshotBalanceClient.parse(data: payload(code: 0, status: false), region: .global))
    }

    func testRejectsMissingFieldsAndNegativeVoucher() throws {
        let missing = Data(#"{"code":0,"status":true,"data":{"available_balance":1,"cash_balance":1}}"#.utf8)
        XCTAssertThrowsError(try MoonshotBalanceClient.parse(data: missing, region: .china))
        XCTAssertThrowsError(try MoonshotBalanceClient.parse(data: payload(
            available: "1",
            cash: "2",
            voucher: "-0.01"
        ), region: .china))
    }

    func testFormattingDoesNotRoundTinyNonzeroBalanceToZero() {
        let tiny = Decimal(string: "0.000001")!
        XCTAssertEqual(MoonshotBalanceFormatter.amount(tiny, currencyCode: "USD"), "$0.000001")
        XCTAssertEqual(MoonshotBalanceFormatter.amount(tiny, currencyCode: "CNY"), "¥0.000001")
    }

    private func payload(
        code: Int = 0,
        status: Bool = true,
        available: String = "1",
        cash: String = "1",
        voucher: String = "0"
    ) -> Data {
        Data("""
        {"code":\(code),"status":\(status),"data":{"available_balance":\(available),"cash_balance":\(cash),"voucher_balance":\(voucher)}}
        """.utf8)
    }
}
