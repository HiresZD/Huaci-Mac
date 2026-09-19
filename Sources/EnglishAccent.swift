import Foundation

enum EnglishAccent: String, CaseIterable, Codable {
    case american = "en-US"
    case british = "en-GB"

    var title: String {
        switch self {
        case .american: return "美式英语"
        case .british: return "英式英语"
        }
    }
}
