import Foundation
import IOKit
import IOKit.hid

// MARK: - IOReturn codes (defined by hand because the C macros are not imported into Swift)

enum IOErr {
    static let notPrivileged: UInt32 = 0xe00002c1
    static let exclusiveAccess: UInt32 = 0xe00002c5
    static let notPermitted: UInt32 = 0xe00002e2
}

// MARK: - Keyboard info

struct KeyboardInfo: Identifiable, Hashable {
    let vid: Int
    let pid: Int
    let name: String
    let transport: String
    let builtIn: Bool

    var id: String { "\(vid):\(pid)" }

    var detail: String {
        if builtIn { return tr("kb.builtIn") }
        switch transport {
        case "USB": return tr("kb.usb")
        case "Bluetooth", "BluetoothLowEnergy": return tr("kb.bluetooth")
        default: return transport.isEmpty ? tr("kb.external") : tr("kb.externalVia", transport)
        }
    }
}

// MARK: - HID property reading helpers

func hidInt(_ d: IOHIDDevice, _ key: String) -> Int? {
    (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue
}

func hidString(_ d: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(d, key as CFString) as? String
}

func keyboardID(_ d: IOHIDDevice) -> String? {
    guard let v = hidInt(d, kIOHIDVendorIDKey), let p = hidInt(d, kIOHIDProductIDKey) else { return nil }
    return "\(v):\(p)"
}

/// Identifies the built-in (MacBook) keyboard. The built-in keyboard is never locked.
func isBuiltInKeyboard(_ d: IOHIDDevice) -> Bool {
    if let b = IOHIDDeviceGetProperty(d, "Built-In" as CFString) as? NSNumber, b.boolValue { return true }
    let transport = hidString(d, kIOHIDTransportKey) ?? ""
    if transport == "SPI" || transport == "FIFO" { return true }
    let name = (hidString(d, kIOHIDProductKey) ?? "").lowercased()
    return name.contains("internal")
}

/// Is this an interface whose primary usage is "keyboard"? (Usage Page 1, Usage 6)
func isPrimaryKeyboard(_ d: IOHIDDevice) -> Bool {
    hidInt(d, kIOHIDPrimaryUsagePageKey) == 0x01 && hidInt(d, kIOHIDPrimaryUsageKey) == 0x06
}

/// Is this interface really a keyboard key interface?
/// - Always yes if its primary usage is keyboard (1,6) or keypad (1,7).
/// - For the media (12,1) and system keys (1,128) interfaces, no if the same interface also
///   carries a mouse/pointer/touch device: don't lock the mouse too on 2.4 GHz keyboard+mouse sets.
func isKeyInterface(_ d: IOHIDDevice) -> Bool {
    guard let page = hidInt(d, kIOHIDPrimaryUsagePageKey), let usage = hidInt(d, kIOHIDPrimaryUsageKey) else {
        return false
    }
    if page == 0x01 && (usage == 0x06 || usage == 0x07) { return true }
    guard (page == 0x0C && usage == 0x01) || (page == 0x01 && usage == 0x80) else { return false }

    if let pairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
        for pair in pairs {
            let pg = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue
            let us = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
            if pg == 0x01 && (us == 0x01 || us == 0x02) { return false } // pointer / mouse
            if pg == 0x0D { return false }                                 // touch
        }
    }
    return true
}

// MARK: - Device watcher

/// Watches all HID interfaces that carry a keyboard's key events:
/// keyboard (1,6), keypad (1,7), media keys (12,1), system keys (1,128).
/// Vendor-specific (lighting/macro) interfaces are deliberately left out,
/// so RGB lighting and software settings are not affected.
final class DeviceWatcher {
    let manager: IOHIDManager
    var onAdd: ((IOHIDDevice) -> Void)?
    var onRemove: ((IOHIDDevice) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let pairs: [(Int, Int)] = [(0x01, 0x06), (0x01, 0x07), (0x0C, 0x01), (0x01, 0x80)]
        let matching = pairs.map {
            [kIOHIDDeviceUsagePageKey: $0.0, kIOHIDDeviceUsageKey: $0.1] as CFDictionary
        } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)
    }

    /// Registers the callbacks and adds the manager to the main run loop. Does NOT open the manager:
    /// opening it opens the devices in normal mode and can prevent seizing them later.
    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(ctx).takeUnretainedValue().onAdd?(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(ctx).takeUnretainedValue().onRemove?(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func devices() -> [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set)
    }

    /// Returns the attached keyboards (one entry per vid:pid).
    func keyboards() -> [KeyboardInfo] {
        var map: [String: KeyboardInfo] = [:]
        for d in devices() where isPrimaryKeyboard(d) {
            guard let v = hidInt(d, kIOHIDVendorIDKey), let p = hidInt(d, kIOHIDProductIDKey) else { continue }
            let info = KeyboardInfo(
                vid: v, pid: p,
                name: hidString(d, kIOHIDProductKey) ?? "Keyboard",
                transport: hidString(d, kIOHIDTransportKey) ?? "",
                builtIn: isBuiltInKeyboard(d)
            )
            map[info.id] = info
        }
        return map.values.sorted {
            ($0.builtIn ? 1 : 0, $0.name) < ($1.builtIn ? 1 : 0, $1.name)
        }
    }
}
