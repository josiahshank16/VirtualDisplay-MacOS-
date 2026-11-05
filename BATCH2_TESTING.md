# Batch 2.1 – Display/Camera separation and capture cleanup

This is a development test branch. It is not yet merged into `main`.

## Setup

1. Quit all other VirtualDisplayCamera instances.
2. Download the ZIP for `feature/batch2-window-region-fps-20261104` and unzip.
3. Open **VirtualDisplayCamera.xcodeproj** from the extracted folder and run in Xcode.
4. If macOS requests **Screen & System Audio Recording**, approve and restart the app.

## First verify independent display / camera operation

1. With Source set to **Virtual Display**, choose 1920 × 1080 or 3840 × 2160.
2. Click **Connect Display**. The status should say **Display Connected**, while **Camera Stopped** remains visible.
3. Click **Show Preview**. You should be able to preview the desktop while the camera is stopped.
4. Click **Start Camera**. Check that ProPresenter sees the same Syphon source as before.
5. Click **Stop Camera**. The second monitor should REMAIN in macOS Displays settings.
6. Click **Disconnect Display**. The second monitor should disappear. Changing resolution is only possible while disconnected.

## Window capture

1. In Source, select **Application Window**, refresh the dropdown.
2. Verify desktop Backstop and Underbelly helper windows are absent.
3. Choose an ordinary visible app window, Start Camera, Show Preview.
4. Check there is no extra white / padded band along the bottom.
5. Move or cover the window and verify the feed remains selected (some minimized or protected windows may not capture).

## Region capture from a physical monitor

1. Stop Camera and choose **Screen Region**.
2. Pick a physical monitor, Select Region, drag a rectangle, then Start Camera.
3. Content should reflect only the selected rectangle.

## Region capture from a virtual monitor

1. Stop Camera, **Connect Display**. Do NOT start the camera yet.
2. Switch Source to **Screen Region**, refresh the monitor list and choose **Virtual Display Camera**.
3. Click **Select Region**. A live mirror of the virtual desktop should open **on your physical monitor**.
4. Drag a rectangle in that mirrored view and close the selector. The coordinates are mapped back into virtual-display points.
5. Click **Start Camera** and confirm the crop appears in ProPresenter.
6. Stop Camera; the virtual display stays available, so you can select another crop without recreating it.

## FPS and diagnostics

- Use **Output FPS cap** to try 15, 24 and 30 fps with moving content; event-driven updates may be less than the cap.
- The ordinary Camera Feed box is compact. Click the **chart** icon in its upper right to reveal requested/active resolutions, Syphon frame size, update rate and totals.
- Source, profile and FPS settings are editable while the feed is stopped. Changing the virtual-display resolution additionally requires disconnecting the virtual monitor.
- Previous saved profiles should still decode and load.

## Notes

- A protected/minimized window may still be unavailable to ScreenCaptureKit. These features do not bypass protected content restrictions.
- Physical Mac and ProPresenter testing is necessary; a successful automated compile only confirms code builds.
