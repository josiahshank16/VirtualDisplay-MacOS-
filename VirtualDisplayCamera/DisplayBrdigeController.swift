
import Foundation
import SwiftUI
import AppKit
import Combine
import VirtualDisplayKit

// Lightweight frame counter.
// No SwiftUI updates happen for individual frames.
private final class CaptureFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var intervalCount = 0
    private var totalCount = 0

    func record() {
        lock.lock()
        intervalCount += 1
        totalCount += 1
        lock.unlock()
    }

    func sample() -> (interval: Int, total: Int) {
        lock.lock()
        let result = (intervalCount, totalCount)
        intervalCount = 0
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        intervalCount = 0
        totalCount = 0
        lock.unlock()
    }
}

@MainActor
final class DisplayBridgeController:
    NSObject, ObservableObject,
    VirtualDisplayDelegate, NSWindowDelegate {

    // MARK: - Status

    @Published private(set) var isRunning = false
    @Published private(set) var displayConnected = false
    @Published private(set) var captureConfigured = false
    @Published private(set) var isPreviewVisible = false

    // MARK: - Performance

    @Published private(set) var captureUpdatesPerSecond = 0.0
    @Published private(set) var capturedUpdatesTotal = 0

    private let frameCounter = CaptureFrameCounter()
    private var statisticsTimer: Timer?
    private var lastSampleTime: TimeInterval = 0

    // MARK: - Virtual Display

    private let virtualDisplay = VirtualDisplay(
        configuration: VirtualDisplayConfiguration(
            name: "Virtual Display Camera",
            maxWidth: 1920,
            maxHeight: 1080,
            hiDPIEnabled: false,
            refreshRate: 60,
            displayModes: [
                DisplayMode(
                    width: 1920,
                    height: 1080,
                    refreshRate: 60
                )
            ]
        )
    )

    // MARK: - Video Output

    private let publisher = SyphonTestPublisher()
    private var displayRenderer: DisplayStreamRenderer?

    // MARK: - Preview

    private var previewWindow: NSWindow?

    override init() {
        super.init()
        virtualDisplay.delegate = self
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }

        frameCounter.reset()
        captureUpdatesPerSecond = 0
        capturedUpdatesTotal = 0

        isRunning = true

        publisher.start()
        startStatisticsTimer()
        virtualDisplay.start()

        print("[Bridge] Starting virtual display")
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false

        stopCapture()
        virtualDisplay.stop()
        publisher.stop()
        stopStatisticsTimer()

        displayConnected = false
        captureUpdatesPerSecond = 0

        print("[Bridge] Virtual display stopped")
    }

    // MARK: - Display Events

    func virtualDisplayDidBecomeReady(
        _ display: VirtualDisplay
    ) {
        displayConnected = true
        startCapture()
    }

    func virtualDisplay(
        _ display: VirtualDisplay,
        didChangeResolution resolution: CGSize,
        scaleFactor: CGFloat
    ) {
        guard let renderer = displayRenderer,
              let displayID = display.displayID
        else { return }

        renderer.configure(
            displayID: displayID,
            resolution: resolution,
            scaleFactor: scaleFactor
        )
    }

    // MARK: - Display Capture

    private func startCapture() {
        guard isRunning,
              displayRenderer == nil,
              let displayID = virtualDisplay.displayID
        else { return }

        let renderer = DisplayStreamRenderer(
            backend: .cgDisplayStream,
            showCursor: true
        )

        let syphonPublisher = publisher
        let counter = frameCounter

        renderer.onFrameAvailable = {
            [weak syphonPublisher] surface in

            counter.record()

            // Keep our original working
            // Syphon output unchanged.
            syphonPublisher?.publish(surface: surface)
        }

        displayRenderer = renderer

        renderer.configure(
            displayID: displayID,
            resolution: virtualDisplay.resolution,
            scaleFactor: virtualDisplay.scaleFactor
        )

        captureConfigured = true
        print("[Bridge] Capture configured")
    }

    private func stopCapture() {
        hidePreview()

        displayRenderer?.onFrameAvailable = nil
        displayRenderer?.stopStream()
        displayRenderer = nil

        captureConfigured = false
    }

    // MARK: - Performance Monitoring

    private func startStatisticsTimer() {
        guard statisticsTimer == nil else { return }

        lastSampleTime = ProcessInfo.processInfo.systemUptime

        let timer = Timer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(refreshStatistics),
            userInfo: nil,
            repeats: true
        )

        RunLoop.main.add(timer, forMode: .common)
        statisticsTimer = timer
    }

    @objc private func refreshStatistics() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - lastSampleTime)
        lastSampleTime = now

        let sample = frameCounter.sample()

        captureUpdatesPerSecond =
            Double(sample.interval) / elapsed

        capturedUpdatesTotal = sample.total
    }

    private func stopStatisticsTimer() {
        statisticsTimer?.invalidate()
        statisticsTimer = nil
    }

    // MARK: - Preview Window

    func showPreview() {
        guard captureConfigured,
              let renderer = displayRenderer
        else {
            print("[Preview] No active display")
            return
        }

        if previewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: 960,
                    height: 540
                ),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable
                ],
                backing: .buffered,
                defer: false
            )

            window.title = "Virtual Display Preview"
            window.isReleasedWhenClosed = false
            window.delegate = self

            window.contentAspectRatio = NSSize(
                width: 16,
                height: 9
            )

            window.center()
            previewWindow = window
        }

        guard let window = previewWindow else { return }

        // Reuse the existing capture renderer.
        window.contentView = renderer

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isPreviewVisible = true
    }

    func hidePreview() {
        guard let window = previewWindow else {
            isPreviewVisible = false
            return
        }

        if window.isVisible {
            window.close()
        } else {
            window.contentView = NSView()
            isPreviewVisible = false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === previewWindow
        else { return }

        window.contentView = NSView()
        isPreviewVisible = false
    }
}
