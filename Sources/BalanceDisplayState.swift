import Foundation

/// A balance belongs to one saved API configuration. Replacing that
/// configuration or editing its draft invalidates both the value and callbacks.
struct BalanceDisplayState {
    private(set) var provider: BalanceProvider = .unconfigured
    private(set) var requiresSave = false
    private(set) var snapshot: BalanceSnapshot?
    private(set) var errorMessage: String?
    private(set) var activeRequestID: UUID?

    var isLoading: Bool { activeRequestID != nil }

    mutating func reset(provider: BalanceProvider, requiresSave: Bool = false) {
        self.provider = provider
        self.requiresSave = requiresSave
        snapshot = nil
        errorMessage = nil
        activeRequestID = nil
    }

    mutating func begin() -> UUID? {
        guard provider.supportsQuery, !requiresSave, !isLoading else { return nil }
        let token = UUID()
        activeRequestID = token
        errorMessage = nil
        return token
    }

    mutating func complete(snapshot: BalanceSnapshot, for token: UUID) {
        guard activeRequestID == token else { return }
        self.snapshot = snapshot
        errorMessage = nil
        activeRequestID = nil
    }

    mutating func fail(message: String, for token: UUID) {
        guard activeRequestID == token else { return }
        errorMessage = message
        activeRequestID = nil
        // Keep the last successful value, with its original timestamp, so a
        // failed refresh can never turn an unknown balance into a false zero.
    }

    mutating func cancel() { activeRequestID = nil }
}
