import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: DisplayBridgeController
    @State private var newProfileName = ""
    @State private var showingNewProfileAlert = false
    @State private var showingDeleteProfileAlert = false

    private var selectedProfileName: String {
        controller.profiles.first(where: { $0.id == controller.selectedProfileID })?.name
            ?? "Choose Profile"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {

                // Compact dropdown, always at the top of the controls.
                HStack(spacing: 8) {
                    Menu {
                        ForEach(controller.profiles) { profile in
                            Button {
                                controller.loadProfile(profile.id)
                            } label: {
                                if profile.id == controller.selectedProfileID {
                                    Label(profile.name, systemImage: "checkmark")
                                } else {
                                    Text(profile.name)
                                }
                            }
                            .disabled(controller.isRunning)
                        }

                        Divider()

                        Button("Save Changes to Current Profile") {
                            controller.updateSelectedProfile()
                        }
                        .disabled(
                            controller.isRunning ||
                            !controller.hasUnsavedChanges
                        )

                        Button("Delete Current Profile…") {
                            showingDeleteProfileAlert = true
                        }
                        .disabled(
                            controller.isRunning ||
                            controller.profiles.count <= 1
                        )

                        Divider()

                        Button {
                            newProfileName = ""
                            showingNewProfileAlert = true
                        } label: {
                            Label("Add New Profile…", systemImage: "plus")
                        }
                        .disabled(controller.isRunning)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "square.stack.3d.up")
                            Text(selectedProfileName)
                                .lineLimit(1)
                            if controller.hasUnsavedChanges {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.orange)
                                    .help("Settings differ from the saved profile")
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)

                    if controller.hasUnsavedChanges {
                        Text("Unsaved")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "display")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Virtual Display Camera")
                            .font(.title2).bold()
                        Text("Syphon capture and display controls")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox("Live Capture") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(
                                controller.displayConnected
                                    ? "Display Connected" : "Display Disconnected",
                                systemImage: controller.displayConnected
                                    ? "checkmark.circle.fill" : "circle.dashed"
                            )
                            .foregroundStyle(
                                controller.displayConnected ? .green : .secondary
                            )
                            Spacer()
                            Text(
                                "\(controller.draftSettings.resolution.label) @ " +
                                "\(controller.draftSettings.resolution.refreshRate) Hz"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        // Preview now lives beside Start/Stop.
                        HStack(spacing: 8) {
                            Button("Start Display") { controller.start() }
                                .disabled(controller.isRunning)

                            Button("Stop Display") { controller.stop() }
                                .disabled(!controller.isRunning)

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
                        }

                        Toggle(
                            "Keep preview on top",
                            isOn: $controller.draftSettings.floatingPreview
                        )

                        Divider()

                        Label(
                            controller.captureConfigured
                                ? "Capture Configured" : "Capture Inactive",
                            systemImage: "video.fill"
                        )
                        .foregroundStyle(
                            controller.captureConfigured ? .green : .secondary
                        )

                        HStack {
                            Text("Frame submitted to Syphon")
                            Spacer()
                            if controller.submittedFrameWidth > 0 &&
                               controller.submittedFrameHeight > 0 {
                                Text(
                                    "\(controller.submittedFrameWidth) × " +
                                    "\(controller.submittedFrameHeight)"
                                )
                                .monospacedDigit()
                                .fontWeight(.semibold)
                            } else {
                                Text("Waiting for frame")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Text("Submitted frames / sec")
                            Spacer()
                            Text(
                                String(
                                    format: "%.1f",
                                    controller.captureUpdatesPerSecond
                                )
                            )
                            .monospacedDigit()
                        }

                        HStack {
                            Text("Total submitted frames")
                            Spacer()
                            Text(controller.capturedUpdatesTotal.formatted())
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)

                        Text(
                            "These dimensions come from a frame actually " +
                            "submitted to Syphon, not the resolution " +
                            "selector or scaled preview."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Display and Output Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(
                            "Virtual resolution",
                            selection: $controller.draftSettings.resolution
                        ) {
                            ForEach(DisplayResolution.allCases) { resolution in
                                Text(resolution.label).tag(resolution)
                            }
                        }

                        if controller.draftSettings.resolution == .ultraHD8K {
                            Label(
                                "8K is an experimental 30 Hz mode. It may " +
                                "be slow or unavailable on some Macs. " +
                                "Test with a smaller mode first.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Toggle(
                            "Show cursor in Syphon output",
                            isOn: $controller.draftSettings.showCursorInSyphon
                        )

                        Text(
                            "The preview always shows the cursor. When " +
                            "Syphon hides it, a separate preview-only " +
                            "capture runs while the preview is open."
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
                            "Resolution, cursor and source-name changes " +
                            "apply when you next start the display. " +
                            "Save them through the profile dropdown."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .disabled(controller.isRunning)
                }

                Text(
                    "Closing or minimizing controls does not stop the " +
                    "virtual display. Reopen them from the Dock."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .frame(minWidth: 440, minHeight: 400)
        .alert("Add New Profile", isPresented: $showingNewProfileAlert) {
            TextField("Profile name", text: $newProfileName)
            Button("Cancel", role: .cancel) {}
            Button("Save Profile") {
                controller.createProfile(named: newProfileName)
                newProfileName = ""
            }
        } message: {
            Text("Save the current display and output settings as a new profile.")
        }
        .alert("Delete Current Profile?", isPresented: $showingDeleteProfileAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                controller.deleteSelectedProfile()
            }
        } message: {
            Text("This deletes the selected profile from the app.")
        }
    }
}
