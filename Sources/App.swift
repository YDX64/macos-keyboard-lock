import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Global shortcut (⌃⌥⌘L)

/// Registers the shortcut. Returns false if another app already owns it.
func registerGlobalHotKey() -> Bool {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        Task { @MainActor in Model.shared.toggle() }
        return noErr
    }, 1, &spec, nil, nil)
    guard handlerStatus == noErr else { return false }

    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x4B4B4C4B), id: 1)
    let status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey),
                                     id, GetApplicationEventTarget(), 0, &ref)
    return status == noErr
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var dock: DockController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Model.shared.start()
        Model.shared.hotKeyWorks = registerGlobalHotKey()
        statusBar = StatusBarController()
        dock = DockController()
    }

    /// The app keeps running in the menu bar when the window is closed (the lock stays on).
    /// Quit with the menu bar item or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MenuActions.shared.showWindow() }
        return true
    }

    /// Menu shown when right-clicking the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MenuActions.shared.buildMenu(includeQuit: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The lock is always released on quit.
        Model.shared.shutdown()
    }
}

// MARK: - App

struct KeyboardLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A single window: no second window with ⌘N.
        Window("Keyboard Lock", id: "main") {
            ContentView()
                .environmentObject(Model.shared)
        }
        .windowResizability(.contentSize)
    }
}
