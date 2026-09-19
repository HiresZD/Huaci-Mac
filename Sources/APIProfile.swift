import Foundation

enum APIPurpose: Equatable {
    case translation
    case chat
}

/// Public configuration only. API keys are stored separately in Keychain.
struct APIProfile: Codable, Equatable, Identifiable {
    static let legacyID = "default"

    var id: String
    var name: String
    var baseURL: String
    var model: String

    static func legacy(baseURL: String = "", model: String = "") -> APIProfile {
        APIProfile(id: legacyID, name: "默认配置", baseURL: baseURL, model: model)
    }

    static func isValidID(_ id: String) -> Bool {
        id == legacyID || UUID(uuidString: id)?.uuidString == id
    }
}
