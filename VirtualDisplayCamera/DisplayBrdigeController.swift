import Foundation
import SwiftUI
import AppKit
import Combine
import VirtualDisplayKit
import IOSurface
import ScreenCaptureKit

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

    // Added in Batch 2. Custom decoding preserves saved Batch 1 profiles.
    var sourceMode: CaptureSourceMode = .virtualDisplay
    var outputFPSCap: Int = 0 // 0 = no additional publishing cap
    var windowTitle: String = ""
    var windowBundleID: String = ""
    var regionDisplayName: String = ""
    var regionRect: CGRect? = nil

    var resolvedSyphonName: String {
        let trimmed = syphonName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "VirtualDisplayCamera" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case resolution, showCursorInSyphon, floatingPreview, syphonName
        case sourceMode, outputFPSCap, windowTitle, windowBundleID
        case regionDisplayName, regionRect
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try values.decodeIfPresent(DisplayResolution.self, forKey: .resolution) ?? .fullHD
        showCursorInSyphon = try values.decodeIfPresent(Bool.self, forKey: .showCursorInSyphon) ?? true
        floatingPreview = try values.decodeIfPresent(Bool.self, forKey: .floatingPreview) ?? false
        syphonName = try values.decodeIfPresent(String.self, forKey: .syphonName) ?? "VirtualDisplayCamera"
        sourceMode = try values.decodeIfPresent(CaptureSourceMode.self, forKey: .sourceMode) ?? .virtualDisplay
        outputFPSCap = try values.decodeIfPresent(Int.self, forKey: .outputFPSCap) ?? 0
        windowTitle = try values.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
        windowBundleID = try values.decodeIfPresent(String.self, forKey: .windowBundleID) ?? ""
        regionDisplayName = try values.decodeIfPresent(String.self, forKey: .regionDisplayName) ?? ""
        regionRect = try values.decodeIfPresent(CGRect.self, forKey: .regionRect)
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
    @Published private(set) var availableWindows: [CaptureWindowChoice] = []
    @Published private(set) var availableDisplays: [CaptureDisplayChoice] = []
    @Published private(set) var selectedWindowID: CGWindowID?
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var isRefreshingSources = false
    @Published private(set) var isSelectingRegion = false
    @Published var captureError: String?

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

    private var externalCapture: ExternalCaptureSession?
    private var externalPreviewCapture: ExternalCaptureSession?
    private let externalPreviewView = SurfacePreviewView()
    private let regionSelector = RegionSelectionCoordinator()
    private var externalFilter: SCContentFilter?
    private var externalSourceRect: CGRect?
    private var externalCaptureWidth = 0
    private var externalCaptureHeight = 0

    // Prevent an asynchronous start from completing after Stop was pressed.
    private var captureGeneration = 0
    private var lastPublishedUptime: TimeInterval = 0

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
        matchSavedSourceSelections()
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
        matchSavedSourceSelections()
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

    // MARK: - Source discovery and selection

    func refreshAvailableSources() {
        guard !isRefreshingSources else { return }
        isRefreshingSources = true
        captureError = nil

        Task {
            defer { isRefreshingSources = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )

                let ownBundleID = Bundle.main.bundleIdentifier ?? ""
                availableWindows = content.windows.compactMap { window in
                    let title = (window.title ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    let app = window.owningApplication
                    let bundleID = app?.bundleIdentifier ?? ""
                    guard !title.isEmpty,
                          window.frame.width >= 64,
                          window.frame.height >= 64,
                          bundleID != ownBundleID
                    else { return nil }

                    return CaptureWindowChoice(
                        id: window.windowID,
                        title: title,
                        applicationName: app?.applicationName ?? "Unknown App",
                        bundleIdentifier: bundleID
                    )
                }
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

                availableDisplays = content.displays.map { display in
                    let screen = NSScreen.screens.first(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                            .uint32Value == display.displayID
                    })
                    return CaptureDisplayChoice(
                        id: display.displayID,
                        name: screen?.localizedName ?? "Display \(display.displayID)",
                        width: display.width,
                        height: display.height
                    )
                }

                matchSavedSourceSelections()
            } catch {
                captureError = "Cannot list capture sources: \(error.localizedDescription). Check Screen Recording permissions."
            }
        }
    }

    private func matchSavedSourceSelections() {
        selectedWindowID = availableWindows.first(where: {
            $0.title == draftSettings.windowTitle &&
            $0.bundleIdentifier == draftSettings.windowBundleID
        })?.id

        selectedDisplayID = availableDisplays.first(where: {
            $0.name == draftSettings.regionDisplayName
        })?.id ?? availableDisplays.first?.id
    }

    func selectWindow(_ id: CGWindowID) {
        guard !isRunning,
              let selected = availableWindows.first(where: { $0.id == id })
        else { return }
        selectedWindowID = id
        draftSettings.windowTitle = selected.title
        draftSettings.windowBundleID = selected.bundleIdentifier
    }

    func selectRegionDisplay(_ id: CGDirectDisplayID) {
        guard !isRunning,
              let selected = availableDisplays.first(where: { $0.id == id })
        else { return }
        if selectedDisplayID != id {
            draftSettings.regionRect = nil
        }
        selectedDisplayID = id
        draftSettings.regionDisplayName = selected.name
    }

    func selectRegionWithMouse() {
        guard !isRunning, !isSelectingRegion,
              let id = selectedDisplayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                      .uint32Value == id
              })
        else {
            captureError = "Select an available monitor before choosing a region."
            return
        }

        isSelectingRegion = true
        regionSelector.select(on: screen) { [weak self] rect in
            guard let self else { return }
            self.isSelectingRegion = false
            guard let rect else { return } // Escape / too-small selection
            self.draftSettings.regionRect = rect
            self.draftSettings.regionDisplayName = self.availableDisplays.first(
                where: { $0.id == id }
            )?.name ?? screen.localizedName
            self.captureError = nil
        }
    }

    var regionSummary: String {
        guard let rect = draftSettings.regionRect else {
            return "No region selected"
        }
        return "\(Int(rect.width)) × \(Int(rect.height)) points at " +
            "(\(Int(rect.minX)), \(Int(rect.minY)))"
    }

    // MARK: - Start and Stop

    func start() {
        guard !isRunning else { return }

        captureError = nil
        captureGeneration += 1
        lastPublishedUptime = 0
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

        if settings.sourceMode != .virtualDisplay {
            isRunning = true
            publisher.start(name: settings.resolvedSyphonName)
            startStatisticsTimer()
            let generation = captureGeneration
            Task { await startExternalCapture(generation: generation) }
            return
        }

        // For large output sizes, create a Retina virtual monitor:
        // maxWidth/maxHeight describe the physical framebuffer and
        // CGVirtualDisplayMode describes the logical desktop at 2x.
        // This matches Chromium's CGVirtualDisplay setup and prevents
        // asking WindowServer for an effectively 8K logical desktop
        // when we only need a 4K Syphon output.
        //
        // 720p/1080p retain the original unscaled settings.
        let usesRetinaBacking = resolution.width > 1920
        let logicalWidth = usesRetinaBacking
            ? resolution.width / 2 : resolution.width
        let logicalHeight = usesRetinaBacking
            ? resolution.height / 2 : resolution.height

        print(
            "[Bridge] Requested output \(resolution.width)x\(resolution.height); " +
            "advertised logical mode \(logicalWidth)x\(logicalHeight); " +
            "HiDPI enabled \(usesRetinaBacking)"
        )

        let display = VirtualDisplay(
            configuration: VirtualDisplayConfiguration(
                name: "Virtual Display Camera",
                maxWidth: UInt32(resolution.width),
                maxHeight: UInt32(resolution.height),

                // The Retina-mode experiment gets a different monitor
                // identity, preventing a previously remembered 1x mode
                // from silently overriding the new settings.
                // Do not force mode switches after display creation.
                vendorID: 0x3456,
                productID: usesRetinaBacking ? 0x1235 : 0x1234,
                serialNumber: (UInt32(resolution.width) << 16) |
                    UInt32(resolution.height),

                hiDPIEnabled: usesRetinaBacking,
                refreshRate: CGFloat(resolution.refreshRate),
                displayModes: [
                    DisplayMode(
                        width: logicalWidth,
                        height: logicalHeight,
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
        captureGeneration += 1
        regionSelector.cancel()
        isSelectingRegion = false

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
        logAvailableDisplayModes(displayID)
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

    // Diagnostic only. Some macOS versions initially return an empty
    // list to the process that created a new virtual display.
    private func logAvailableDisplayModes(_ displayID: CGDirectDisplayID) {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil)
            as? [CGDisplayMode] else {
            print("[Bridge] Available CoreGraphics modes not readable yet")
            return
        }

        print("[Bridge] Available CoreGraphics modes (\(modes.count)):")
        for mode in modes.prefix(25) {
            print(
                "  - logical \(mode.width)x\(mode.height), " +
                "pixels \(mode.pixelWidth)x\(mode.pixelHeight), " +
                "\(mode.refreshRate)Hz"
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
        renderer.onFrameAvailable = { [weak self] surface in
            self?.publishFrame(surface)
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
        externalCapture?.stop()
        externalCapture = nil
        externalPreviewCapture?.stop()
        externalPreviewCapture = nil
        externalFilter = nil
        externalPreviewView.clear()
        externalSourceRect = nil
        externalCaptureWidth = 0
        externalCaptureHeight = 0
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

    // MARK: - External window / region capture

    private func startExternalCapture(generation: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard generation == captureGeneration, isRunning else { return }

            let settings = draftSettings
            let filter: SCContentFilter
            let width: Int
            let height: Int
            var sourceRect: CGRect?

            switch settings.sourceMode {
            case .virtualDisplay:
                return

            case .window:
                guard let window = content.windows.first(where: {
                    $0.windowID == selectedWindowID &&
                    $0.title == settings.windowTitle
                }) ?? content.windows.first(where: {
                    $0.title == settings.windowTitle &&
                    ($0.owningApplication?.bundleIdentifier ?? "") == settings.windowBundleID
                }) else {
                    throw CaptureStartError.sourceNotFound(
                        "The saved window is no longer available. Refresh and select it again."
                    )
                }

                filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                width = max(2, Int((filter.contentRect.width * scale).rounded()))
                height = max(2, Int((filter.contentRect.height * scale).rounded()))

            case .region:
                guard let choice = availableDisplays.first(where: {
                    $0.id == selectedDisplayID
                }) ?? availableDisplays.first(where: {
                    $0.name == settings.regionDisplayName
                }),
                let display = content.displays.first(where: {
                    $0.displayID == choice.id
                }),
                let rect = settings.regionRect,
                rect.width >= 16, rect.height >= 16 else {
                    throw CaptureStartError.sourceNotFound(
                        "Choose a display and drag a screen region first."
                    )
                }

                filter = SCContentFilter(
                    display: display,
                    excludingApplications: [],
                    exceptingWindows: []
                )

                // sourceRect is relative to the selected display in
                // top-left-origin screen points, not global Mac coordinates.
                let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                        .uint32Value == display.displayID
                })
                let pointWidth = screen?.frame.width ?? CGFloat(display.width)
                let pointHeight = screen?.frame.height ?? CGFloat(display.height)
                let clipped = rect.intersection(
                    CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight)
                )
                guard clipped.width >= 16, clipped.height >= 16 else {
                    throw CaptureStartError.sourceNotFound(
                        "The saved region no longer fits this display. Select it again."
                    )
                }

                let scaleX = CGFloat(display.width) / pointWidth
                let scaleY = CGFloat(display.height) / pointHeight
                sourceRect = clipped
                width = max(2, Int((clipped.width * scaleX).rounded()))
                height = max(2, Int((clipped.height * scaleY).rounded()))
            }

            externalFilter = filter
            externalSourceRect = sourceRect
            externalCaptureWidth = width
            externalCaptureHeight = height

            let session = ExternalCaptureSession()
            externalCapture = session
            try await session.start(
                filter: filter,
                width: width,
                height: height,
                sourceRect: sourceRect,
                showsCursor: settings.showCursorInSyphon,
                fpsCap: settings.outputFPSCap,
                onFrame: { [weak self] surface in
                    self?.publishFrame(surface)
                },
                onError: { [weak self] message in
                    guard let self, self.isRunning else { return }
                    self.stop()
                    self.captureError = "Capture stopped: \(message)"
                }
            )
            guard generation == captureGeneration, isRunning else {
                session.stop()
                return
            }
            captureConfigured = true
            print("[Bridge] External \(settings.sourceMode.rawValue) started: " +
                  "\(width)x\(height), FPS cap \(settings.outputFPSCap)")
        } catch {
            guard generation == captureGeneration else { return }
            stop()
            captureError = "Capture couldn't start: \(error.localizedDescription)"
            print("[Bridge] \(captureError ?? "")")
        }
    }

    private enum CaptureStartError: LocalizedError {
        case sourceNotFound(String)
        var errorDescription: String? {
            switch self {
            case .sourceNotFound(let message): return message
            }
        }
    }

    private func publishFrame(_ surface: IOSurface) {
        guard isRunning else { return }
        let cap = draftSettings.outputFPSCap
        let now = ProcessInfo.processInfo.systemUptime
        if cap > 0,
           lastPublishedUptime > 0,
           now - lastPublishedUptime < (1.0 / Double(cap) - 0.001) {
            return
        }
        guard publisher.publish(surface: surface) else { return }

        lastPublishedUptime = now
        frameCounter.record(
            width: IOSurfaceGetWidth(surface),
            height: IOSurfaceGetHeight(surface)
        )
        if draftSettings.sourceMode != .virtualDisplay &&
           draftSettings.showCursorInSyphon {
            externalPreviewView.show(surface: surface)
        }
    }

    // MARK: - Preview

    func showPreview() {
        if draftSettings.sourceMode != .virtualDisplay {
            showExternalPreview()
            return
        }
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

    private func showExternalPreview() {
        guard captureConfigured,
              let filter = externalFilter else { return }

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
            window.title = "Capture Preview"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            previewWindow = window
        }

        guard let window = previewWindow else { return }
        if externalCaptureHeight > 0 {
            window.contentAspectRatio = NSSize(
                width: externalCaptureWidth,
                height: externalCaptureHeight
            )
        }

        window.contentView = externalPreviewView
        updatePreviewWindowLevel()

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isPreviewVisible = true

        // The main output stream hides the pointer if the user disabled it.
        // A temporary preview-only stream makes the pointer visible without
        // modifying what the Syphon receiver sees.
        if !draftSettings.showCursorInSyphon,
           externalPreviewCapture == nil {
            let session = ExternalCaptureSession()
            externalPreviewCapture = session
            let width = externalCaptureWidth
            let height = externalCaptureHeight
            let sourceRect = externalSourceRect
            let generation = captureGeneration
            Task {
                do {
                    try await session.start(
                        filter: filter,
                        width: width,
                        height: height,
                        sourceRect: sourceRect,
                        showsCursor: true,
                        fpsCap: draftSettings.outputFPSCap,
                        onFrame: { [weak self] surface in
                            self?.externalPreviewView.show(surface: surface)
                        },
                        onError: { [weak self] message in
                            self?.captureError = "Preview stopped: \(message)"
                        }
                    )
                    if generation != captureGeneration ||
                       !isPreviewVisible {
                        session.stop()
                    }
                } catch {
                    guard generation == captureGeneration else { return }
                    captureError = "Preview could not start: \(error.localizedDescription)"
                    externalPreviewCapture = nil
                }
            }
        }
    }

    func hidePreview() {
        if let window = previewWindow {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        previewRenderer?.stopStream()
        previewRenderer = nil
        externalPreviewCapture?.stop()
        externalPreviewCapture = nil
        externalPreviewView.clear()
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
        externalPreviewCapture?.stop()
        externalPreviewCapture = nil
        externalPreviewView.clear()
        isPreviewVisible = false
    }
}
