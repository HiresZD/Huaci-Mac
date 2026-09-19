import Foundation

struct SelectionRead {
    var text: String?
    var secure: Bool = false
    var safetyUnverified: Bool = false
}

enum FocusedSelectionAttribute {
    case role, subrole, selectedText
}

// Keep the previously working focused-element path independent of hit-testing
// and expanded-tree validation. The source also enforces a time budget.
protocol FocusedSelectionSource {
    associatedtype Element
    var canRead: Bool { get }
    func focusedElement() -> Element?
    func textAttribute(_ attribute: FocusedSelectionAttribute, of element: Element) -> String?
    func parent(of element: Element) -> Element?
    func sameElement(_ lhs: Element, _ rhs: Element) -> Bool
}

enum FocusedSelectionReader {
    static func read<Source: FocusedSelectionSource>(
        from source: Source, expandedRead: () -> SelectionRead
    ) -> SelectionRead {
        let result = readFocused(from: source)
        // An optional expansion must never veto a valid standard selection or
        // bypass a password field detected by the primary path.
        if result.text != nil || result.secure { return result }
        return expandedRead()
    }

    private static func readFocused<Source: FocusedSelectionSource>(from source: Source) -> SelectionRead {
        guard source.canRead else { return SelectionRead() }
        var current = source.focusedElement()
        var visited: [Source.Element] = []
        for _ in 0..<5 {
            guard source.canRead, let item = current,
                  !visited.contains(where: { source.sameElement($0, item) }) else { break }
            visited.append(item)
            let role = source.textAttribute(.role, of: item)
            let subrole = source.textAttribute(.subrole, of: item)
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
                return SelectionRead(secure: true)
            }
            // Match the original reader: optional role/subrole availability is
            // not a prerequisite for querying the app's explicit selected text.
            guard source.canRead else { break }
            if let text = source.textAttribute(.selectedText, of: item),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               text.utf16.count <= SelectionTextRange.maximumSelectionUTF16Length {
                return SelectionRead(text: text)
            }
            current = source.parent(of: item)
        }
        return SelectionRead()
    }
}
