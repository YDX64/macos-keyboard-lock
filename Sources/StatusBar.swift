import SwiftUI
import AppKit
import Combine

// MARK: - Menu actions (shared by the menu bar item and the Dock menu)

@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func toggle() { Model.shared.toggle() }

    @objc func setDuration(_ sender: NSMenuItem) { Model.shared.setDuration(seconds: sender.tag) }

    @objc func uninstall() { Model.shared.confirmAndUninstall() }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Keyboard Lock" }?.makeKeyAndOrderFront(nil)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    /// Builds the menu for the current state.
    func buildMenu(includeQuit: Bool) -> NSMenu {
        let m = Model.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: m.statusLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if m.needsSetup || m.helperState == .unknown {
            menu.addItem(item(tr("menu.setup"), #selector(showWindow)))
        } else {
            let toggle = item(m.isLocked ? tr("menu.unlock") : tr("menu.lock"), #selector(toggle), key: "l")
            toggle.keyEquivalentModifierMask = [.control, .option, .command]
            toggle.isEnabled = !m.busy && !m.installing && (m.isLocked || m.canLock)
            menu.addItem(toggle)

            let sub = NSMenu()
            sub.autoenablesItems = false
            for d in LockDuration.allCases {
                let di = NSMenuItem(title: d.label, action: #selector(setDuration(_:)), keyEquivalent: "")
                di.target = self
                di.tag = d.rawValue
                di.state = d == m.duration ? .on : .off
                di.isEnabled = !m.isLocked
                sub.addItem(di)
            }
            let parent = NSMenuItem(title: tr("menu.autoUnlock"), action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        menu.addItem(item(tr("menu.showWindow"), #selector(showWindow)))
        if m.helperState == .ready && !m.isLocked && !m.installing {
            menu.addItem(item(tr("menu.uninstall"), #selector(uninstall)))
        }
        if includeQuit {
            menu.addItem(.separator())
            menu.addItem(item(tr("menu.quit"), #selector(quit), key: "q"))
        }
        return menu
    }
}

// MARK: - Menu bar item

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellable: AnyCancellable?
    private var pulseTimer: Timer?
    private var pulseHigh = true

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        cancellable = Model.shared.objectWillChange.sink { _ in
            Task { @MainActor in Self.current?.refresh() }
        }
        Self.current = self
        refresh()
    }

    /// The single status bar controller (the app creates exactly one).
    private static weak var current: StatusBarController?

    /// The menu is rebuilt from the current state every time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = MenuActions.shared.buildMenu(includeQuit: true)
        for it in fresh.items {
            fresh.removeItem(it)
            menu.addItem(it)
        }
    }

    private func refresh() {
        let m = Model.shared
        guard let button = statusItem.button else { return }

        let locked = m.isLocked
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if locked {
            let tint: NSColor = m.waitingForKeyboard ? .systemOrange : .systemRed
            config = config.applying(.init(paletteColors: [tint]))
        }
        let name = locked ? "lock.fill" : (m.needsSetup ? "lock.slash" : "lock.open")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Keyboard Lock")?
            .withSymbolConfiguration(config)
        image?.isTemplate = !locked   // colored while locked, otherwise follows the menu bar color
        button.image = image
        button.title = locked ? (m.remainingText.map { " " + $0 } ?? "") : ""
        button.toolTip = "Keyboard Lock · " + m.statusLine

        setPulse(active: locked)
    }

    /// While locked the icon fades in and out slowly, so the lock state is clear at a glance.
    private func setPulse(active: Bool) {
        if active {
            guard pulseTimer == nil else { return }
            let t = Timer(timeInterval: 0.9, repeats: true) { _ in
                Task { @MainActor in Self.current?.pulseStep() }
            }
            RunLoop.main.add(t, forMode: .common)
            pulseTimer = t
        } else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseHigh = true
            statusItem.button?.alphaValue = 1
        }
    }

    private func pulseStep() {
        pulseHigh.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            statusItem.button?.animator().alphaValue = pulseHigh ? 1 : 0.45
        }
    }
}

// MARK: - Dock icon (changes with the state, no animation)

enum IconRenderer {
    enum Look { case unlocked, locked, waiting, setup }

    private static func colors(_ look: Look) -> (NSColor, NSColor) {
        switch look {
        case .unlocked: return (NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1),
                                NSColor(red: 0.10, green: 0.62, blue: 0.30, alpha: 1))
        case .locked:   return (NSColor(red: 1.0, green: 0.36, blue: 0.30, alpha: 1),
                                NSColor(red: 0.80, green: 0.10, blue: 0.20, alpha: 1))
        case .waiting:  return (NSColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 1),
                                NSColor(red: 0.85, green: 0.45, blue: 0.05, alpha: 1))
        case .setup:    return (NSColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 1),
                                NSColor(red: 0.32, green: 0.36, blue: 0.44, alpha: 1))
        }
    }

    /// Status icon: green = unlocked, red = locked, orange = keyboard unplugged, gray = setup required.
    static func image(look: Look) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            let s = rect.width
            let base = rect.insetBy(dx: s * 0.06, dy: s * 0.06)
            let path = NSBezierPath(roundedRect: base, xRadius: s * 0.2, yRadius: s * 0.2)
            let (top, bottom) = colors(look)
            NSGradient(colors: [top, bottom])?.draw(in: path, angle: -90)

            let symbol: String
            switch look {
            case .unlocked: symbol = "lock.open.fill"
            case .setup: symbol = "lock.slash.fill"
            default: symbol = "lock.fill"
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let w = sym.size.width, h = sym.size.height
                sym.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
            }
            return true
        }
    }
}

/// The Dock icon only updates when the state changes; there is no animation or timer,
/// so it costs no CPU or battery.
@MainActor
final class DockController {
    private var cancellable: AnyCancellable?
    private var look: IconRenderer.Look?
    private var badge: String?

    init() {
        cancellable = Model.shared.objectWillChange.sink { _ in
            Task { @MainActor in Self.current?.refresh() }
        }
        Self.current = self
        refresh()
    }

    /// The single Dock controller (the app creates exactly one).
    private static weak var current: DockController?

    private func refresh() {
        let m = Model.shared
        let newLook: IconRenderer.Look
        if m.isLocked { newLook = m.waitingForKeyboard ? .waiting : .locked }
        else if m.needsSetup { newLook = .setup }
        else { newLook = .unlocked }

        if newLook != look {
            look = newLook
            NSApp.applicationIconImage = IconRenderer.image(look: newLook)
        }

        // Badge: remaining time of a timed lock (minute precision, so it does not change every second).
        var newBadge: String? = nil
        if m.isLocked {
            if let r = m.remaining { newBadge = r >= 90 ? tr("unit.minutes", Int32((r + 59) / 60)) : tr("unit.seconds", Int32(r)) }
            else { newBadge = "🔒" }
        }
        if newBadge != badge {
            badge = newBadge
            NSApp.dockTile.badgeLabel = newBadge
        }
    }
}
