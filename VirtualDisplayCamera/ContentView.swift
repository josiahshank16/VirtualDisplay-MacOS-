
import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var controller:
        DisplayBridgeController

    var body: some View {

        ScrollView {
            VStack(spacing: 15) {

                Image(systemName: "display")
                    .font(.system(size: 42))
                    .foregroundStyle(.blue)

                Text("Virtual Display Camera")
                    .font(.title2)
                    .bold()

                Label(
                    controller.displayConnected
                    ? "Display Connected"
                    : "Display Disconnected",
                    systemImage: controller.displayConnected
                    ? "checkmark.circle.fill"
                    : "circle.dashed"
                )
                .foregroundStyle(
                    controller.displayConnected
                    ? Color.green
                    : Color.secondary
                )

                HStack(spacing: 15) {

                    Button("Start Display") {
                        controller.start()
                    }
                    .disabled(controller.isRunning)

                    Button("Stop Display") {
                        controller.stop()
                    }
                    .disabled(!controller.isRunning)
                }

                Text("1920 × 1080 | 60 Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Label(
                    controller.captureConfigured
                    ? "Syphon Capture Active"
                    : "Syphon Capture Inactive",
                    systemImage: "video.fill"
                )
                .foregroundStyle(
                    controller.captureConfigured
                    ? Color.green
                    : Color.secondary
                )

                // MARK: - Performance

                VStack(spacing: 8) {

                    HStack {
                        Text("Capture Updates")
                        Spacer()
                        Text(
                            String(
                                format: "%.1f / sec",
                                controller.captureUpdatesPerSecond
                            )
                        )
                        .monospacedDigit()
                    }

                    HStack {
                        Text("Total Updates")
                        Spacer()
                        Text(
                            controller.capturedUpdatesTotal
                                .formatted()
                        )
                        .monospacedDigit()
                    }
                }
                .font(.subheadline)
                .padding(12)
                .background(.quaternary.opacity(0.25))
                .clipShape(
                    RoundedRectangle(cornerRadius: 10)
                )

                // MARK: - Preview

                Button {
                    if controller.isPreviewVisible {
                        controller.hidePreview()
                    } else {
                        controller.showPreview()
                    }
                } label: {
                    Label(
                        controller.isPreviewVisible
                        ? "Hide Preview"
                        : "Show Preview",
                        systemImage: controller.isPreviewVisible
                        ? "eye.slash"
                        : "eye"
                    )
                }
                .disabled(
                    !controller.captureConfigured &&
                    !controller.isPreviewVisible
                )

                Text("Preview is off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text(
                    "Closing or minimizing this window " +
                    "will not stop your virtual display."
                )
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            }
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .frame(
            minWidth: 360,
            maxWidth: .infinity,
            minHeight: 280,
            maxHeight: .infinity
        )
    }
}
