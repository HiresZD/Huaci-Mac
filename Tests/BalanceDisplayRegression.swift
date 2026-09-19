import Foundation

private struct BalanceDisplayFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct BalanceDisplayRegression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw BalanceDisplayFailure(description: message) }
    }

    static func start(_ state: inout BalanceDisplayState) throws -> UUID {
        guard let token = state.begin() else { throw BalanceDisplayFailure(description: "Expected a balance request") }
        return token
    }

    static func main() throws {
        let amount = BalanceAmount(currency: "CNY", total: "12.3456", granted: "0.00", toppedUp: "12.3456")
        let first = BalanceSnapshot(isAvailable: true, balances: [amount], fetchedAt: Date(timeIntervalSince1970: 100))
        let zero = BalanceSnapshot(isAvailable: false,
            balances: [BalanceAmount(currency: "USD", total: "0.00", granted: "0.00", toppedUp: "0.00")],
            fetchedAt: Date(timeIntervalSince1970: 200))
        var state = BalanceDisplayState()
        try check(state.begin() == nil && state.snapshot == nil, "Unconfigured accounts must not start requests")

        state.reset(provider: .deepSeek)
        let originalToken = try start(&state)
        try check(state.begin() == nil, "Repeated clicks during one request must not queue more requests")
        state.complete(snapshot: first, for: originalToken)
        try check(state.snapshot == first && !state.isLoading, "Successful balance preserves currency and exact timestamp")

        let failedRefresh = try start(&state)
        state.fail(message: "网络不可用", for: failedRefresh)
        try check(state.snapshot == first && state.errorMessage == "网络不可用",
                  "A failed refresh must retain the old value and original update time")
        let successfulRefresh = try start(&state)
        state.complete(snapshot: zero, for: successfulRefresh)
        try check(state.snapshot == zero && state.errorMessage == nil,
                  "A real zero balance is distinct from failure and replaces the previous value")

        let previousAccount = try start(&state)
        state.reset(provider: .deepSeek, requiresSave: true)
        state.complete(snapshot: first, for: previousAccount)
        try check(state.snapshot == nil && state.begin() == nil,
                  "Editing a key clears the old account and rejects its in-flight response")
        state.reset(provider: .deepSeek)
        let replacementAccount = try start(&state)
        state.fail(message: "旧账户错误", for: previousAccount)
        try check(state.activeRequestID == replacementAccount && state.errorMessage == nil,
                  "Late failure from an old key must not stop the new account request")
        state.complete(snapshot: zero, for: replacementAccount)
        try check(state.snapshot == zero, "The new account result must survive independently")

        let closingRequest = try start(&state)
        state.cancel()
        state.complete(snapshot: first, for: closingRequest)
        try check(state.snapshot == zero && !state.isLoading, "Closing the settings window invalidates late responses")

        for provider: BalanceProvider in [.openAI, .unsupported, .unconfigured] {
            state.reset(provider: provider)
            try check(state.snapshot == nil && state.begin() == nil,
                      "Unsupported balance APIs must show no number and make no network request")
        }
        print("Balance account switching and refresh checks passed; no network or Keychain used.")
    }
}
