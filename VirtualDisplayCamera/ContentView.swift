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
                                "Draw a rectangle directly on the monitor. " +
                                "Press Escape to cancel. The region captures " +
                                "the pixels beneath it, including overlapping windows."
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

                GroupBox("Live Capture") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(
                                controller.captureConfigured
                                    ? "Capture Active"
                                    : (controller.isRunning ? "Starting Capture…" : "Capture Stopped"),
                                systemImage: controller.captureConfigured
                                    ? "checkmark.circle.fill" : "circle.dashed"
                            )
                            .foregroundStyle(
                                controller.captureConfigured ? .green : .secondary
                            )
                            Spacer()
                            if controller.draftSettings.sourceMode == .virtualDisplay {
                                Text(
                                    "\(controller.draftSettings.resolution.label) @ " +
                                    "\(controller.draftSettings.resolution.refreshRate) Hz"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }

                        // Preview now lives beside Start/Stop.
                        HStack(spacing: 8) {
                            Button("Start Capture") { controller.start() }
                                .disabled(controller.isRunning)

                            Button("Stop Capture") { controller.stop() }
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

                        if controller.draftSettings.sourceMode == .virtualDisplay {
                        HStack {
                            Text("Requested display")
                            Spacer()
                            Text(controller.draftSettings.resolution.label)
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Desktop coordinates (points)")
                            Spacer()
                            if controller.activeDisplayLogicalWidth > 0 &&
                               controller.activeDisplayLogicalHeight > 0 {
                                Text(
                                    "\(controller.activeDisplayLogicalWidth) × " +
                                    "\(controller.activeDisplayLogicalHeight)"
                                )
                                .monospacedDigit()
                            } else {
                                Text("Waiting for mode")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Text("Active mode (physical pixels)")
                            Spacer()
                            if controller.activeDisplayPixelWidth > 0 &&
                               controller.activeDisplayPixelHeight > 0 {
                                Text(
                                    "\(controller.activeDisplayPixelWidth) × " +
                                    "\(controller.activeDisplayPixelHeight)"
                                )
                                .monospacedDigit()
                                .fontWeight(.semibold)
                            } else {
                                Text("Waiting for mode")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if controller.isActiveModeDifferentFromRequested {
                            Label(
                                "macOS activated a different physical resolution. " +
                                "Check the available modes in Displays settings.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        }

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

                        if controller.submittedFrameWidth > 0 &&
                           controller.activeDisplayPixelWidth > 0 &&
                           (controller.submittedFrameWidth != controller.activeDisplayPixelWidth ||
                            controller.submittedFrameHeight != controller.activeDisplayPixelHeight) {
                            Label(
                                "Capture frame dimensions differ from the active " +
                                "display mode. This points to capture scaling.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
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
                            "Compare requested, active display, and " +
                            "submitted frame sizes to locate a resolution cap."
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
                        if controller.draftSettings.sourceMode == .virtualDisplay {
                            Picker(
                                "Virtual resolution",
                                selection: $controller.draftSettings.resolution
                            ) {
                                ForEach(DisplayResolution.allCases) { resolution in
                                    Text(resolution.label).tag(resolution)
                                }
                            }
                        }

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
                            "Source, resolution, FPS cap, cursor and " +
                            "source-name settings apply at the next capture " +
                            "start. Save settings through the profile dropdown."
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
