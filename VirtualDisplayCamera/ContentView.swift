import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: DisplayBridgeController
    @State private var newProfileName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "display")
                        .font(.system(size: 34))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Virtual Display Camera")
                            .font(.title2).bold()
                        Text("Syphon capture and display controls")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            controller.displayConnected
                                ? "Display Connected" : "Display Disconnected",
                            systemImage: controller.displayConnected
                                ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .foregroundStyle(
                            controller.displayConnected ? .green : .secondary
                        )

                        HStack {
                            Button("Start Display") { controller.start() }
                                .disabled(controller.isRunning)
                            Button("Stop Display") { controller.stop() }
                                .disabled(!controller.isRunning)
                            Spacer()
                            Text("\(controller.draftSettings.resolution.label)  ·  60 Hz")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Label(
                            controller.captureConfigured
                                ? "Syphon Capture Active"
                                : "Syphon Capture Inactive",
                            systemImage: "video.fill"
                        )
                        .foregroundStyle(
                            controller.captureConfigured ? .green : .secondary
                        )

                        HStack {
                            Text("Capture updates")
                            Spacer()
                            Text(String(
                                format: "%.1f / sec",
                                controller.captureUpdatesPerSecond
                            )).monospacedDigit()
                        }
                        HStack {
                            Text("Total updates")
                            Spacer()
                            Text(controller.capturedUpdatesTotal.formatted())
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Saved Profiles") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(
                            "Current profile",
                            selection: Binding(
                                get: { controller.selectedProfileID },
                                set: { controller.loadProfile($0) }
                            )
                        ) {
                            ForEach(controller.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .disabled(controller.isRunning)

                        if controller.hasUnsavedChanges {
                            Label(
                                "Unsaved settings changes",
                                systemImage: "pencil.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }

                        HStack {
                            Button("Update Profile") {
                                controller.updateSelectedProfile()
                            }
                            .disabled(
                                controller.isRunning ||
                                !controller.hasUnsavedChanges
                            )
                            Button("Delete Profile", role: .destructive) {
                                controller.deleteSelectedProfile()
                            }
                            .disabled(
                                controller.isRunning ||
                                controller.profiles.count <= 1
                            )
                            Spacer()
                        }

                        Divider()

                        HStack {
                            TextField(
                                "New profile name",
                                text: $newProfileName
                            )
                            Button("Save as New") {
                                controller.createProfile(named: newProfileName)
                                newProfileName = ""
                            }
                            .disabled(
                                controller.isRunning ||
                                newProfileName.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Display and Output Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(
                            "Virtual resolution",
                            selection: $controller.draftSettings.resolution
                        ) {
                            ForEach(DisplayResolution.allCases) { res in
                                Text(res.label).tag(res)
                            }
                        }

                        Toggle(
                            "Show cursor in Syphon output",
                            isOn: $controller.draftSettings.showCursorInSyphon
                        )

                        Text(
                            "Preview always shows the cursor. When the " +
                            "Syphon cursor is hidden, opening the preview " +
                            "uses a separate preview-only capture stream."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        HStack {
                            Text("Syphon source name")
                            TextField(
                                "VirtualDisplayCamera",
                                text: $controller.draftSettings.syphonName
                            )
                            .textFieldStyle(.roundedBorder)
                        }

                        Text(
                            "Resolution, cursor, and source-name changes " +
                            "apply the next time you start the display."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .disabled(controller.isRunning)
                }

                GroupBox("Preview") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button {
                                if controller.isPreviewVisible {
                                    controller.hidePreview()
                                } else {
                                    controller.showPreview()
                                }
                            } label: {
                                Label(
                                    controller.isPreviewVisible
                                        ? "Hide Preview" : "Show Preview",
                                    systemImage: controller.isPreviewVisible
                                        ? "eye.slash" : "eye"
                                )
                            }
                            .disabled(
                                !controller.captureConfigured &&
                                !controller.isPreviewVisible
                            )
                            Spacer()
                            Text("Off by default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle(
                            "Keep preview on top",
                            isOn: $controller.draftSettings.floatingPreview
                        )
                        Text("The preview is view-only; it does not forward mouse clicks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                Text(
                    "Closing or minimizing the controls window " +
                    "does not stop the virtual display. " +
                    "Reopen controls from the Dock."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .frame(minWidth: 440, minHeight: 450)
    }
}
