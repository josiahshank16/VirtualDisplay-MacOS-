import AppKit

// A non-interactive-to-the-application selection overlay: click and drag
// directly on a physical monitor to define a ScreenCaptureKit sourceRect.
// The rectangle is returned in TOP-LEFT-origin display points.
@MainActor
final class RegionSelectionCoordinator {
    private var selectionWindow: NSWindow?

    func select(
        on screen: NSScreen,
        completion: @escaping (CGRect?) -> Void
    ) {
        cancel()

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onSelection = { [weak self] rect in
            self?.selectionWindow?.orderOut(nil)
            self?.selectionWindow?.contentView = nil
            self?.selectionWindow = nil
            completion(rect)
        }
        window.contentView = view
        selectionWindow = window

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        selectionWindow?.orderOut(nil)
        selectionWindow?.contentView = nil
        selectionWindow = nil
    }
}

@MainActor
private final class RegionSelectionView: NSView {
    var onSelection: ((CGRect?) -> Void)?

    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var selectedRect: CGRect? {
        guard let a = dragStart, let b = dragEnd else { return nil }
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        return CGRect(
            x: x, y: y,
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        ).intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: bounds).fill()

        if let rect = selectedRect, rect.width > 0, rect.height > 0 {
            NSColor.systemBlue.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 3
            outline.stroke()
        }

        let text = "Drag to select a capture region  •  Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.boldSystemFont(ofSize: 18),
            .backgroundColor: NSColor.black.withAlphaComponent(0.55)
        ]
        (text as NSString).draw(
            at: NSPoint(x: 25, y: 25),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragEnd = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragEnd = convert(event.locationInWindow, from: nil)
        let rect = selectedRect
        dragStart = nil
        dragEnd = nil
        if let rect, rect.width >= 16, rect.height >= 16 {
            onSelection?(rect)
        } else {
            onSelection?(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onSelection?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
