import Foundation
import CoreFoundation

// AX ranges are UTF-16 offsets, not Swift Character offsets. Keep this helper
// independent of AppKit so range handling can be checked without reading an app.
enum SelectionTextRange {
    static let maximumSelectionUTF16Length = 20_000
    static let maximumValueUTF16Length = 200_000
    static let maximumRangeCount = 8

    static func validated(_ ranges: [CFRange]) -> [CFRange]? {
        guard !ranges.isEmpty, ranges.count <= maximumRangeCount else { return nil }
        var result: [CFRange] = []
        var length = 0
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            guard range.location >= 0, range.location != kCFNotFound, range.length > 0,
                  range.length <= maximumSelectionUTF16Length,
                  range.location <= Int.max - range.length else { return nil }
            if let previous = result.last {
                if previous.location == range.location && previous.length == range.length { continue }
                guard previous.location + previous.length <= range.location else { return nil }
            }
            // Account for the newline inserted between separate selections.
            length += range.length + (result.isEmpty ? 0 : 1)
            guard length <= maximumSelectionUTF16Length else { return nil }
            result.append(range)
        }
        return result.isEmpty ? nil : result
    }

    static func extract(from value: String, ranges: [CFRange]) -> String? {
        let sourceLength = value.utf16.count
        guard sourceLength <= maximumValueUTF16Length,
              let ranges = validated(ranges) else { return nil }
        var parts: [String] = []
        for range in ranges {
            guard range.location <= sourceLength,
                  range.length <= sourceLength - range.location,
                  let swiftRange = Range(NSRange(location: range.location, length: range.length), in: value)
            else { return nil }
            parts.append(String(value[swiftRange]))
        }
        let selected = parts.joined(separator: "\n")
        return selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selected
    }
}
