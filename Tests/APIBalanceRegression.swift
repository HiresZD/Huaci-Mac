import Foundation

private struct BalanceTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct APIBalanceRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw BalanceTestFailure(description: message) }
    }

    static func expectThrows(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch is APIBalanceError { return }
        throw BalanceTestFailure(description: "Expected balance validation to reject: \(label)")
    }

    static func amount(currency: String = "CNY", total: Any = "12.340000000000000001",
                       granted: Any = "2.30", toppedUp: Any = "10.04") -> [String: Any] {
        ["currency": currency, "total_balance": total,
         "granted_balance": granted, "topped_up_balance": toppedUp]
    }

    static func payload(_ amounts: [[String: Any]], available: Any = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["is_available": available, "balance_infos": amounts])
    }

    static func main() throws {
        // Only public endpoint metadata and a placeholder key are used. No network is contacted.
        for address in ["https://api.deepseek.com", "https://api.deepseek.com/",
                        "https://api.deepseek.com/v1", "https://api.deepseek.com/v1/chat/completions",
                        "https://API.DEEPSEEK.COM:443/chat/completions", " https://api.deepseek.com \n"] {
            try expect(BalanceProvider.detect(baseURL: address) == .deepSeek,
                       "Official DeepSeek roots, v1 and completion URLs must select the same account provider")
            let configuration = APIConfiguration(endpoint: URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))!,
                                                 apiKey: "test-key", model: "arbitrary-model")
            let request = try APIBalance.makeRequest(configuration: configuration)
            try expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance",
                       "Balance always uses the exact provider account endpoint")
            try expect(request.httpMethod == "GET" && request.httpBody == nil,
                       "Balance must not submit a chat request or model prompt")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key",
                       "The key belongs only in the bearer header")
            try expect(request.value(forHTTPHeaderField: "Accept") == "application/json",
                       "The balance endpoint returns JSON")
            try expect(request.timeoutInterval == 15 && request.cachePolicy == .reloadIgnoringLocalCacheData,
                       "A balance refresh must have a bounded wait and bypass cached data")
        }

        let openAI = BalanceProvider.detect(baseURL: "https://api.openai.com/v1/chat/completions")
        try expect(openAI == .openAI && !openAI.supportsQuery,
                   "OpenAI must be recognized without claiming an ordinary-key balance API")
        try expect(openAI.accountURL?.absoluteString == "https://platform.openai.com/settings/organization/billing/overview",
                   "OpenAI must offer its own billing page")
        try expect(BalanceProvider.deepSeek.supportsQuery && BalanceProvider.deepSeek.accountURL?.host == "platform.deepseek.com",
                   "DeepSeek supports the documented balance query and its own account page")
        try expect(BalanceProvider.detect(baseURL: " \n ") == .unconfigured,
                   "A missing URL is distinguishable from an unsupported provider")
        try expect(BalanceProvider.unsupported.accountURL == nil && BalanceProvider.unconfigured.accountURL == nil,
                   "Unknown providers must not get an invented billing URL")

        let unsupported = [
            "http://api.deepseek.com", "http://api.openai.com", "https://api.deepseek.com:8443",
            "https://api.openai.com:444", "https://api.deepseek.com.example.org",
            "https://api.openai.com.example.org", "https://evil.example/api.deepseek.com",
            "https://api.deepseek.com@evil.example", "https://someone@api.deepseek.com",
            "https://api.openai.com:secret@evil.example", "https://api.deepseek.com?key=unexpected",
            "https://api.deepseek.com?", "https://api.openai.com#billing", "https://api.openai.com#",
            "https://api.deepseek.com.", "https://%61pi.deepseek.com", "https://api.deеpseek.com",
            "https://relay.example/v1", "http://localhost:8080/v1", "api.deepseek.com", "not a URL"
        ]
        for address in unsupported {
            try expect(BalanceProvider.detect(baseURL: address) == .unsupported,
                       "Unsafe, spoofed or unsupported provider address accepted: \(address)")
            if let endpoint = URL(string: address) {
                try expectThrows(address) {
                    _ = try APIBalance.makeRequest(configuration: APIConfiguration(
                        endpoint: endpoint, apiKey: "test-key", model: "deepseek-flash"))
                }
            }
        }
        // A model name is never used to reroute a provider's key.
        for address in ["https://api.openai.com/v1", "https://relay.example/v1"] {
            try expectThrows("unsupported provider with a DeepSeek model") {
                _ = try APIBalance.makeRequest(configuration: APIConfiguration(
                    endpoint: URL(string: address)!, apiKey: "test-key", model: "deepseek-flash"))
            }
        }
        for key in ["", " \n ", "test\nkey", "test\rkey", "test\u{0000}key", String(repeating: "x", count: 8_193)] {
            try expectThrows("invalid credential") {
                _ = try APIBalance.makeRequest(configuration: APIConfiguration(
                    endpoint: URL(string: "https://api.deepseek.com")!, apiKey: key, model: ""))
            }
        }

        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try payload([amount(), amount(currency: "USD", total: "0.000000000000000123",
                                                 granted: "0", toppedUp: "0.000000000000000123")])
        let snapshot = try APIBalance.parse(data: data, fetchedAt: fetchedAt)
        try expect(snapshot.isAvailable && snapshot.fetchedAt == fetchedAt && snapshot.balances.count == 2,
                   "Availability, refresh time and separate currencies must survive parsing")
        try expect(snapshot.balances[0] == BalanceAmount(currency: "CNY", total: "12.340000000000000001",
                                                        granted: "2.30", toppedUp: "10.04"),
                   "Monetary precision and the provider total must remain exactly as returned")
        try expect(snapshot.balances[1].currency == "USD" && snapshot.balances[1].total == "0.000000000000000123",
                   "USD must neither be rounded nor converted or merged into CNY")
        let zero = try APIBalance.parse(data: payload([amount(total: "0.00", granted: "0", toppedUp: "0")], available: false))
        try expect(!zero.isAvailable && zero.balances[0].total == "0.00",
                   "A successful zero-balance response is distinct from unavailable or invalid data")
        let negative = try APIBalance.parse(data: payload([amount(total: "-0.000001", granted: "0", toppedUp: "-0.000001")], available: false))
        try expect(negative.balances[0].total == "-0.000001", "Overdraft values must not be clamped to zero")

        let invalidAmounts: [Any] = ["", " ", " 1.23", "1.23 ", "1\n", "1\r2", "NaN", "Infinity", "1e6",
                                     "+1", "1,234", ".5", "1.", "1 CNY", "<b>2</b>", "١٢", 12.5, 0, true, NSNull(),
                                     String(repeating: "9", count: 129)]
        for value in invalidAmounts {
            for field in ["total_balance", "granted_balance", "topped_up_balance"] {
                var invalid = amount()
                invalid[field] = value
                try expectThrows("invalid decimal \(field)") {
                    _ = try APIBalance.parse(data: payload([invalid]))
                }
            }
        }
        for field in ["currency", "total_balance", "granted_balance", "topped_up_balance"] {
            var missing = amount()
            missing.removeValue(forKey: field)
            try expectThrows("missing \(field)") { _ = try APIBalance.parse(data: payload([missing])) }
        }
        for currency in ["", "cny", "EUR", "USD\nCNY", " CNY"] {
            try expectThrows("unexpected currency") { _ = try APIBalance.parse(data: payload([amount(currency: currency)])) }
        }
        let invalidAvailability: [Any] = ["true", 1, 0, NSNull()]
        for available in invalidAvailability {
            try expectThrows("non-boolean availability") { _ = try APIBalance.parse(data: payload([amount()], available: available)) }
        }
        try expectThrows("duplicate currency") { _ = try APIBalance.parse(data: payload([amount(), amount()])) }
        try expectThrows("empty balances") { _ = try APIBalance.parse(data: payload([])) }
        try expectThrows("too many balances") {
            _ = try APIBalance.parse(data: payload(Array(repeating: amount(), count: 17)))
        }
        for raw in ["", "[]", "{}", "null", "<html>Unauthorized</html>",
                    #"{"is_available":true}"#,
                    #"{"balance_infos":[]}"#,
                    #"{"is_available":true,"balance_infos":{}}"#,
                    #"{"is_available":true,"balance_infos":null}"#] {
            try expectThrows("invalid root or structure") { _ = try APIBalance.parse(data: Data(raw.utf8)) }
        }
        try expectThrows("oversized response") {
            _ = try APIBalance.parse(data: Data(repeating: 32, count: 65_537))
        }
        print("API balance request and parsing checks passed (no network used).")
    }
}
