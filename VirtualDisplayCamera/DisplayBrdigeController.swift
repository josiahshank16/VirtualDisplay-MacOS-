import Foundation
import SwiftUI
import AppKit
import Combine
import VirtualDisplayKit
import IOSurface

// All display resolutions currently use a 16:9 aspect ratio.
// Changing resolution recreates the virtual display, so it is available
// only while the display is stopped.
enum DisplayResolution: String, Codable, CaseIterable, Identifiable {
    case hd720
    case fullHD
    case qhd
    case ultraHD
    case ultraHD8K

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .hd720: 1280
        case .fullHD: 1920
        case .qhd: 2560
        case .ultraHD: 3840
        case .ultraHD8K: 7680
        }
    }

    var height: Int {
        switch self {
        case .hd720: 720
        case .fullHD: 1080
        case .qhd: 1440
        case .ultraHD: 2160
        case .ultraHD8K: 4320
        }
    }

    var label: String {
        let dimensions = "\(width) × \(height)"
        return self == .ultraHD8K ? "\(dimensions) (8K test)" : dimensions
    }

    var refreshRate: Int { self == .ultraHD8K ? 30 : 60 }
}

struct DisplaySettings: Codable, Equatable {
    var resolution: DisplayResolution = .fullHD
    var showCursorInSyphon: Bool = true
    var floatingPreview: Bool = false
    var syphonName: String = "VirtualDisplayCamera"

    var resolvedSyphonName: String {
        let trimmed = syphonName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "VirtualDisplayCamera" : trimmed
    }
}

struct SavedDisplayProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var settings: DisplaySettings
}

// Keep video-frame statistics independent of SwiftUI redraws.
private final class CaptureFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var intervalCount = 0
    private var totalCount = 0
    private var lastWidth = 0
    private var lastHeight = 0

    func record(width: Int, height: Int) {
        lock.lock()
        intervalCount += 1
        totalCount += 1
        lastWidth = width
        lastHeight = height
        lock.unlock()
    }

    func sample() -> (interval: Int, total: Int, width: Int, height: Int) {
        lock.lock()
        let result = (intervalCount, totalCount, lastWidth, lastHeight)
        intervalCount = 0
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        intervalCount = 0
        totalCount = 0
        lastWidth = 0
        lastHeight = 0
        lock.unlock()
    }
}

@MainActor
final class DisplayBridgeController:
    NSObject, ObservableObject,
    VirtualDisplayDelegate, NSWindowDelegate {

    @Published private(set) var isRunning = false
    @Published private(set) var displayConnected = false
    @Published private(set) var captureConfigured = false
    @Published private(set) var isPreviewVisible = false

    @Published private(set) var captureUpdatesPerSecond = 0.0
    @Published private(set) var capturedUpdatesTotal = 0
    @Published private(set) var submittedFrameWidth = 0
    @Published private(set) var submittedFrameHeight = 0
    @Published private(set) var activeDisplayPixelWidth = 0
    @Published private(set) var activeDisplayPixelHeight = 0
    @Published private(set) var activeDisplayLogicalWidth = 0
    @Published private(set) var activeDisplayLogicalHeight = 0
    @Published private(set) var activeDisplayModeRefreshRate = 0.0

    var isActiveModeDifferentFromRequested: Bool {
        guard isRunning,
              activeDisplayPixelWidth > 0,
              activeDisplayPixelHeight > 0 else { return false }
        return activeDisplayPixelWidth != draftSettings.resolution.width ||
            activeDisplayPixelHeight != draftSettings.resolution.height
    }

    // Editing the draft never silently overwrites a saved profile.
    @Published var draftSettings = DisplaySettings() {
        didSet { updatePreviewWindowLevel() }
    }
    @Published private(set) var profiles: [SavedDisplayProfile] = []
    @Published private(set) var selectedProfileID = UUID()

    var hasUnsavedChanges: Bool {
        profiles.first(where: { $0.id == selectedProfileID })?.settings != draftSettings
    }

    private enum Storage {
        static let profiles = "VirtualDisplayCamera.SavedProfiles.v1"
        static let selectedProfile = "VirtualDisplayCamera.SelectedProfile.v1"
    }

    private let frameCounter = CaptureFrameCounter()
    private var statisticsTimer: Timer?
    private var lastSampleTime: TimeInterval = 0

    // Recreated at Start according to the selected resolution.
    private var virtualDisplay: VirtualDisplay?
    private let publisher = SyphonTestPublisher()
    private var displayRenderer: DisplayStreamRenderer?

    // A separate preview stream is only used when the Syphon source
    // hides its cursor. The extra stream is stopped when preview closes.
    private var previewRenderer: DisplayStreamRenderer?
    private var previewWindow: NSWindow?

    override init() {
        super.init()
        restoreProfiles()
    }

    // MARK: - Saved Profiles

    func loadProfile(_ id: UUID) {
        guard !isRunning,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        selectedProfileID = id
        draftSettings = profile.settings
        persistProfiles()
    }

    func createProfile(named proposedName: String) {
        guard !isRunning else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let profile = SavedDisplayProfile(
            id: UUID(), name: name, settings: draftSettings
        )
        profiles.append(profile)
        selectedProfileID = profile.id
        persistProfiles()
    }

    func updateSelectedProfile() {
        guard !isRunning,
              let index = profiles.firstIndex(where: { $0.id == selectedProfileID })
        else { return }
        profiles[index].settings = draftSettings
        persistProfiles()
    }

    func deleteSelectedProfile() {
        guard !isRunning, profiles.count > 1 else { return }
        profiles.removeAll(where: { $0.id == selectedProfileID })
        guard let first = profiles.first else { return }
        selectedProfileID = first.id
        draftSettings = first.settings
        persistProfiles()
    }

    private func restoreProfiles() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Storage.profiles),
           let stored = try? JSONDecoder().decode(
                [SavedDisplayProfile].self, from: data
           ),
           !stored.isEmpty {
            profiles = stored
        } else {
            profiles = [
                SavedDisplayProfile(
                    id: UUID(), name: "Standard 1080p", settings: DisplaySettings()
                )
            ]
        }

        let preferred = UUID(
            uuidString: defaults.string(forKey: Storage.selectedProfile) ?? ""
        )
        let profile = profiles.first(where: { $0.id == preferred })
            ?? profiles[0]
        selectedProfileID = profile.id
        draftSettings = profile.settings
        persistProfiles()
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Storage.profiles)
            UserDefaults.standard.set(
                selectedProfileID.uuidString, forKey: Storage.selectedProfile
            )
        }
    }

    // MARK: - Start and Stop

    func start() {
        guard !isRunning else { return }

        frameCounter.reset()
        captureUpdatesPerSecond = 0
        capturedUpdatesTotal = 0
        submittedFrameWidth = 0
        submittedFrameHeight = 0
        activeDisplayPixelWidth = 0
        activeDisplayPixelHeight = 0
        activeDisplayLogicalWidth = 0
        activeDisplayLogicalHeight = 0
        activeDisplayModeRefreshRate = 0

        // Capture all settings at Start. The settings editor is disabled
        // while running so streams and display geometry stay in sync.
        let settings = draftSettings
        let resolution = settings.resolution

        let display = VirtualDisplay(
            configuration: VirtualDisplayConfiguration(
                name: "Virtual Display Camera",
                maxWidth: UInt32(resolution.width),
                maxHeight: UInt32(resolution.height),

                // macOS remembers the active mode for a monitor's
                // vendor/product/serial combination. A stable identity
                // PER RESOLUTION prevents 1080p from being restored when
                // a fresh 4K or 8K virtual display is created.
                //
                // Do not use CGDisplaySetDisplayMode here. Reports on newer
                // macOS versions indicate it can prevent virtual display
                // teardown until the creating process exits.
                vendorID: 0x3456,
                productID: 0x1234,
                serialNumber: (UInt32(resolution.width) << 16) |
                    UInt32(resolution.height),

                hiDPIEnabled: false,
                refreshRate: CGFloat(resolution.refreshRate),
                displayModes: [
                    DisplayMode(
                        width: resolution.width,
                        height: resolution.height,
                        refreshRate: CGFloat(resolution.refreshRate)
                    )
                ]
            )
        )
        display.delegate = self
        virtualDisplay = display

        isRunning = true
        publisher.start(name: settings.resolvedSyphonName)
        startStatisticsTimer()
        display.start()
        print("[Bridge] Starting virtual display at \(resolution.label)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        stopCapture()
        virtualDisplay?.stop()
        virtualDisplay = nil
        publisher.stop()
        stopStatisticsTimer()

        displayConnected = false
        captureUpdatesPerSecond = 0
        submittedFrameWidth = 0
        submittedFrameHeight = 0
        activeDisplayPixelWidth = 0
        activeDisplayPixelHeight = 0
        activeDisplayLogicalWidth = 0
        activeDisplayLogicalHeight = 0
        activeDisplayModeRefreshRate = 0
        print("[Bridge] Virtual display stopped")
    }

    // MARK: - Display Events

    func virtualDisplayDidBecomeReady(_ display: VirtualDisplay) {
        guard isRunning, virtualDisplay === display,
              let displayID = display.displayID else { return }

        updateActualDisplayMode(displayID)
        displayConnected = true
        startCapture()
    }

    func virtualDisplay(
        _ display: VirtualDisplay,
        didChangeResolution resolution: CGSize,
        scaleFactor: CGFloat
    ) {
        guard virtualDisplay === display,
              let displayID = display.displayID else { return }

        updateActualDisplayMode(displayID)
        // CGDisplayStream needs pixel dimensions. NSScreen's frame is
        // in points and must not be mistaken for the output pixel size.
        let pixelDimensions = actualPixelDimensions(
            displayID: displayID, fallbackResolution: resolution,
            fallbackScaleFactor: scaleFactor
        )
        displayRenderer?.configure(
            displayID: displayID,
            resolution: pixelDimensions,
            scaleFactor: 1.0
        )
        previewRenderer?.configure(
            displayID: displayID,
            resolution: pixelDimensions,
            scaleFactor: 1.0
        )
    }

    // MARK: - Real CoreGraphics display mode

    // CGDisplayPixelsWide/High and NSScreen.frame can describe logical
    // dimensions for a Retina/HiDPI mode. They are not reliable evidence
    // of the physical frame-buffer size. Use the current CGDisplayMode.
    private func readActiveMode(_ displayID: CGDirectDisplayID) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(displayID)
    }

    private func updateActualDisplayMode(_ displayID: CGDirectDisplayID) {
        if let mode = readActiveMode(displayID) {
            activeDisplayLogicalWidth = mode.width
            activeDisplayLogicalHeight = mode.height
            activeDisplayPixelWidth = mode.pixelWidth
            activeDisplayPixelHeight = mode.pixelHeight
            activeDisplayModeRefreshRate = mode.refreshRate

            print(
                "[Bridge] Active mode: " +
                "logical \(mode.width)x\(mode.height), " +
                "physical \(mode.pixelWidth)x\(mode.pixelHeight), " +
                "refresh \(mode.refreshRate)Hz; " +
                "requested \(draftSettings.resolution.label)"
            )
            if let screen = virtualDisplay?.screen {
                print(
                    "[Bridge] NSScreen frame \(screen.frame.size), " +
                    "backingScaleFactor \(screen.backingScaleFactor)"
                )
            }
        } else {
            // A temporary fallback for cases where WindowServer hasn't
            // populated the mode yet. Re-check on display-change events.
            activeDisplayLogicalWidth = Int(CGDisplayPixelsWide(displayID))
            activeDisplayLogicalHeight = Int(CGDisplayPixelsHigh(displayID))
            activeDisplayPixelWidth = 0
            activeDisplayPixelHeight = 0
            activeDisplayModeRefreshRate = 0
            print(
                "[Bridge] Current CGDisplayMode unavailable; " +
                "waiting for a valid pixel size before diagnosing a cap"
            )
        }
    }

    private func actualPixelDimensions(
        displayID: CGDirectDisplayID,
        fallbackResolution: CGSize,
        fallbackScaleFactor: CGFloat
    ) -> CGSize {
        if let mode = readActiveMode(displayID),
           mode.pixelWidth > 0,
           mode.pixelHeight > 0 {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }

        // Fallback until CGDisplayCopyDisplayMode is available. This is
        // an approximation only; the UI won't call it a physical mode.
        return CGSize(
            width: fallbackResolution.width * fallbackScaleFactor,
            height: fallbackResolution.height * fallbackScaleFactor
        )
    }

    // MARK: - Capture

    private func startCapture() {
        guard isRunning,
              displayRenderer == nil,
              let display = virtualDisplay,
              let displayID = display.displayID
        else { return }

        let renderer = DisplayStreamRenderer(
            backend: .cgDisplayStream,
            showCursor: draftSettings.showCursorInSyphon
        )
        let syphonPublisher = publisher
        let counter = frameCounter

        renderer.onFrameAvailable = { [weak syphonPublisher] surface in
            if syphonPublisher?.publish(surface: surface) == true {
                counter.record(
                    width: IOSurfaceGetWidth(surface),
                    height: IOSurfaceGetHeight(surface)
                )
            }
        }

        displayRenderer = renderer
        renderer.configure(
            displayID: displayID,
            resolution: actualPixelDimensions(
                displayID: displayID,
                fallbackResolution: display.resolution,
                fallbackScaleFactor: display.scaleFactor
            ),
            scaleFactor: 1.0
        )

        captureConfigured = true
        print("[Bridge] Capture configured; feed cursor = \(draftSettings.showCursorInSyphon)")
    }

    private func stopCapture() {
        hidePreview()
        displayRenderer?.onFrameAvailable = nil
        displayRenderer?.stopStream()
        displayRenderer = nil
        captureConfigured = false
    }

    // MARK: - Performance

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
        captureUpdatesPerSecond = Double(sample.interval) / elapsed
        capturedUpdatesTotal = sample.total
        submittedFrameWidth = sample.width
        submittedFrameHeight = sample.height
    }

    private func stopStatisticsTimer() {
        statisticsTimer?.invalidate()
        statisticsTimer = nil
    }

    // MARK: - Preview

    func showPreview() {
        guard captureConfigured,
              let outputRenderer = displayRenderer,
              let display = virtualDisplay,
              let displayID = display.displayID
        else {
            print("[Preview] No active display")
            return
        }

        if previewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: 960, height: 540
                ),
                styleMask: [
                    .titled, .closable, .miniaturizable, .resizable
                ],
                backing: .buffered,
                defer: false
            )
            window.title = "Virtual Display Preview"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentAspectRatio = NSSize(width: 16, height: 9)
            window.center()
            previewWindow = window
        }

        guard let window = previewWindow else { return }

        // When the feed includes the cursor, reuse the existing capture.
        // When the feed hides the cursor, create a preview-only stream
        // with the cursor enabled (never published to Syphon).
        if draftSettings.showCursorInSyphon {
            previewRenderer?.stopStream()
            previewRenderer = nil
            window.contentView = outputRenderer
        } else {
            if previewRenderer == nil {
                let preview = DisplayStreamRenderer(
                    backend: .cgDisplayStream, showCursor: true
                )
                previewRenderer = preview
                preview.configure(
                    displayID: displayID,
                    resolution: actualPixelDimensions(
                        displayID: displayID,
                        fallbackResolution: display.resolution,
                        fallbackScaleFactor: display.scaleFactor
                    ),
                    scaleFactor: 1.0
                )
            }
            window.contentView = previewRenderer
        }

        updatePreviewWindowLevel()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isPreviewVisible = true
    }

    func hidePreview() {
        if let window = previewWindow {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        previewRenderer?.stopStream()
        previewRenderer = nil
        isPreviewVisible = false
    }

    private func updatePreviewWindowLevel() {
        previewWindow?.level = draftSettings.floatingPreview
            ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === previewWindow else { return }
        window.contentView = NSView()
        previewRenderer?.stopStream()
        previewRenderer = nil
        isPreviewVisible = false
    }
}
