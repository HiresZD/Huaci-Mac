import AppKit
import ApplicationServices

enum AccessibilityReader {
    // Read the original focused selection before attempting optional hit tests,
    // ranges or tree expansion. Copy compatibility is a separate event path.
    static func read(pid: pid_t, point: CGPoint?, enableChromium: Bool) -> SelectionRead {
        let source = FocusedAXSource(pid: pid, enableChromium: enableChromium)
        return FocusedSelectionReader.read(from: source) {
            // A fresh expansion budget cannot consume the primary path's time.
            Reader(pid: pid).read(point: point)
        }
    }

    private final class FocusedAXSource: FocusedSelectionSource {
        private let application: AXUIElement
        private let deadline = ProcessInfo.processInfo.systemUptime + 1.5

        var canRead: Bool { ProcessInfo.processInfo.systemUptime < deadline }

        init(pid: pid_t, enableChromium: Bool) {
            application = AXUIElementCreateApplication(pid)
            // Preserve the original warm-up before Chromium accessibility enablement.
            _ = attribute(application, kAXRoleAttribute)
            if enableChromium {
                for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                    guard prepare(application) else { break }
                    _ = AXUIElementSetAttributeValue(application, name as CFString, kCFBooleanTrue)
                }
            }
        }

        private func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            // Restore the previous 250 ms message allowance on this path.
            return AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining))) == .success
        }

        private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }

        private func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        func focusedElement() -> AXUIElement? {
            element(attribute(application, kAXFocusedUIElementAttribute))
        }

        func textAttribute(_ name: FocusedSelectionAttribute, of item: AXUIElement) -> String? {
            let attributeName: String
            switch name {
            case .role: attributeName = kAXRoleAttribute
            case .subrole: attributeName = kAXSubroleAttribute
            case .selectedText: attributeName = kAXSelectedTextAttribute
            }
            return attribute(item, attributeName) as? String
        }

        func parent(of item: AXUIElement) -> AXUIElement? {
            element(attribute(item, kAXParentAttribute))
        }

        func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }
    }

    private final class Reader {
        private struct Attribute {
            let error: AXError
            let value: CFTypeRef?
        }

        private struct Node {
            let element: AXUIElement
            var attributes: [String: Attribute] = [:]
            var ancestryChecked = false
        }

        private let pid: pid_t
        private let application: AXUIElement
        private let deadline = ProcessInfo.processInfo.systemUptime + 0.65
        private let maximumNodes = 48
        private let maximumParents = 16
        private var nodes: [Node] = []
        private var secure = false
        private var securityIncomplete = false

        init(pid: pid_t) {
            self.pid = pid
            application = AXUIElementCreateApplication(pid)
        }

        private var hasTime: Bool { ProcessInfo.processInfo.systemUptime < deadline }

        private func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            // A single unresponsive app may exceed the overall budget by at most
            // this one message timeout; no later message starts after the deadline.
            return AXUIElementSetMessagingTimeout(element, Float(min(0.06, remaining))) == .success
        }

        private func nodeIndex(_ element: AXUIElement) -> Int? {
            if let index = nodes.firstIndex(where: { CFEqual($0.element, element) }) { return index }
            guard nodes.count < maximumNodes, hasTime else { return nil }
            nodes.append(Node(element: element))
            return nodes.count - 1
        }

        private func attribute(_ element: AXUIElement, _ name: String) -> Attribute {
            guard let index = nodeIndex(element) else { return Attribute(error: .cannotComplete, value: nil) }
            if let cached = nodes[index].attributes[name] { return cached }
            guard prepare(element) else { return Attribute(error: .cannotComplete, value: nil) }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            let result = Attribute(error: status, value: status == .success ? value : nil)
            nodes[index].attributes[name] = result
            return result
        }

        private func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        private func uniqueAppend(_ item: AXUIElement?, to list: inout [AXUIElement]) {
            guard let item, !list.contains(where: { CFEqual($0, item) }) else { return }
            list.append(item)
        }

        // Finish the ancestor checks before reading text. A secure ancestor must
        // block every route, including a valid selection on another seed.
        private func checkedAncestors(of start: AXUIElement) -> [AXUIElement]? {
            var path: [AXUIElement] = []
            var current: AXUIElement? = start
            for _ in 0..<maximumParents {
                guard let item = current else { break }
                guard hasTime, let index = nodeIndex(item) else {
                    securityIncomplete = true
                    return nil
                }
                guard !path.contains(where: { CFEqual($0, item) }) else {
                    securityIncomplete = true
                    return nil
                }
                path.append(item)
                if nodes[index].ancestryChecked { return path }
                let roleResult = attribute(item, kAXRoleAttribute)
                let subroleResult = attribute(item, kAXSubroleAttribute)
                let role = roleResult.value as? String
                let subrole = subroleResult.value as? String
                if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
                    secure = true
                    return nil
                }
                guard roleResult.error == .success, role != nil,
                      subroleResult.error == .success || subroleResult.error == .attributeUnsupported || subroleResult.error == .noValue
                else {
                    securityIncomplete = true
                    return nil
                }
                if role == kAXApplicationRole || role == kAXWindowRole {
                    markChecked(path)
                    return path
                }
                let parent = attribute(item, kAXParentAttribute)
                if parent.error == .noValue || parent.error == .attributeUnsupported {
                    markChecked(path)
                    return path
                }
                guard parent.error == .success, let next = element(parent.value) else {
                    securityIncomplete = true
                    return nil
                }
                current = next
            }
            securityIncomplete = true
            return nil
        }

        private func markChecked(_ path: [AXUIElement]) {
            for item in path {
                if let index = nodes.firstIndex(where: { CFEqual($0.element, item) }) {
                    nodes[index].ancestryChecked = true
                }
            }
        }

        private func selectedRange(_ value: CFTypeRef?) -> CFRange? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let axValue = value as! AXValue
            guard AXValueGetType(axValue) == .cfRange else { return nil }
            var range = CFRange(location: kCFNotFound, length: 0)
            guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
            return range
        }

        private func selectedRanges(_ item: AXUIElement) -> [CFRange]? {
            let multiple = attribute(item, "AXSelectedTextRanges").value
            if let multiple, CFGetTypeID(multiple) == CFArrayGetTypeID(), let values = multiple as? [AnyObject], !values.isEmpty {
                guard values.count <= SelectionTextRange.maximumRangeCount else { return nil }
                let ranges = values.compactMap { selectedRange($0) }
                guard ranges.count == values.count else { return nil }
                return SelectionTextRange.validated(ranges)
            }
            guard let range = selectedRange(attribute(item, kAXSelectedTextRangeAttribute).value) else { return nil }
            return SelectionTextRange.validated([range])
        }

        private func selection(in item: AXUIElement) -> String? {
            if let text = attribute(item, kAXSelectedTextAttribute).value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               text.utf16.count <= SelectionTextRange.maximumSelectionUTF16Length {
                return text
            }
            guard let ranges = selectedRanges(item) else { return nil }
            var pieces: [String] = []
            var parameterizedSucceeded = true
            for originalRange in ranges {
                var range = originalRange
                guard prepare(item), let value = AXValueCreate(.cfRange, &range) else { return nil }
                var result: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(
                    item, kAXStringForRangeParameterizedAttribute as CFString, value, &result
                )
                guard error == .success, let text = result as? String,
                      text.utf16.count == range.length else {
                    parameterizedSucceeded = false
                    break
                }
                pieces.append(text)
            }
            if parameterizedSucceeded {
                let text = pieces.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                return nil
            }
            // AXValue is only sliced with a validated, nonempty selection range.
            // Never treat the entire text field, document title, or label as selected.
            // Check the app's character count before fetching its complete value;
            // missing counts use the explicit Copy route instead of an unbounded read.
            guard let count = attribute(item, kAXNumberOfCharactersAttribute).value as? NSNumber,
                  count.int64Value >= 0,
                  count.int64Value <= Int64(SelectionTextRange.maximumValueUTF16Length),
                  let lastRange = ranges.last,
                  lastRange.location + lastRange.length <= count.intValue else { return nil }
            guard let value = attribute(item, kAXValueAttribute).value as? String else { return nil }
            return SelectionTextRange.extract(from: value, ranges: ranges)
        }

        private func children(of item: AXUIElement) -> [AXUIElement] {
            guard prepare(item) else { return [] }
            var values: CFArray?
            // Read a small prefix directly, never materialize an entire document tree.
            guard AXUIElementCopyAttributeValues(item, kAXChildrenAttribute as CFString, 0, 8, &values) == .success,
                  let values else { return [] }
            let rawChildren = values as [AnyObject]
            return rawChildren.compactMap { element($0) }
        }

        func read(point: CGPoint?) -> SelectionRead {
            var seeds: [AXUIElement] = []
            let focused = element(attribute(application, kAXFocusedUIElementAttribute).value)
            if let point, point.x.isFinite, point.y.isFinite, prepare(application) {
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success,
                   let hit, prepare(hit) {
                    var hitPID: pid_t = 0
                    if AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid {
                        uniqueAppend(hit, to: &seeds)
                    }
                }
            }
            // For a mouse selection the hit element is more specific than a
            // stale focused sidebar/search box. Keyboard reads pass no point.
            uniqueAppend(focused, to: &seeds)
            if let window = element(attribute(application, kAXFocusedWindowAttribute).value) {
                uniqueAppend(element(attribute(window, kAXFocusedUIElementAttribute).value), to: &seeds)
            }
            guard !seeds.isEmpty else { return SelectionRead(safetyUnverified: true) }
            var groups: [(seed: AXUIElement, ancestors: [AXUIElement])] = []
            for seed in seeds {
                guard let ancestors = checkedAncestors(of: seed) else {
                    return SelectionRead(secure: secure, safetyUnverified: securityIncomplete)
                }
                groups.append((seed: seed, ancestors: ancestors))
            }
            // Finish the hit group's local search before considering a focused
            // sidebar/search box that may still expose an unrelated old selection.
            // Keep both query deduplication and traversal budgets global to the read.
            var inspected: [AXUIElement] = []
            var visited: [AXUIElement] = []
            for group in groups {
                for item in group.ancestors {
                    guard hasTime else { break }
                    if inspected.contains(where: { CFEqual($0, item) }) { continue }
                    inspected.append(item)
                    if let text = selection(in: item) { return SelectionRead(text: text) }
                }
                // Descend only from the original hit/focused element, never from
                // one of its window ancestors or an entire document tree.
                var queue = [(group.seed, 0)]
                while !queue.isEmpty, hasTime, visited.count < 24 {
                    let (item, depth) = queue.removeFirst()
                    if visited.contains(where: { CFEqual($0, item) }) { continue }
                    visited.append(item)
                    guard checkedAncestors(of: item) != nil else {
                        return SelectionRead(secure: secure, safetyUnverified: securityIncomplete)
                    }
                    if !inspected.contains(where: { CFEqual($0, item) }) {
                        inspected.append(item)
                        if let text = selection(in: item) { return SelectionRead(text: text) }
                    }
                    let role = attribute(item, kAXRoleAttribute).value as? String
                    guard depth < 3, role != kAXWindowRole, role != kAXApplicationRole else { continue }
                    for child in children(of: item) { queue.append((child, depth + 1)) }
                }
            }
            return SelectionRead(secure: secure, safetyUnverified: securityIncomplete)
        }
    }
}
