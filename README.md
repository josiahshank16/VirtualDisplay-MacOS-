# Virtual Display Camera for macOS

Create an extra **virtual macOS display** and make its picture available to [Syphon](https://syphon.github.io/)-compatible apps, including [ProPresenter](https://renewedvision.com/propresenter/).

**Project status:** The macOS app has been built and used successfully, but its original Xcode project and downloadable release are still being uploaded to this repository. Until those files appear, this repository is not a complete source or binary distribution.

## Features

- Creates a **1920 × 1080 virtual extended desktop** configured for **60 Hz**.
- Shares frames under the Syphon source name **VirtualDisplayCamera**.
- Uses an **event-driven** display capture path: it publishes frame updates when the display changes rather than fabricating duplicate frames.
- Offers an optional resizable **16:9 preview window**.
- Shows display/capture status, capture updates per second, and total captured frame updates.
- Starts the display **manually**, when **Start Display** is clicked.
- Keeps streaming when the controls window is minimized or closed; reopen the controls from the Dock menu (**Show Controls**).

## How it works

```text
macOS extended desktop
        │
        ▼
VirtualDisplayKit (virtual macOS display)
        │
        ▼
CGDisplayStream / IOSurface
        │
        ▼
Metal texture → SyphonMetalServer
        │
        ▼
ProPresenter or another Syphon-compatible receiver
```

The app uses [VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit) to create and capture a virtual display, and [Syphon](https://github.com/Syphon/Syphon-Framework) to share captured frames to other apps. It avoids needing a physical video cable or capture card between the virtual display and the receiving app. It does **not** register as a system webcam or output directly to Blackmagic hardware; any downstream SDI routing happens in the receiving app.

## Download and install

Once a compiled version is published, find the `.app` ZIP under [GitHub Releases](../../releases).

1. Download the ZIP for your Mac and unzip it.
2. Move **VirtualDisplayCamera.app** into **Applications**.
3. Launch the app. Depending on the signing/notarization of the release, macOS may require you to approve opening it under **System Settings → Privacy & Security**.
4. If macOS requests screen-recording permissions, review and grant access for this app, then reopen it if prompted.
5. Click **Start Display**, and use **System Settings → Displays** to arrange the extra display.
6. Move a window onto the virtual monitor.
7. In ProPresenter (or a compatible receiving app), choose the **VirtualDisplayCamera** Syphon source.
8. Click **Stop Display** when finished.

**Compatibility:** The current build process is aimed at **Apple Silicon (arm64)** Macs. The Syphon framework package supports macOS 14.0+, but the **minimum macOS version of the final app** is determined by the exported app's own deployment target. The earlier inspected release candidate had a **15.6 minimum**; the intention for the next release is **macOS 15.0**. Check each release's stated minimum version before downloading.

Because the virtual-display implementation relies on an **undocumented macOS API**, compatibility with every macOS version cannot be guaranteed.

### Check an exported app's macOS minimum

On a Mac with Xcode's command-line developer tools:

```bash
xcrun vtool -show-build "/path/to/VirtualDisplayCamera.app/Contents/MacOS/VirtualDisplayCamera"
```

Look for `minos`. The Mac running it must have that version or newer.

## Build from source

> The original Xcode project is being uploaded separately.

1. Open `VirtualDisplayCamera.xcodeproj` in Xcode on an Apple Silicon Mac.
2. Allow Xcode to resolve its Swift package dependencies:
   - [VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit)
   - [Syphon-MacOS-SPM](https://github.com/josiahshank16/Syphon-MacOS-SPM) (binary Syphon XCFramework)
3. Check **TARGETS → VirtualDisplayCamera → General** to confirm the **Syphon** product is linked and embedded with the app. Do not link an additional locally stored Syphon.framework.
4. Check **Build Settings → macOS Deployment Target** for both Debug and Release.
5. Run the project from Xcode. Verify the virtual display appears and that ProPresenter can see its Syphon source.
6. To distribute, use **Product → Archive**, then export using Xcode's distribution options.

The Xcode project must contain its Swift source files, `.xcodeproj` configuration, and assets (including the custom app icon). A downloaded GitHub **source ZIP** is not the finished app; use a release asset for the compiled program.

## Troubleshooting

**The app refuses to open on an older Mac:** Check the built application's `minos` with the command above, not just the project settings. Re-archive after lowering the deployment target.

**The extra display appears, but the Syphon feed does not:** Check macOS screen-recording permissions, confirm the virtual display capture is running, and restart the receiving app if necessary. The working app is **not sandboxed**, because Syphon requires interprocess communication.

**Capture updates per second are lower than 60:** This is normal with a static desktop or lower-frame-rate content. Frame updates are event-driven.

**The Dock icon is missing or outdated:** Confirm the custom app icon asset is included in the target and inspect a *freshly exported* app, rather than one that was manually modified in Finder.

## License and acknowledgements

This repository uses the following independently maintained components:

- [VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit)
- [Syphon Framework](https://github.com/Syphon/Syphon-Framework), distributed in this project through [Syphon-MacOS-SPM](https://github.com/josiahshank16/Syphon-MacOS-SPM)

Their licensing terms apply to those components. **No license has yet been selected for the original VirtualDisplayCamera source code**; a public GitHub repository is not automatically open-source licensed.
