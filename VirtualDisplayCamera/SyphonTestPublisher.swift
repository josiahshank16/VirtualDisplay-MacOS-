
import Foundation
import CoreGraphics
import IOSurface
import Metal
import Syphon

@MainActor
final class SyphonTestPublisher: NSObject {

    private var server: SyphonMetalServer?
    private var device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?

    func start() {
        guard server == nil else { return }

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            print("Metal initialization failed")
            return
        }

        self.device = device
        self.commandQueue = queue

        server = SyphonMetalServer(
            name: "VirtualDisplayCamera",
            device: device,
            options: nil
        )

        print(server != nil
              ? "Syphon server started"
              : "Syphon server failed")
    }

    func publish(surface: IOSurface) {
        guard let server,
              let device,
              let commandQueue
        else { return }

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)

        guard width > 0, height > 0 else { return }

        let descriptor =
            MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )

        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        ),
        let buffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        // Keep the source frame available until
        // Syphon finishes copying it on the GPU.
        IOSurfaceIncrementUseCount(surface)

        buffer.addCompletedHandler { [surface] _ in
            IOSurfaceDecrementUseCount(surface)
        }

        server.publishFrameTexture(
            texture,
            on: buffer,
            imageRegion: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            ),
            flipped: true
        )

        buffer.commit()
    }

    func stop() {
        server?.stop()
        server = nil
        commandQueue = nil
        device = nil
    }
}

