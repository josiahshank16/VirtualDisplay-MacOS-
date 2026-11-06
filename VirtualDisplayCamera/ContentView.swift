import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: DisplayBridgeController
    @State private var newProfileName = ""
    @State private var showingNewProfileAlert = false
    @State private var showingDeleteProfileAlert = false
    @State private var showDiagnostics = false

    private var selectedProfileName: String {
        controller.profiles.first(where: { $0.id == controller.selectedProfileID })?.name
            ?? "Choose Profile"
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
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

                GroupBox("Virtual Display") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Label(
                                controller.displayConnected
                                    ? "Display Connected"
                                    : (controller.isDisplayRequested
                                       ? "Connecting Display…" : "Display Disconnected"),
                                systemImage: controller.displayConnected
                                    ? "checkmark.circle.fill" : "display"
                            )
                            .foregroundStyle(
                                controller.displayConnected ? .green : .secondary
                            )
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Button("Connect Display") {
                                controller.connectDisplay()
                            }
                            .disabled(controller.isDisplayRequested)

                            Button("Disconnect Display") {
                                controller.disconnectDisplay()
                            }
                            .disabled(!controller.isDisplayRequested)

                            Spacer()
                        }

                        Picker(
                            "Display resolution",
                            selection: $controller.draftSettings.resolution
                        ) {
                            ForEach(DisplayResolution.allCases) { resolution in
                                Text(resolution.label).tag(resolution)
                            }
                        }
                        .disabled(controller.isDisplayRequested)

                        Text(
                            "The virtual monitor stays connected when the " +
                            "camera feed stops. Connect it first if you plan " +
                            "to capture a window or region on that monitor."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if controller.isDisplayRequested &&
                           controller.isActiveModeDifferentFromRequested {
                            Label(
                                "This display was connected at a different resolution. " +
                                "Reconnect to apply your new choice.",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Capture Source") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Source", selection: $controller.draftSettings.sourceMode) {
                            ForEach(CaptureSourceMode.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        }
                        .disabled(controller.isRunning)

                        if controller.draftSettings.sourceMode == .window {
                            HStack {
                                Picker(
                                    "Window",
                                    selection: Binding<CGWindowID>(
                                        get: { controller.selectedWindowID ?? 0 },
                                        set: { controller.selectWindow($0) }
                                    )
                                ) {
                                    Text("Select a window…").tag(CGWindowID(0))
                                    ForEach(controller.availableWindows) { choice in
                                        Text(choice.label).tag(choice.id)
                                    }
                                }
                                .disabled(controller.isRunning)
                                Button {
                                    controller.refreshAvailableSources()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .help("Refresh available application windows")
                                .disabled(controller.isRunning || controller.isRefreshingSources)
                            }

                            Text(
                                "Capture a selected application window, even " +
                                "when other windows overlap it. Some hidden, " +
                                "minimized, or protected windows may be unavailable."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if controller.draftSettings.sourceMode == .region {
                            HStack {
                                Picker(
                                    "Monitor",
                                    selection: Binding<CGDirectDisplayID>(
                                        get: { controller.selectedDisplayID ?? 0 },
                                        set: { controller.selectRegionDisplay($0) }
                                    )
                                ) {
                                    Text("Select a monitor…").tag(CGDirectDisplayID(0))
                                    ForEach(controller.availableDisplays) { choice in
                                        Text(choice.label).tag(choice.id)
                                    }
                                }
                                .disabled(controller.isRunning)

                                Button {
                                    controller.refreshAvailableSources()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .help("Refresh monitors")
                                .disabled(controller.isRunning || controller.isRefreshingSources)
                            }

                            HStack {
                                Button {
                                    controller.selectRegionWithMouse()
                                } label: {
                                    Label("Select Region…", systemImage: "crop")
                                }
                                .disabled(controller.isRunning ||
                                          controller.isSelectingRegion ||
                                          controller.selectedDisplayID == nil)

                                Text(controller.regionSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(
                                "Select a region on the chosen monitor. For a " +
                                "virtual display, a mirrored selection window " +
                                "opens on your physical monitor. Press Escape " +
                                "to cancel."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if controller.isRefreshingSources {
                            ProgressView("Finding available sources…")
                                .controlSize(.small)
                        }

                        if let error = controller.captureError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            controller.captureConfigured
                                ? "Syphon Camera Active"
                                : (controller.isRunning
                                   ? "Starting Camera…" : "Camera Stopped"),
                            systemImage: controller.captureConfigured
                                ? "checkmark.circle.fill" : "video"
                        )
                        .foregroundStyle(
                            controller.captureConfigured ? .green : .secondary
                        )

                        HStack(spacing: 8) {
                            Button("Start Camera") {
                                controller.start()
                            }
                            .disabled(controller.isRunning)

                            Button("Stop Camera") {
                                controller.stop()
                            }
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
                                !controller.isPreviewVisible &&
                                !(controller.draftSettings.sourceMode == .virtualDisplay &&
                                  controller.displayConnected)
                            )
                        }

                        Toggle(
                            "Keep preview on top",
                            isOn: $controller.draftSettings.floatingPreview
                        )

                        if showDiagnostics {
                            Divider()

                            if controller.draftSettings.sourceMode == .virtualDisplay {
                                diagnosticRow(
                                    "Requested display",
                                    controller.draftSettings.resolution.label
                                )
                                diagnosticRow(
                                    "Desktop points",
                                    controller.activeDisplayLogicalWidth > 0
                                    ? "\(controller.activeDisplayLogicalWidth) × \(controller.activeDisplayLogicalHeight)"
                                    : "—"
                                )
                                diagnosticRow(
                                    "Physical pixels",
                                    controller.activeDisplayPixelWidth > 0
                                    ? "\(controller.activeDisplayPixelWidth) × \(controller.activeDisplayPixelHeight)"
                                    : "—"
                                )
                            }
                            diagnosticRow(
                                "Syphon frame",
                                controller.submittedFrameWidth > 0
                                ? "\(controller.submittedFrameWidth) × \(controller.submittedFrameHeight)"
                                : "—"
                            )
                            diagnosticRow(
                                "Published / sec",
                                String(format: "%.1f", controller.captureUpdatesPerSecond)
                            )
                            diagnosticRow(
                                "Total frames",
                                controller.capturedUpdatesTotal.formatted()
                            )

                            if controller.isActiveModeDifferentFromRequested &&
                               controller.draftSettings.sourceMode == .virtualDisplay {
                                Label(
                                    "The virtual display mode does not match the requested resolution.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack {
                        Text("Camera Feed")
                        Spacer()
                        Button {
                            withAnimation {
                                showDiagnostics.toggle()
                            }
                        } label: {
                            Image(
                                systemName: showDiagnostics
                                    ? "chart.bar.fill" : "chart.bar"
                            )
                        }
                        .buttonStyle(.borderless)
                        .help(showDiagnostics ? "Hide activity details" : "Show activity details")
                        .accessibilityLabel(
                            showDiagnostics ? "Hide diagnostics" : "Show diagnostics"
                        )
                    }
                }

                GroupBox("Display and Output Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        if controller.draftSettings.sourceMode == .virtualDisplay &&
                           controller.draftSettings.resolution == .ultraHD8K {
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

                        Picker(
                            "Output FPS cap",
                            selection: $controller.draftSettings.outputFPSCap
                        ) {
                            Text("No additional cap").tag(0)
                            Text("15 fps").tag(15)
                            Text("24 fps").tag(24)
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                        Text(
                            "Caps limit maximum published frames, not minimum " +
                            "video smoothness. ScreenCaptureKit runs at up to " +
                            "60 fps when no cap is selected."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                            "FPS, cursor and Syphon name changes apply when " +
                            "you next start the camera. Display resolution " +
                            "changes require disconnecting the virtual display."
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
        .onAppear {
            controller.refreshAvailableSources()
        }
        .onChange(of: controller.draftSettings.sourceMode) { _, newMode in
            if newMode != .virtualDisplay {
                controller.refreshAvailableSources()
            }
        }
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
