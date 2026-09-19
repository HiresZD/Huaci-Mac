import Foundation

/// Screen coordinates use AppKit's bottom-left origin, including negative origins
/// on secondary displays. Keep placement separate from rendering a conversation.
enum ChatWindowPlacement {
    static func screenIndex(near point: CGPoint, frames: [CGRect]) -> Int? {
        if let index = frames.firstIndex(where: { $0.contains(point) }) { return index }
        // A display may have disconnected since the selection was captured.
        // Choose the closest remaining display, not the previous chat's display.
        return frames.indices.min { lhs, rhs in
            squaredDistance(from: point, to: frames[lhs]) < squaredDistance(from: point, to: frames[rhs])
        }
    }

    static func frame(_ current: CGRect, in visibleFrame: CGRect, near point: CGPoint? = nil) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        var result = current
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        if let point {
            // Move right with the selection until the screen edge is reached.
            // Switching to the selection's left side would cause a backward jump.
            result.origin.x = point.x + 8
            let below = point.y - 12 - result.height
            let above = point.y + 12
            result.origin.y = below >= bounds.minY || above + result.height > bounds.maxY
                ? below : above
        }
        result.origin.x = max(bounds.minX, min(result.minX, bounds.maxX - result.width))
        result.origin.y = max(bounds.minY, min(result.minY, bounds.maxY - result.height))
        return result
    }

    private static func squaredDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, max(0, point.x - frame.maxX))
        let dy = max(frame.minY - point.y, max(0, point.y - frame.maxY))
        return dx * dx + dy * dy
    }
}
