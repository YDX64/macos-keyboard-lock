import SwiftUI

/// A ring that expands behind the lock icon and fades out while the keyboard is locked.
/// It keeps no state: the phase is computed from the timeline clock (no @State macro needed).
struct PulseRing: View {
    let active: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let p = t.truncatingRemainder(dividingBy: 1.6) / 1.6   // 0...1
            Circle()
                .stroke(color.opacity(0.6 * (1 - p)), lineWidth: 3)
                .scaleEffect(1 + 0.45 * p)
                .opacity(active ? 1 : 0)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model

    private var accent: Color {
        if m.needsSetup { return .gray }
        if m.isLocked { return m.waitingForKeyboard ? .orange : .red }
        return .green
    }

    var body: some View {
        VStack(spacing: 18) {
            statusCard
            if m.needsSetup { setupCard }
            lockButton
            keyboardSection
            durationSection
            if let n = m.notice { noticeView(n) }
            footer
        }
        .padding(24)
        .frame(width: 460)
        .animation(.easeInOut(duration: 0.2), value: m.isLocked)
        .animation(.easeInOut(duration: 0.2), value: m.notice)
        .animation(.easeInOut(duration: 0.2), value: m.helperState)
    }

    // MARK: Status card

    private var subtitle: String {
        if m.installing || m.busy { return tr("status.working") }
        if m.needsSetup { return tr("status.setupHint") }
        if m.isLocked {
            if m.waitingForKeyboard { return tr("status.waiting") }
            let names = m.lockedNames.isEmpty ? tr("status.selectedKeyboard") : m.lockedNames.joined(separator: ", ")
            if let t = m.remainingText { return tr("status.lockedTimeLeft", names, t) }
            return tr("status.lockedKeysOff", names)
        }
        return tr("status.idleHint")
    }

    private var title: String {
        if m.needsSetup { return tr("status.setupNeeded.title") }
        return m.isLocked ? tr("status.locked.title") : tr("status.unlocked.title")
    }

    private var statusIcon: String {
        if m.needsSetup { return "lock.slash.fill" }
        return m.isLocked ? "lock.fill" : "lock.open.fill"
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                PulseRing(active: m.isLocked && !m.waitingForKeyboard, color: accent)
                Circle().fill(accent.opacity(0.18))
                Image(systemName: statusIcon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.25)))
    }

    // MARK: Setup card

    private var setupKey: String {
        switch m.helperState {
        case .outdated: return "outdated"
        case .notResponding: return "notResponding"
        default: return "install"
        }
    }

    private var setupButtonKey: String {
        switch m.helperState {
        case .outdated: return "setup.update.button"
        case .notResponding: return "setup.repair.button"
        default: return "setup.install.button"
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.blue)
                Text(tr("setup.\(setupKey).title")).font(.headline)
            }
            Text(tr("setup.\(setupKey).body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                m.installHelper()
            } label: {
                HStack(spacing: 8) {
                    if m.installing { ProgressView().controlSize(.small) }
                    Text(tr(setupButtonKey)).font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(m.installing)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.25)))
    }

    // MARK: Main button

    private var lockButton: some View {
        Button {
            m.toggle()
        } label: {
            HStack(spacing: 10) {
                if m.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: m.isLocked ? "lock.open.fill" : "lock.fill")
                }
                Text(m.isLocked ? tr("button.unlock") : tr("button.lock"))
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(m.isLocked ? .green : .red)
        .disabled(m.busy || m.installing || (!m.isLocked && !m.canLock))
    }

    // MARK: Keyboard list

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("section.keyboards")).font(.headline)

            if m.keyboards.isEmpty {
                placeholder(tr("kb.none"))
            } else {
                VStack(spacing: 6) {
                    ForEach(m.keyboards) { kb in keyboardRow(kb) }
                }
                if m.externalKeyboards.isEmpty {
                    placeholder(tr("kb.noExternal"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func keyboardRow(_ kb: KeyboardInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kb.builtIn ? "laptopcomputer" : "keyboard")
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(kb.builtIn ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(kb.name).font(.body.weight(.medium))
                Text(kb.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if kb.builtIn {
                Text(tr("kb.alwaysOn")).font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("", isOn: binding(for: kb))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(m.isLocked || m.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func binding(for kb: KeyboardInfo) -> Binding<Bool> {
        Binding(
            get: { m.selected.contains(kb.id) },
            set: { on in
                if on { m.selected.insert(kb.id) } else { m.selected.remove(kb.id) }
            }
        )
    }

    // MARK: Auto-unlock duration

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("section.autoUnlock")).font(.headline)
            Picker("", selection: $m.duration) {
                ForEach(LockDuration.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(m.isLocked || m.busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Notice

    private func noticeView(_ n: Notice) -> some View {
        let color: Color = n.kind == .error ? .red : (n.kind == .warning ? .orange : .blue)
        let icon = n.kind == .error ? "xmark.octagon.fill"
            : (n.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 8) {
                Text(n.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = n.action {
                    Button(tr("notice.openInputMonitoring")) { m.perform(action) }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button {
                m.notice = nil
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }

    // MARK: Footer

    private func languageName(_ choice: LanguageChoice) -> String {
        switch choice {
        case .system: return tr("lang.system")
        case .en: return tr("lang.en")
        case .tr: return tr("lang.tr")
        }
    }

    /// A footer line that wraps instead of being truncated, in every language.
    private func footerLine(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if m.hotKeyWorks { footerLine(tr("footer.hotkey")) }
            footerLine(tr("footer.control"))
            footerLine(tr("footer.alwaysWorks"))

            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Picker("", selection: $m.language) {
                        ForEach(LanguageChoice.allCases) { Text(languageName($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                if m.helperState == .ready && !m.isLocked {
                    Button(tr("footer.uninstall")) { m.confirmAndUninstall() }
                        .buttonStyle(.link)
                }
            }
            .padding(.top, 2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}
