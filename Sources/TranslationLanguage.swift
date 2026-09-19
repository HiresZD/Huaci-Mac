import Foundation

enum TranslationLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"

    var title: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        case .portuguese: return "葡萄牙语"
        case .russian: return "俄语"
        case .arabic: return "阿拉伯语"
        }
    }

    /// The API receives the language name rather than an ambiguous UI abbreviation.
    var instructionName: String { title }

    var actionTitle: String { "翻译" }
}
