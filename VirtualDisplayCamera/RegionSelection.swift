import AppKit
import VirtualDisplayKit

// Handles region selection on both real monitors and invisible virtual
// monitors. On a virtual monitor, the capture preview is mirrored into a
// selection window on a *physical* monitor. The user drags on that window;
// the returned rect is mapped back to the virtual monitor's point space.
@MainActor
final class RegionSelectionCoordinator {
    private var selectionWindow: NSWindow?
    private var mirrorRenderer: DisplayStreamRenderer?

    func select(
        on sourceScreen: NSScreen,
        mirrorVirtualDisplay: Bool,
        displayID: CGDirectDisplayID,
        completion: @escaping (CGRect?) -> Void
    ) {
        cancel()

        let frame: NSRect
        if mirrorVirtualDisplay {
            let physical = NSScreen.screens.first(where: { screen in
                let n = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
                return n?.uint32Value != displayID
            }) ?? NSScreen.main ?? sourceScreen

            let maxWidth = min(1000.0, physical.visibleFrame.width * 0.85)
            let maxHeight = min(750.0, physical.visibleFrame.height * 0.80)
            let ratio = sourceScreen.frame.width / max(1, sourceScreen.frame.height)
            let width = min(maxWidth, maxHeight * ratio)
            let height = width / ratio
            frame = NSRect(
                x: physical.visibleFrame.midX - width / 2,
                y: physical.visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
        } else {
            frame = sourceScreen.frame
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = mirrorVirtualDisplay
        window.level = mirrorVirtualDisplay ? .floating : .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true

        if mirrorVirtualDisplay {
            let renderer = DisplayStreamRenderer(
                backend: .cgDisplayStream, showCursor: true
            )
            renderer.frame = container.bounds
            renderer.autoresizingMask = [.width, .height]
            container.addSubview(renderer, positioned: .below, relativeTo: nil)
            mirrorRenderer = renderer

            // Configure the mirrored preview, not the Syphon camera.
            // CGDisplayMode's pixel size is authoritative for HiDPI.
            if let mode = CGDisplayCopyDisplayMode(displayID) {
                renderer.configure(
                    displayID: displayID,
                    resolution: CGSize(
                        width: mode.pixelWidth, height: mode.pixelHeight
                    ),
                    scaleFactor: 1.0
                )
            } else {
                renderer.configure(
                    displayID: displayID,
                    resolution: sourceScreen.frame.size,
                    scaleFactor: sourceScreen.backingScaleFactor
                )
            }
        }

        let overlay = RegionSelectionView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.dimBackground = !mirrorVirtualDisplay
        overlay.isMirroredSelection = mirrorVirtualDisplay
        overlay.onSelection = { [weak self, weak overlay] chosen in
            guard let overlay else {
                completion(nil)
                return
            }
            self?.cancel()

            let selected = chosen.map { rect in
                let xScale = sourceScreen.frame.width / max(1, overlay.bounds.width)
                let yScale = sourceScreen.frame.height / max(1, overlay.bounds.height)
                return CGRect(
                    x: rect.minX * xScale,
                    y: rect.minY * yScale,
                    width: rect.width * xScale,
                    height: rect.height * yScale
                ).intersection(
                    CGRect(origin: .zero, size: sourceScreen.frame.size)
                )
            }
            completion(selected)
        }
        container.addSubview(overlay)
        window.contentView = container
        selectionWindow = window

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        mirrorRenderer?.stopStream()
        mirrorRenderer = nil
        selectionWindow?.orderOut(nil)
        selectionWindow?.contentView = nil
        selectionWindow = nil
    }
}

@MainActor
private final class RegionSelectionView: NSView {
    var onSelection: ((CGRect?) -> Void)?
    var dimBackground = true
    var isMirroredSelection = false

    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var selectedRect: CGRect? {
        guard let a = dragStart, let b = dragEnd else { return nil }
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        ).intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        if dimBackground {
            NSColor.black.withAlphaComponent(0.26).setFill()
            NSBezierPath(rect: bounds).fill()
        }

        if let rect = selectedRect, rect.width > 0, rect.height > 0 {
            NSColor.systemBlue.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 3
            outline.stroke()
        }

        let text = isMirroredSelection
            ? "Virtual display mirror — drag to crop  •  Esc to cancel"
            : "Drag to select a capture region  •  Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.boldSystemFont(ofSize: 16),
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ]
        (text as NSString).draw(
            at: NSPoint(x: 24, y: 24),
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
