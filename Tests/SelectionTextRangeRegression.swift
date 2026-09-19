import Foundation
import CoreFoundation

private struct RangeRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct SelectionTextRangeRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw RangeRegressionFailure(description: message) }
    }

    static func main() throws {
        let source = "A😀 word 中文"
        try check(SelectionTextRange.extract(from: source, ranges: [CFRange(location: 1, length: 2)]) == "😀",
                  "AX UTF-16 ranges must preserve surrogate pairs")
        try check(SelectionTextRange.extract(from: source, ranges: [CFRange(location: 4, length: 4)]) == "word",
                  "Offsets after an emoji must use UTF-16 rather than Character indexes")
        try check(SelectionTextRange.extract(from: source, ranges: [CFRange(location: 1, length: 1)]) == nil,
                  "A range bisecting a surrogate pair must be rejected")
        try check(SelectionTextRange.extract(from: source, ranges: [CFRange(location: 10, length: 2)]) == nil,
                  "Out-of-bounds ranges must not return the entire field")
        try check(SelectionTextRange.extract(from: source, ranges: [CFRange(location: kCFNotFound, length: 1)]) == nil,
                  "CFNotFound must not become a valid selection")
        try check(SelectionTextRange.extract(from: source, ranges: [CFRange(location: 4, length: 0)]) == nil,
                  "An insertion caret is not a selected word")
        try check(SelectionTextRange.validated([CFRange(location: Int.max, length: 2)]) == nil,
                  "Overflowing ranges must be rejected")
        try check(SelectionTextRange.extract(from: "abcdef", ranges: [CFRange(location: 4, length: 2), CFRange(location: 0, length: 2)]) == "ab\nef",
                  "Separate ranges must be ordered and joined without unselected text")
        try check(SelectionTextRange.validated([CFRange(location: 0, length: 3), CFRange(location: 2, length: 2)]) == nil,
                  "Overlapping ranges must not duplicate text")
        try check(SelectionTextRange.extract(from: "word", ranges: [CFRange(location: 0, length: 4), CFRange(location: 0, length: 4)]) == "word",
                  "Identical ranges should be deduplicated")
        try check(SelectionTextRange.extract(from: String(repeating: "a", count: 200_001), ranges: [CFRange(location: 0, length: 1)]) == nil,
                  "AXValue fallback must have a strict document-size limit")
        try check(SelectionTextRange.validated([CFRange(location: 0, length: 20_001)]) == nil,
                  "Oversized selections must be rejected")
        print("Selection UTF-16 range regression checks passed; no other apps or clipboard were read.")
    }
}
