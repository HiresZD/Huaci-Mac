import AppKit

/// Keep AppKit's scrolling, hit testing and accessibility, but draw a quiet
/// thumb inside the full native hit area. Use with legacy-style scroll views;
/// overlay scrollers can fade out regardless of the app's desired idle state.
@MainActor
final class SubtleScroller: NSScroller {
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isTrackingMouse = false

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .legacy
        controlSize = .small
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        // The translation panel does not activate Huaci. Track while another
        // app is active as well, without a global event monitor or polling.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        refreshPointerState()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        needsDisplay = true
        defer {
            isTrackingMouse = false
            refreshPointerState()
            needsDisplay = true
        }
        // Let NSScroller handle knob dragging, slot clicks, target/action and
        // modifier keys. Only its visual treatment is customized here.
        super.mouseDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Clear the previous thumb, including its wider hover state, from our
        // transparent backing layer before redrawing it at its current size.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track or border: the surrounding panel material remains visible.
    }

    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        let nativeKnob = rect(for: .knob)
        guard !nativeKnob.isEmpty else { return }

        let isEmphasized = isPointerInside || isTrackingMouse
        let thickness: CGFloat = isEmphasized ? 6 : 3
        let thumb: NSRect
        if bounds.height >= bounds.width {
            thumb = NSRect(
                x: bounds.midX - thickness / 2,
                y: nativeKnob.minY,
                width: thickness,
                height: nativeKnob.height
            )
        } else {
            thumb = NSRect(
                x: nativeKnob.minX,
                y: bounds.midY - thickness / 2,
                width: nativeKnob.width,
                height: thickness
            )
        }
        NSColor.labelColor.withAlphaComponent(isEmphasized ? 0.42 : 0.22).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    private func refreshPointerState() {
        if let window, window.isVisible, !isHidden {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isPointerInside = visibleRect.contains(point)
        } else {
            isPointerInside = false
        }
        needsDisplay = true
    }
}
