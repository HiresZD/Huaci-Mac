import Foundation

/// Billing belongs to the endpoint's provider, not to the selected model.
enum BalanceProvider: Equatable {
    case deepSeek
    case openAI
    case unsupported
    case unconfigured

    static func detect(baseURL: String) -> BalanceProvider {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return .unconfigured }
        guard !address.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              components.percentEncodedHost?.lowercased() == host,
              components.url != nil else { return .unsupported }
        switch host {
        case "api.deepseek.com": return .deepSeek
        case "api.openai.com": return .openAI
        default: return .unsupported
        }
    }

    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .openAI: return "OpenAI"
        case .unsupported: return "当前服务商"
        case .unconfigured: return "尚未配置"
        }
    }

    var supportsQuery: Bool { self == .deepSeek }

    var accountURL: URL? {
        switch self {
        case .deepSeek: return URL(string: "https://platform.deepseek.com/")
        case .openAI: return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case .unsupported, .unconfigured: return nil
        }
    }
}

struct BalanceAmount: Equatable {
    let currency: String
    let total: String
    let granted: String
    let toppedUp: String
}

struct BalanceSnapshot: Equatable {
    let isAvailable: Bool
    let balances: [BalanceAmount]
    let fetchedAt: Date
}

struct APIBalanceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct DeepSeekBalancePayload: Decodable {
    struct Amount: Decodable {
        let currency: String
        let total: String
        let granted: String
        let toppedUp: String

        enum CodingKeys: String, CodingKey {
            case currency
            case total = "total_balance"
            case granted = "granted_balance"
            case toppedUp = "topped_up_balance"
        }
    }

    let isAvailable: Bool
    let balances: [Amount]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balances = "balance_infos"
    }
}

/// Never allow a balance request to forward its bearer token through a redirect.
private final class BalanceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum APIBalance {
    private static let maximumPayloadBytes = 65_536

    static func makeRequest(configuration: APIConfiguration) throws -> URLRequest {
        // Revalidate even programmatically constructed configurations before using a key.
        // OpenAI ordinary API keys have no documented remaining-credit endpoint.
        guard BalanceProvider.detect(baseURL: configuration.endpoint.absoluteString) == .deepSeek else {
            throw APIBalanceError("当前服务商暂不支持在应用内查询余额。")
        }
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIBalanceError("请先填写 API Key。") }
        guard key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw APIBalanceError("API Key 格式无效，请检查粘贴内容。")
        }
        // This is an account endpoint; never append it to /v1/chat/completions.
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func parse(data: Data, fetchedAt: Date = Date()) throws -> BalanceSnapshot {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            throw APIBalanceError("余额接口返回的数据为空或过大，请稍后刷新。")
        }
        let payload: DeepSeekBalancePayload
        do { payload = try JSONDecoder().decode(DeepSeekBalancePayload.self, from: data) }
        catch { throw malformedResponse() }
        guard !payload.balances.isEmpty, payload.balances.count <= 16 else { throw malformedResponse() }
        var currencies = Set<String>()
        let balances = try payload.balances.map { amount -> BalanceAmount in
            guard ["CNY", "USD"].contains(amount.currency),
                  currencies.insert(amount.currency).inserted,
                  validAmount(amount.total), validAmount(amount.granted), validAmount(amount.toppedUp) else {
                throw malformedResponse()
            }
            // Preserve exact decimal strings and the provider's accounting. Do not round,
            // convert currencies, invent zero values, or recompute total from its parts.
            return BalanceAmount(currency: amount.currency, total: amount.total,
                                 granted: amount.granted, toppedUp: amount.toppedUp)
        }
        return BalanceSnapshot(isAvailable: payload.isAvailable, balances: balances, fetchedAt: fetchedAt)
    }

    static func fetch(configuration: APIConfiguration) async throws -> BalanceSnapshot {
        try Task.checkCancellation()
        let request = try makeRequest(configuration: configuration)
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.httpCookieAcceptPolicy = .never
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 15
        let session = URLSession(configuration: settings, delegate: BalanceRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler(operation: {
                let (bytes, response) = try await session.bytes(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw APIBalanceError("余额接口没有返回有效的 HTTP 响应。")
                }
                guard (200...299).contains(http.statusCode) else { throw httpError(http.statusCode) }
                guard response.expectedContentLength <= Int64(maximumPayloadBytes) else {
                    throw APIBalanceError("余额接口返回的数据过大，已停止接收。")
                }
                var data = Data()
                data.reserveCapacity(4_096)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maximumPayloadBytes else {
                        throw APIBalanceError("余额接口返回的数据过大，已停止接收。")
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return try parse(data: data)
            }, onCancel: { session.invalidateAndCancel() })
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? APIBalanceError { throw error }
            if let error = error as? URLError {
                if error.code == .cancelled { throw CancellationError() }
                if error.code == .timedOut { throw APIBalanceError("余额查询超时，请稍后刷新。") }
            }
            // Never expose an upstream response body or an underlying request description.
            throw APIBalanceError("暂时无法连接余额接口，请检查网络后刷新。")
        }
    }

    private static func validAmount(_ amount: String) -> Bool {
        guard !amount.isEmpty, amount.utf8.count <= 128 else { return false }
        return amount.range(of: #"\A-?[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil
    }

    private static func malformedResponse() -> APIBalanceError {
        APIBalanceError("余额接口返回了无法识别的数据，请稍后刷新。")
    }

    private static func httpError(_ status: Int) -> APIBalanceError {
        switch status {
        case 300...399: return APIBalanceError("余额接口要求跳转，已停止查询。请检查 API 地址。")
        case 401: return APIBalanceError("余额查询认证失败，请检查 API Key。")
        case 403: return APIBalanceError("当前 API Key 无权查询余额，请在账户后台查看。")
        case 404: return APIBalanceError("余额查询接口暂不可用，请在账户后台查看。")
        case 429: return APIBalanceError("余额查询过于频繁，请稍后刷新。")
        case 500...599: return APIBalanceError("余额服务暂时不可用，请稍后刷新。")
        default: return APIBalanceError("余额查询失败（HTTP \(status)），请稍后刷新。")
        }
    }
}
