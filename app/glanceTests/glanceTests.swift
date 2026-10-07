//
//  glanceTests.swift
//  glanceTests
//
//  Created by mingfu on 2026/7/7.
//

import Testing
@testable import Glance

struct glanceTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

    @Test func pipQuotesStripPricesFromNames() {
        let items = [
            MenuItem(title: "快捷操作", children: [
                MenuItem(title: "复制", action: "copy", value: "x"),
            ]),
            MenuItem(title: "BTC/USDT  100", action: "select", value: "BTCUSDT", statusTitle: "100"),
            MenuItem(title: "外汇汇率", children: [
                MenuItem(title: "港币 HKD  卖7.1 买7.0", action: "select", value: "fx:HKD", statusTitle: "7.1/7.0"),
            ]),
        ]
        let quotes = PiPQuote.quotes(from: items)
        #expect(quotes.map(\.id) == ["BTCUSDT", "fx:HKD"])
        #expect(quotes[0].name == "BTC/USDT")
        #expect(quotes[0].valueText == "100")
        #expect(quotes[1].name == "港币 HKD")
        #expect(quotes[1].valueText == "7.1/7.0")
    }

}
