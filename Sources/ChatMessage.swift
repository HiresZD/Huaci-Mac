import Foundation

/// Only visible conversation text is sent as history; API metadata is kept separately.
struct ChatMessage: Codable, Equatable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}
