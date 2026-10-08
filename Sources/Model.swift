import SwiftUI
import AppKit
import IOKit.hid

struct Notice: Equatable {
    enum Kind { case info, warning, error }
    enum Action { case openInputMonitoring }
    var text: String
    var kind: Kind
    var action: Action? = nil
}

enum LockDuration: Int, CaseIterable, Identifiable {
    case unlimited = 0, min15 = 900, min30 = 1800, hour1 = 3600, hour2 = 7200

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .unlimited: return tr("duration.unlimited")
        case .min15: return tr("duration.min15")
        case .min30: return tr("duration.min30")
        case .hour1: return tr("duration.hour1")
        case .hour2: return tr("duration.hour2")
        }
    }
}

/// State of the persistent lock service (LaunchDaemon).
enum HelperState: Equatable {
    case unknown        // not polled yet
    case ready          // installed, running, protocol version matches
    case notInstalled   // not installed
    case notResponding  // looks installed but does not answer
    case outdated       // running, but the protocol version differs
}

private struct PollResult {
    var status: StatusReply?
    var version: Int?
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    @Published var keyboards: [KeyboardInfo] = []
    @Published var selected: Set<String> = []
    @Published var isLocked = false
    @Published var busy = false
    @Published var remaining: Int? = nil
    @Published var duration: LockDuration = .unlimited
    @Published var notice: Notice? = nil
    @Published var lockedNames: [String] = []
    /// A lock is requested but the keyboard is unplugged right now; it locks again when plugged in.
    @Published var waitingForKeyboard = false
    /// Whether the global shortcut (⌃⌥⌘L) could be registered.
    @Published var hotKeyWorks = true
    @Published var helperState: HelperState = .unknown
    /// Setup or removal (including the password dialog) is in progress.
    @Published var installing = false
    /// Language picked in the app. `didSet` runs before SwiftUI re-renders, so `tr()` is up to date.
    @Published var language: LanguageChoice = Localizer.choice {
        didSet { Localizer.choice = language }
    }

    private let watcher = DeviceWatcher()
    private let socket = KK.socketPath
    private var known = Set<String>()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var missedPolls = 0
    /// Incremented by every state-changing operation; the result of an older in-flight poll is ignored.
    private var epoch = 0

    private init() {}

    // MARK: Start

    func start() {
        guard timer == nil else { return }
        // Keep sending heartbeats while the app is hidden: disable App Nap.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keyboard lock heartbeat"
        )
        watcher.start()
        refreshDevices()
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common: keep polling while a menu is open or the window is being dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observeSessionEnd()
    }

    /// Release the keyboard when the screen locks, the user session changes or the Mac sleeps.
    /// Otherwise (especially on Macs without a built-in keyboard) a password could not be typed.
    private func observeSessionEnd() {
        let release: (String) -> Void = { [weak self] key in
            Task { @MainActor in
                guard let self, self.isLocked, !self.busy else { return }
                self.unlock()
                self.notice = Notice(text: tr(key), kind: .info)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in release("notice.release.screenLock") }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            release("notice.release.session")
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            release("notice.release.sleep")
        }
    }

    /// On quit: release the lock (the service keeps running, idle).
    func shutdown() {
        Installer.cancelPending()
        HelperControl.release(socket: socket)
    }

    // MARK: Devices

    private func refreshDevices() {
        let list = watcher.keyboards()
        if list != keyboards { keyboards = list }

        // Select newly plugged-in external keyboards by default.
        for kb in list where !kb.builtIn && !known.contains(kb.id) {
            known.insert(kb.id)
            selected.insert(kb.id)
        }
        let present = Set(list.map(\.id))
        selected = selected.intersection(present)
        // A keyboard that was unplugged can be selected again when it comes back.
        known = known.intersection(present)
    }

    var externalKeyboards: [KeyboardInfo] { keyboards.filter { !$0.builtIn } }
    var hasBuiltInKeyboard: Bool { keyboards.contains { $0.builtIn } }
    var needsSetup: Bool {
        helperState == .notInstalled || helperState == .notResponding || helperState == .outdated
    }
    var canLock: Bool { helperState == .ready && !selected.isEmpty }

    // MARK: Formatting (shared by the window, the menu bar and the Dock)

    static func format(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var remainingText: String? { remaining.map(Model.format) }

    var statusLine: String {
        if installing { return tr("statusLine.working") }
        if needsSetup { return tr("statusLine.setup") }
        if isLocked {
            if waitingForKeyboard { return tr("statusLine.waiting") }
            if let t = remainingText { return tr("statusLine.timeLeft", t) }
            return tr("statusLine.locked")
        }
        return tr("statusLine.unlocked")
    }

    // MARK: Polling (heartbeat)

    private func tick() {
        refreshDevices()
        guard !busy, !installing else { return }
        let sock = socket
        let e = epoch
        Task {
            let poll = await Task.detached(priority: .utility) { () -> PollResult in
                let st = HelperControl.status(socket: sock)
                let v = st != nil ? HelperControl.version(socket: sock) : nil
                return PollResult(status: st, version: v)
            }.value
            // If a lock/unlock ran while this poll was in flight, drop the stale result.
            guard e == self.epoch else { return }
            self.apply(poll)
        }
    }

    private func apply(_ poll: PollResult) {
        guard !busy, !installing else { return }
        guard let st = poll.status else {
            // A single missed poll can be transient; do not decide until several in a row.
            missedPolls += 1
            if missedPolls >= 2 {
                helperState = Installer.installedPlistExists ? .notResponding : .notInstalled
            }
            if isLocked && missedPolls >= 3 {
                isLocked = false
                remaining = nil
                waitingForKeyboard = false
                notice = Notice(text: tr("notice.helperGone"), kind: .info)
                NSSound(named: "Pop")?.play()
            } else if !isLocked {
                remaining = nil
            }
            return
        }
        missedPolls = 0
        helperState = poll.version == KK.protocolVersion ? .ready : .outdated

        if st.count > 0 || st.wanted > 0 {
            if !isLocked { lockedNames = selectedNames() }
            isLocked = true
            waitingForKeyboard = st.count == 0
            remaining = st.remaining > 0 ? st.remaining : nil
            if notice?.kind == .error { notice = nil }
        } else {
            waitingForKeyboard = false
            if isLocked {
                isLocked = false
                notice = Notice(text: tr("notice.expired"), kind: .info)
                NSSound(named: "Pop")?.play()
                // Bounce the Dock icon so the user notices that a timed lock has ended.
                NSApp.requestUserAttention(.informationalRequest)
            }
            remaining = nil
        }
    }

    private func selectedNames() -> [String] {
        keyboards.filter { selected.contains($0.id) }.map(\.name)
    }

    // MARK: Lock / unlock

    func toggle() {
        if busy || installing { return }
        isLocked ? unlock() : lock()
    }

    func setDuration(seconds: Int) {
        guard !isLocked, let d = LockDuration(rawValue: seconds) else { return }
        duration = d
    }

    func lock() {
        guard !busy, !installing, !isLocked else { return }
        guard helperState == .ready else {
            show(Notice(text: tr("notice.needSetup"), kind: .warning))
            return
        }
        let keys = externalKeyboards.map(\.id).filter { selected.contains($0) }.sorted()
        guard !keys.isEmpty else {
            notice = Notice(text: tr("notice.noKeyboardSelected"), kind: .warning)
            return
        }
        // Without Input Monitoring permission macOS refuses to detach a keyboard. The service
        // shares this app's identity, so the permission is checked here and, if missing, the
        // user is guided to the setting.
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            show(Notice(text: tr("notice.permissionPrompt"), kind: .warning, action: .openInputMonitoring))
            return
        }
        if access != kIOHIDAccessTypeGranted {
            show(deniedNotice(IOErr.notPermitted))
            return
        }

        busy = true
        epoch += 1
        notice = nil
        var secs = duration.rawValue
        if secs == 0 && !hasBuiltInKeyboard {
            // Without a built-in keyboard you could not even type a password: 1 hour instead of unlimited.
            secs = LockDuration.hour1.rawValue
            notice = Notice(text: tr("notice.noBuiltIn1h"), kind: .info)
        }
        let sock = socket
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                HelperControl.lock(socket: sock, seconds: secs, keys: keys)
            }.value
            self.finishLock(outcome)
        }
    }

    /// Shows a notice and brings the window to the front (it must not stay hidden behind other windows).
    private func show(_ n: Notice) {
        notice = n
        MenuActions.shared.showWindow()
    }

    private func finishLock(_ outcome: LockOutcome) {
        busy = false
        epoch += 1
        missedPolls = 0
        switch outcome {
        case .locked(let st):
            lockedNames = selectedNames()
            isLocked = true
            remaining = st.remaining > 0 ? st.remaining : nil
            NSSound(named: "Tink")?.play()
            if st.error != 0 {
                notice = Notice(text: tr("notice.partialLock", describe(st.error)), kind: .warning)
            } else if !hasBuiltInKeyboard {
                notice = Notice(text: tr("notice.noBuiltInUnlock"), kind: .info)
            }
        case .noDevice:
            notice = Notice(text: tr("notice.noDevice"), kind: .warning)
        case .denied(let code):
            show(deniedNotice(code))
        case .failed(let message):
            notice = Notice(text: tr("notice.lockFailed", message), kind: .error)
        }
    }

    func unlock() {
        guard !busy, !installing else { return }
        busy = true
        epoch += 1
        let sock = socket
        Task {
            // If UNLOCK gets no reply, ask for the state before announcing a result.
            let final = await Task.detached(priority: .userInitiated) { () -> StatusReply? in
                HelperControl.unlock(socket: sock) ?? HelperControl.status(socket: sock)
            }.value
            self.busy = false
            self.epoch += 1
            self.missedPolls = 0
            if let final, final.count > 0 || final.wanted > 0 {
                // The service is alive and still locking: tell the user the truth.
                self.notice = Notice(text: tr("notice.unlockFailed"), kind: .error)
                return
            }
            // Either "released" or no service at all: the keyboard is free.
            self.isLocked = false
            self.waitingForKeyboard = false
            self.remaining = nil
            NSSound(named: "Pop")?.play()
        }
    }

    // MARK: Install / uninstall

    func installHelper() {
        guard !installing, !busy else { return }
        if isLocked {
            show(Notice(text: tr("notice.unlockFirstInstall"), kind: .warning))
            return
        }
        // The script only installs a copy whose code hash equals this running app's hash.
        guard let hash = CodeIdentity.ownCDHash() else {
            show(Notice(text: tr("notice.signatureUnreadable"), kind: .error))
            return
        }
        installing = true
        notice = nil
        let script = Installer.installScript(src: Bundle.main.bundlePath, dst: KK.installedApp,
                                             plistPath: KK.daemonPlist, uid: getuid(),
                                             expectedCDHash: hash)
        let prompt = tr("prompt.install")
        let failedTimeout = tr("notice.installTimeout")
        let sock = socket
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Installer.Result in
                let r = Installer.runPrivileged(script, prompt: prompt)
                guard case .success = r else { return r }
                // Wait for the service to come up (about 8 s at most).
                for _ in 0..<40 {
                    if HelperControl.version(socket: sock) == KK.protocolVersion { return .success }
                    usleep(200_000)
                }
                return .failed(failedTimeout)
            }.value
            self.installing = false
            self.missedPolls = 0
            switch result {
            case .success:
                self.helperState = .ready
                self.notice = Notice(text: tr("notice.installDone"), kind: .info)
                self.relaunchFromApplicationsIfNeeded()
            case .cancelled:
                self.notice = Notice(text: tr("notice.installCancelled"), kind: .info)
            case .failed(let message):
                self.notice = Notice(text: tr("notice.installFailed", message), kind: .error)
            }
        }
    }

    /// After setup the app reopens from the protected copy in /Applications.
    private func relaunchFromApplicationsIfNeeded() {
        guard Bundle.main.bundlePath != KK.installedApp else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: KK.installedApp), configuration: cfg) { _, error in
            if error == nil { DispatchQueue.main.async { NSApp.terminate(nil) } }
        }
    }

    func confirmAndUninstall() {
        guard !installing, !busy else { return }
        if isLocked {
            show(Notice(text: tr("notice.unlockFirstUninstall"), kind: .warning))
            return
        }
        let alert = NSAlert()
        alert.messageText = tr("alert.uninstall.title")
        alert.informativeText = tr("alert.uninstall.message")
        alert.addButton(withTitle: tr("alert.uninstall.confirm"))
        alert.addButton(withTitle: tr("alert.uninstall.cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        installing = true
        let script = Installer.uninstallScript(plistPath: KK.daemonPlist, socketPath: KK.defaultSocket)
        let prompt = tr("prompt.uninstall")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Installer.runPrivileged(script, prompt: prompt)
            }.value
            self.installing = false
            self.missedPolls = 0
            switch result {
            case .success:
                self.helperState = .notInstalled
                self.notice = Notice(text: tr("notice.uninstallDone"), kind: .info)
            case .cancelled:
                self.notice = Notice(text: tr("notice.uninstallCancelled"), kind: .info)
            case .failed(let message):
                self.notice = Notice(text: tr("notice.uninstallFailed", message), kind: .error)
            }
        }
    }

    // MARK: Error descriptions

    private func describe(_ code: UInt32) -> String {
        switch code {
        case IOErr.notPermitted: return tr("err.notPermitted")
        case IOErr.exclusiveAccess: return tr("err.exclusive")
        case IOErr.notPrivileged: return tr("err.notPrivileged")
        default: return tr("err.code", code)
        }
    }

    private func deniedNotice(_ code: UInt32) -> Notice {
        switch code {
        case IOErr.notPermitted:
            return Notice(text: tr("notice.permissionDenied"), kind: .error, action: .openInputMonitoring)
        case IOErr.exclusiveAccess:
            return Notice(text: tr("notice.exclusive"), kind: .error)
        default:
            return Notice(text: tr("notice.lockFailedCode", describe(code)), kind: .error)
        }
    }

    func perform(_ action: Notice.Action) {
        switch action {
        case .openInputMonitoring:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
