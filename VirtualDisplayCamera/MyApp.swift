
import SwiftUI
import AppKit

// MARK: - Application Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Keep the video system running independently
    // of the controls window.
    let controller = DisplayBridgeController()

    private var controlsWindow: NSWindow?

    // MARK: - Application Startup

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        showControlsWindow()
        print("[App] Virtual Display Camera launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        return false
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        controller.stop()
    }

    // MARK: - Dock Menu

    func applicationDockMenu(
        _ sender: NSApplication
    ) -> NSMenu? {

        let menu = NSMenu()

        let showItem = NSMenuItem(
            title: "Show Controls",
            action: #selector(openControls),
            keyEquivalent: ""
        )

        showItem.target = self
        menu.addItem(showItem)

        return menu
    }

    // MARK: - Dock Click Behavior

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {

        showControlsWindow()
        return false
    }

    // MARK: - Window Controls

    @objc private func openControls() {
        showControlsWindow()
    }

    private func showControlsWindow() {

        if let window = controlsWindow {

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ContentView()
            .environmentObject(controller)

        let hostingController = NSHostingController(
            rootView: view
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 420,
                height: 400
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable
            ],
            backing: .buffered,
            defer: false
        )

        window.title = "Virtual Display Camera"

        window.contentViewController = hostingController

        // Allow resizing, but prevent the window
        // from becoming too small to use.
        window.contentMinSize = NSSize(
            width: 360,
            height: 280
        )

        // Remember the window's position and size.
        window.setFrameAutosaveName(
            "VirtualDisplayCamera.ControlsWindow"
        )

        // Keep the window available after closing.
        window.isReleasedWhenClosed = false

        window.center()
        controlsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Main Application

@main
struct MyApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
