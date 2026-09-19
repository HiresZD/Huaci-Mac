import Foundation

@main
struct ChatWindowPlacementRegression {
    static func main() {
        let visible = CGRect(x: 0, y: 60, width: 1440, height: 816)
        let oldFrame = CGRect(x: 24, y: 100, width: 600, height: 662)
        let left = ChatWindowPlacement.frame(oldFrame, in: visible, near: CGPoint(x: 100, y: 760))
        let right = ChatWindowPlacement.frame(left, in: visible, near: CGPoint(x: 1100, y: 760))
        require(right.minX > left.minX, "A new right-side selection must move a previously left-side chat")
        require(right.size == oldFrame.size, "Moving a chat must preserve the user's size when it fits")
        requireContained(left, in: visible)
        requireContained(right, in: visible)
        var previousX = -CGFloat.greatestFiniteMagnitude
        for x in stride(from: 0, through: 1440, by: 40) {
            let frame = ChatWindowPlacement.frame(oldFrame, in: visible, near: CGPoint(x: CGFloat(x), y: 500))
            require(frame.minX >= previousX, "Moving the selection right must not jump the chat backwards")
            previousX = frame.minX
        }

        let screens = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1280, y: -240, width: 1280, height: 1024),
            CGRect(x: 0, y: 900, width: 1920, height: 1080)
        ]
        require(ChatWindowPlacement.screenIndex(near: CGPoint(x: -600, y: 400), frames: screens) == 1,
                "Select the display containing the selection, including negative coordinates")
        require(ChatWindowPlacement.screenIndex(near: CGPoint(x: 500, y: 1600), frames: screens) == 2,
                "Select an upper display rather than the previous window's display")
        require(ChatWindowPlacement.screenIndex(near: CGPoint(x: 2200, y: 1500), frames: screens) == 2,
                "An unavailable selection display should fall back to the nearest remaining display")
        require(ChatWindowPlacement.screenIndex(near: .zero, frames: []) == nil,
                "No display must be handled without indexing an empty array")
        let secondaryVisible = CGRect(x: -1280, y: -180, width: 1280, height: 940)
        let moved = ChatWindowPlacement.frame(right, in: secondaryVisible, near: CGPoint(x: -1000, y: 700))
        requireContained(moved, in: secondaryVisible)
        require(moved.minX < 0 && moved.size == oldFrame.size, "Moving displays must preserve a fitting size")

        let shortFrame = CGRect(x: 60, y: 120, width: 500, height: 480)
        let nearBottom = CGPoint(x: 400, y: 100)
        let above = ChatWindowPlacement.frame(shortFrame, in: visible, near: nearBottom)
        require(above.minY > nearBottom.y, "A selection near the Dock should put the chat above when it fits")
        for point in [CGPoint(x: 0, y: 60), CGPoint(x: 1440, y: 876), CGPoint(x: 720, y: 468)] {
            requireContained(ChatWindowPlacement.frame(oldFrame, in: visible, near: point), in: visible)
        }
        let huge = CGRect(x: -400, y: -600, width: 2400, height: 1800)
        let fitted = ChatWindowPlacement.frame(huge, in: visible, near: CGPoint(x: 1400, y: 70))
        require(fitted.size == visible.insetBy(dx: 8, dy: 8).size,
                "A window larger than the destination display must shrink to its usable bounds")
        requireContained(fitted, in: visible)
        require(ChatWindowPlacement.frame(shortFrame, in: visible) == shortFrame,
                "Reopening without a new selection must preserve the user's position and size")
        print("Chat window placement regression checks passed.")
    }

    private static func requireContained(_ frame: CGRect, in visible: CGRect) {
        let bounds = visible.insetBy(dx: 8, dy: 8)
        require(frame.minX >= bounds.minX && frame.maxX <= bounds.maxX &&
                frame.minY >= bounds.minY && frame.maxY <= bounds.maxY,
                "The window must stay inside the display's usable bounds, away from Dock and menu bar")
    }

    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
}
