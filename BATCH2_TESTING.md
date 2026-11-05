# Batch 2 macOS test plan

Batch 2 adds ScreenCaptureKit capture modes and output FPS caps, and is **not** merged or released.

## Launch

1. Quit any prior VirtualDisplayCamera process.
2. Download the Batch 2 branch ZIP, unzip and open `VirtualDisplayCamera.xcodeproj`.
3. Run the application from Xcode. If macOS requests Screen Recording permission, allow it in **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit/relaunch.
4. Keep ProPresenter ready with the existing Syphon input. Leave the Syphon source name unchanged while comparing modes.

## Tests

1. **Original virtual display:** Select Virtual Display, 1920 × 1080, Start Capture. Check preview and Syphon feed. Repeat with 3840 × 2160 to ensure Batch 1 HiDPI is intact.
2. **Window:** Stop. Select Application Window, refresh the list, choose a visible standard app window, Start Capture, Show Preview. Check content appears in ProPresenter. Cover or move the selected window; the output should remain focused on it. Some protected/minimized windows may be unavailable.
3. **Region:** Stop. Select Screen Region, select the correct monitor, click Select Region, drag a rectangular box across your desired area. Return to controls and Start Capture. Move content inside/outside that fixed area.
4. **Pointer:** With either external mode stopped, turn off Show cursor in Syphon output; restart, open preview. The feed should be pointer-free while preview remains useful with a cursor. This uses a separate preview-only stream when needed.
5. **FPS:** Set cap to 15 then 30 with animated content. The submitted-frames/sec counter should be at or below the chosen cap, often lower when content isn't changing. No additional cap still limits ScreenCaptureKit requests to 60fps.
6. **Profiles:** Stop, save an external capture mode and an FPS choice in a named profile. Quit and reopen; choose the profile. Window profiles match the original app and window title when available. Region profiles store the monitor name and selection rectangle.

## Diagnostics

- The controls report **Frame submitted to Syphon** and **Submitted frames / sec**.
- For a frozen or missing frame, copy the Xcode console around `[Bridge]` and any ScreenCaptureKit error, along with the selected mode.
- ScreenCaptureKit generally does not capture protected video. The app does not modify macOS security settings or bypass content protections.

The published v1.0.1 release and the `main` branch are not modified by these test changes.
