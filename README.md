# Virtual Display Camera for macOS

A lightweight utility that adds a **virtual extended desktop** to macOS and publishes the screen as a live **Syphon source** for apps such as [ProPresenter](https://renewedvision.com/propresenter/).

**Downloads:** [Virtual Display Camera v1.0.1](../../releases/tag/v1.0.1) · **All versions:** [Releases](../../releases)

[![macOS source build](https://github.com/josiahshank16/VirtualDisplay-MacOS-/actions/workflows/build-macos.yml/badge.svg)](../../actions/workflows/build-macos.yml) [![v1.0.1 release audit](https://github.com/josiahshank16/VirtualDisplay-MacOS-/actions/workflows/verify-v1.0.1.yml/badge.svg)](../../actions/workflows/verify-v1.0.1.yml)

> **Source status:** The Swift files, icon, Xcode project, and locked package resolutions are included. An **unsigned Apple Silicon Release build from a fresh GitHub checkout passed** on [pull request #1](../../pull/1), and automated builds now run for source changes. This checks compilation, not physical Mac installation, macOS permissions, or notarization.

## What it does

- Creates a **1920 × 1080** virtual extended display at **60 Hz**.
- Publishes its live picture as the **VirtualDisplayCamera** Syphon source.
- Uses event-driven display capture: the number of capture updates depends on the content changing, not a forced fixed-rate video encoder.
- Offers an optional resizable **16:9 preview window** using the existing capture renderer.
- Shows display/capture status, capture updates per second, and total capture updates.
- Only starts a new virtual display after you click **Start Display**.
- Continues running if you close or minimize the controls window. Reopen it from the app's Dock menu (**Show Controls**).

## Download and install

**For Apple Silicon (arm64) Macs:** download [VirtualDisplayCamera.zip from v1.0.1](../../releases/download/v1.0.1/VirtualDisplayCamera.zip). It contains the compiled `.app`; you do not need Xcode or a separate Syphon installation.

1. Download and unzip `VirtualDisplayCamera.zip`.
2. Move `VirtualDisplayCamera.app` into **Applications**.
3. Open the app. Depending on the signing/notarization status, macOS may require you to approve it under **System Settings → Privacy & Security**.
4. Review any macOS **Screen & System Audio Recording** permission prompts, and reopen the app if asked.
5. Click **Start Display**. Use **System Settings → Displays** to place the virtual screen relative to the physical screen.
6. Move the desired app or video window onto the virtual display.
7. Select the **VirtualDisplayCamera** Syphon input in ProPresenter or another Syphon-compatible receiving app.
8. When finished, click **Stop Display**.

### Compatibility and limitations

- **Architecture:** The packaged Syphon framework currently targets **Apple Silicon (arm64)**. Intel support has not been built.
- **Minimum macOS:** The published **v1.0.1 ZIP has been independently inspected** on a GitHub-hosted Mac: the included executable reports **`minos 15.0`** and **`arm64`** architecture. This meets the OS-version requirement for Sequoia 15.5 and newer. Functional compatibility on each macOS version still needs device testing.
- **Private APIs:** VirtualDisplayKit uses undocumented macOS virtual-display interfaces; behavior may change with macOS updates.
- **Signing:** The published v1.0.1 ZIP passes local macOS **code-signature verification**. This does **not** demonstrate Apple notarization. Users may still have to approve installation in Privacy & Security.

To inspect a downloaded ZIP on macOS, run the bundled [release verification script](scripts/verify-release.sh):

```bash
bash scripts/verify-release.sh "/path/to/VirtualDisplayCamera.zip"
```

Or inspect the app executable directly:

```bash
xcrun vtool -show-build "/path/to/VirtualDisplayCamera.app/Contents/MacOS/VirtualDisplayCamera"
```

Look for `minos` (the supported minimum macOS version). The [published v1.0.1 audit](../../actions/workflows/verify-v1.0.1.yml) downloaded the actual release ZIP, verified its SHA-256, confirmed `minos 15.0`, found the embedded and linked Syphon framework, found `AppIcon` in the asset catalog, and verified its code signature. This is a packaging inspection, **not** a notarization check or live-display test.

## Build from source in Xcode

1. Click **Code → Download ZIP** from this repository's **main branch** and extract it, or clone the repository with Git. The older tagged `v1.0.1` source snapshot predates the cleanup of the unused extension; use main for the latest buildable source.
2. Open `VirtualDisplayCamera.xcodeproj` in Xcode on an Apple Silicon Mac.
3. Allow Xcode to resolve the two package dependencies. They are specified in the project and `Package.resolved`:
   - [VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit)
   - [Syphon-MacOS-SPM](https://github.com/josiahshank16/Syphon-MacOS-SPM) (binary Syphon XCFramework, version 1.0.0)
4. Choose the **VirtualDisplayCamera** application scheme and your Mac as the destination.
5. If Xcode asks about signing, choose an appropriate **Team** for local development or configure local build signing as required. The original developer's Personal Team selection is not portable to other accounts.
6. Check **TARGETS → VirtualDisplayCamera → Build Settings → macOS Deployment Target** and verify the value for Debug and Release.
7. Choose **Product → Build** or **Product → Run**. Confirm that the virtual screen appears and that a receiving application discovers the Syphon source.
8. To export a downloadable build, choose **Product → Archive**, export the app, and ZIP the resulting `.app` for GitHub Releases.

The obsolete Camera System Extension target was removed in [pull request #1](../../pull/1) so building the app no longer compiles or embeds that unused prototype. The main app target and project are both configured for macOS 15.0, but binary releases must still be checked independently.

## Architecture

```text
macOS extended desktop
       │
       ▼
VirtualDisplayKit (virtual CGDisplay)
       │
       ▼
CGDisplayStream → IOSurface frame
       │
       ▼
Shared Metal texture / SyphonMetalServer
       │
       ▼
Syphon-compatible receiver (e.g. ProPresenter)
       │
       ▼
Receiver-managed video outputs (such as Blackmagic SDI)
```

This project **does not** output directly to SDI or register a system webcam. ProPresenter is responsible for routing received content to its outputs.

## Troubleshooting

**This application requires a newer version of macOS:** Inspect the actual executable's `minos`; the source project's deployment setting alone is not proof of a compiled release's compatibility.

**The virtual display appears but the Syphon source does not:** Confirm capture has started, allow requested screen-recording permissions, and restart the receiving application. The working application is intentionally **not App Sandboxed**, since its Syphon publication needs interprocess communication.

**Capture updates are less than 60 per second:** Normal for still screens and lower-frame-rate video. Updates are event-driven.

**The Dock icon doesn't look right:** Check that `VirtualDisplayCamera/AppIcon.icon` is included in the app build and inspect a fresh export, not an older app icon manually changed through Finder.

## Third-party components and licensing

- [VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit)
- [Syphon Framework](https://github.com/Syphon/Syphon-Framework), distributed through [Syphon-MacOS-SPM](https://github.com/josiahshank16/Syphon-MacOS-SPM)
- The app icon incorporates Lucide's **monitor-dot** artwork.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and relevant license notices. **The original Virtual Display Camera source does not yet have a license selected**; public visibility alone does not make it freely reusable.
