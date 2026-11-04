import Foundation
import SwiftUI
import AppKit
import Combine
import VirtualDisplayKit

// All display resolutions currently use a 16:9 aspect ratio.
// Changing resolution recreates the virtual display, so it is available
// only while the display is stopped.
enum DisplayResolution: String, Codable, CaseIterable, Identifiable {
    case hd720
    case fullHD
    case qhd
    case ultraHD

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .hd720: 1280
        case .fullHD: 1920
        case .qhd: 2560
        case .ultraHD: 3840
        }
    }

    var height: Int {
        switch self {
        case .hd720: 720
        case .fullHD: 1080
        case .qhd: 1440
        case .ultraHD: 2160
        }
    }

    var label: String { "\(width) × \(height)" }
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

    @Published private(set) var isRunning = false
    @Published private(set) var displayConnected = false
    @Published private(set) var captureConfigured = false
    @Published private(set) var isPreviewVisible = false

    @Published private(set) var captureUpdatesPerSecond = 0.0
    @Published private(set) var capturedUpdatesTotal = 0

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

        // Capture all settings at Start. The settings editor is disabled
        // while running so streams and display geometry stay in sync.
        let settings = draftSettings
        let resolution = settings.resolution

        let display = VirtualDisplay(
            configuration: VirtualDisplayConfiguration(
                name: "Virtual Display Camera",
                maxWidth: UInt32(resolution.width),
                maxHeight: UInt32(resolution.height),
                hiDPIEnabled: false,
                refreshRate: 60,
                displayModes: [
                    DisplayMode(
                        width: resolution.width,
                        height: resolution.height,
                        refreshRate: 60
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
        print("[Bridge] Virtual display stopped")
    }

    // MARK: - Display Events

    func virtualDisplayDidBecomeReady(_ display: VirtualDisplay) {
        guard isRunning, virtualDisplay === display else { return }
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

        displayRenderer?.configure(
            displayID: displayID,
            resolution: resolution,
            scaleFactor: scaleFactor
        )
        previewRenderer?.configure(
            displayID: displayID,
            resolution: resolution,
            scaleFactor: scaleFactor
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
            counter.record()
            syphonPublisher?.publish(surface: surface)
        }

        displayRenderer = renderer
        renderer.configure(
            displayID: displayID,
            resolution: display.resolution,
            scaleFactor: display.scaleFactor
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
                    resolution: display.resolution,
                    scaleFactor: display.scaleFactor
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
