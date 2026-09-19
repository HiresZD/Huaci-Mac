import Foundation

private struct FocusedRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FakeFocusedSource: FocusedSelectionSource {
    struct Node {
        var role: String? = "AXTextArea"
        var subrole: String?
        var selectedText: String?
        var parent: Int?
    }

    var nodes: [Int: Node]
    var focused: Int?
    var remainingReads: Int
    private(set) var reads: [String] = []

    init(nodes: [Int: Node], focused: Int? = 0, remainingReads: Int = 100) {
        self.nodes = nodes
        self.focused = focused
        self.remainingReads = remainingReads
    }

    var canRead: Bool { remainingReads > 0 }

    private func consume(_ name: String) -> Bool {
        guard canRead else { return false }
        remainingReads -= 1
        reads.append(name)
        return true
    }

    func focusedElement() -> Int? {
        guard consume("focused") else { return nil }
        return focused
    }

    func textAttribute(_ attribute: FocusedSelectionAttribute, of element: Int) -> String? {
        switch attribute {
        case .role:
            guard consume("role:\(element)") else { return nil }
            return nodes[element]?.role
        case .subrole:
            guard consume("subrole:\(element)") else { return nil }
            return nodes[element]?.subrole
        case .selectedText:
            guard consume("selectedText:\(element)") else { return nil }
            return nodes[element]?.selectedText
        }
    }

    func parent(of element: Int) -> Int? {
        guard consume("parent:\(element)") else { return nil }
        return nodes[element]?.parent
    }

    func sameElement(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }
}

@main
struct FocusedSelectionRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw FocusedRegressionFailure(description: message) }
    }

    private static func read(_ source: FakeFocusedSource,
                             expansion: SelectionRead = SelectionRead(text: "expanded")) -> (SelectionRead, Int) {
        var expansionCalls = 0
        let result = FocusedSelectionReader.read(from: source) {
            expansionCalls += 1
            return expansion
        }
        return (result, expansionCalls)
    }

    static func main() throws {
        let focused = FakeFocusedSource(nodes: [0: .init(selectedText: "hello")])
        let (direct, badHitCalls) = read(focused, expansion: SelectionRead(safetyUnverified: true))
        try check(direct.text == "hello" && badHitCalls == 0,
                  "A valid focused selection must return before a failing hit-test/ancestor expansion")
        try check(!focused.reads.contains("parent:0"),
                  "A working focused selection must not require its full ancestor tree")

        let optional = FakeFocusedSource(nodes: [0: .init(role: nil, subrole: nil, selectedText: "word")])
        let (optionalResult, optionalExpansion) = read(optional)
        try check(optionalResult.text == "word" && optionalExpansion == 0,
                  "Missing optional role/subrole attributes must not suppress an explicit selected-text value")

        let parent = FakeFocusedSource(nodes: [
            0: .init(role: "AXStaticText", parent: 1),
            1: .init(role: "AXGroup", parent: 2),
            2: .init(selectedText: "selected in parent")
        ])
        let (parentResult, parentExpansion) = read(parent)
        try check(parentResult.text == "selected in parent" && parentExpansion == 0,
                  "Focused child controls must retain the original parent-selection fallback")

        for secureNode in [
            FakeFocusedSource.Node(role: "AXSecureTextField", selectedText: "password"),
            FakeFocusedSource.Node(role: "AXTextField", subrole: "AXSecureTextField", selectedText: "password")
        ] {
            let secureSource = FakeFocusedSource(nodes: [0: secureNode])
            let (secureResult, secureExpansion) = read(secureSource)
            try check(secureResult.secure && secureResult.text == nil && secureExpansion == 0,
                      "A secure role or subrole must block both primary text reads and expansion")
            try check(!secureSource.reads.contains("selectedText:0"),
                      "Password text must never be requested after a secure field is detected")
        }

        let secureParent = FakeFocusedSource(nodes: [
            0: .init(role: "AXGroup", parent: 1),
            1: .init(role: "AXTextField", subrole: "AXSecureTextField", selectedText: "password")
        ])
        let (secureParentResult, secureParentExpansion) = read(secureParent)
        try check(secureParentResult.secure && secureParentExpansion == 0 &&
                  !secureParent.reads.contains("selectedText:1"),
                  "A secure parent reached during selection fallback must stop before its text is requested")

        let emptySelections: [String?] = [nil, "", " \n\t "]
        for emptySelection in emptySelections {
            let noSelection = FakeFocusedSource(nodes: [0: .init(selectedText: emptySelection)])
            let (expanded, expansionCalls) = read(noSelection)
            try check(expanded.text == "expanded" && expansionCalls == 1,
                      "A missing or whitespace-only selection must allow exactly one expansion")
        }
        let (noFocusResult, noFocusExpansion) = read(FakeFocusedSource(nodes: [:], focused: nil))
        try check(noFocusResult.text == "expanded" && noFocusExpansion == 1,
                  "An app without a focused accessibility element must still allow the optional expansion")

        let cyclic = FakeFocusedSource(nodes: [0: .init(parent: 1), 1: .init(parent: 0)])
        let (_, cycleExpansion) = read(cyclic)
        try check(cyclic.reads.filter { $0 == "role:0" }.count == 1 &&
                  cyclic.reads.filter { $0 == "role:1" }.count == 1 && cycleExpansion == 1,
                  "A cyclic accessibility parent chain must visit each element once and then stop")

        var deepNodes: [Int: FakeFocusedSource.Node] = [:]
        for index in 0..<6 {
            deepNodes[index] = .init(selectedText: index == 5 ? "too deep" : nil,
                                     parent: index < 5 ? index + 1 : nil)
        }
        let tooDeep = FakeFocusedSource(nodes: deepNodes)
        let (deepResult, deepExpansion) = read(tooDeep)
        try check(deepResult.text == "expanded" && deepExpansion == 1 &&
                  !tooDeep.reads.contains("role:5") && !tooDeep.reads.contains("selectedText:5"),
                  "The standard path must stop after five elements rather than traverse the whole app")
        deepNodes[4]?.selectedText = "fifth element"
        let (lastAllowed, lastExpansion) = read(FakeFocusedSource(nodes: deepNodes))
        try check(lastAllowed.text == "fifth element" && lastExpansion == 0,
                  "The fifth element remains eligible for the original focused-selection fallback")

        let exhausted = FakeFocusedSource(nodes: [0: .init(selectedText: "unread")], remainingReads: 0)
        let (_, exhaustedExpansion) = read(exhausted)
        try check(exhausted.reads.isEmpty && exhaustedExpansion == 1,
                  "An exhausted primary budget must do no reads and leave the independent expansion available")
        let expires = FakeFocusedSource(nodes: [0: .init(selectedText: "unread", parent: 0)], remainingReads: 2)
        let (_, expiresExpansion) = read(expires)
        try check(expires.reads == ["focused", "role:0"] && expiresExpansion == 1,
                  "Budget expiry during attribute reads must stop before selected text or another parent iteration")

        let boundary = String(repeating: "😀", count: 10_000)
        let (boundaryResult, boundaryExpansion) = read(FakeFocusedSource(nodes: [0: .init(selectedText: boundary)]))
        try check(boundaryResult.text == boundary && boundaryExpansion == 0,
                  "A selection at the 20,000 UTF-16-unit limit must remain readable")
        for tooLong in [String(repeating: "a", count: 20_001), boundary + "😀"] {
            let (oversized, oversizedExpansion) = read(FakeFocusedSource(nodes: [0: .init(selectedText: tooLong)]),
                                                        expansion: SelectionRead())
            try check(oversized.text == nil && oversizedExpansion == 1,
                      "Oversized focused selections must be rejected using UTF-16 length, including surrogate pairs")
        }
        print("Focused selection regression checks passed with fake accessibility sources; no apps or clipboard were read.")
    }
}
