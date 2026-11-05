import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit

enum CaptureSourceMode: String, Codable, CaseIterable, Identifiable {
    case virtualDisplay = "Virtual Display"
    case window = "Application Window"
    case region = "Screen Region"

    var id: String { rawValue }
}

struct CaptureWindowChoice: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let bundleIdentifier: String

    var label: String {
        "\(applicationName) — \(title)"
    }
}

struct CaptureDisplayChoice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int

    var label: String {
        "\(name) (\(width) × \(height))"
    }
}

// Handles ScreenCaptureKit outside the existing virtual-display pipeline.
// Each instance owns exactly one SCStream. Preview-only capture can therefore
// be turned on/off without disrupting the Syphon publishing stream.
@MainActor
final class ExternalCaptureSession {
    private var stream: SCStream?
    private var receiver: ExternalFrameReceiver?
    private(set) var isStarted = false

    func start(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        sourceRect: CGRect? = nil,
        showsCursor: Bool,
        fpsCap: Int,
        onFrame: @escaping (IOSurface) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        guard stream == nil else { return }

        let config = SCStreamConfiguration()
        config.width = max(2, width)
        config.height = max(2, height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.capturesAudio = false
        config.queueDepth = 3
        // The receiver is allowed up to 60fps if no cap is selected.
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: Int32(fpsCap == 0 ? 60 : fpsCap)
        )
        if let sourceRect {
            config.sourceRect = sourceRect
        }

        let output = ExternalFrameReceiver(onFrame: onFrame, onError: onError)
        let capture = SCStream(
            filter: filter,
            configuration: config,
            delegate: output
        )
        try capture.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "VDC.ScreenCaptureKit.video")
        )

        stream = capture
        receiver = output

        do {
            try await capture.startCapture()
            guard stream === capture else {
                try? await capture.stopCapture()
                return
            }
            isStarted = true
        } catch {
            if stream === capture {
                stream = nil
                receiver = nil
            }
            throw error
        }
    }

    func stop() {
        let previous = stream
        stream = nil
        receiver = nil
        isStarted = false

        if let previous {
            Task {
                try? await previous.stopCapture()
            }
        }
    }
}

// The sample callback runs on ScreenCaptureKit's serial queue. Retain the
// CVPixelBuffer until main-actor publication has completed, so the IOSurface
// cannot be recycled before our Metal/Syphon publisher takes ownership.
private final class ExternalFrameReceiver:
    NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    @MainActor private let onFrame: (IOSurface) -> Void
    @MainActor private let onError: (String) -> Void

    @MainActor init(
        onFrame: @escaping (IOSurface) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.onFrame = onFrame
        self.onError = onError
        super.init()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue),
              status == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(buffer)?
                  .takeUnretainedValue()
        else { return }

        // Capture 'buffer' deliberately to extend the underlying IOSurface
        // lifetime across the hop to the main thread.
        Task { @MainActor [buffer, surface] in
            self.onFrame(surface)
            withExtendedLifetime(buffer) {}
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.onError(message)
        }
    }
}

@MainActor
final class SurfacePreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show(surface: IOSurface) {
        layer?.contents = surface
    }

    func clear() {
        layer?.contents = nil
    }
}
