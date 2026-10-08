# Changelog

## 1.0.0

First public release.

- Lock one chosen external keyboard while its backlight stays on (HID seize through a root helper).
- Window, menu bar item, Dock icon menu and global shortcut ⌃⌥⌘L.
- Timed lock with countdown (menu bar) and Dock badge; green/red/orange/gray Dock icon states.
- One-time setup installs a LaunchDaemon and a root-owned copy in `/Applications`; no password afterwards.
- Safety nets: heartbeat release, screen-lock / sleep / session release, one-hour cap without a built-in
  keyboard (enforced inside the helper), built-in keyboard never locked.
- English (default) and Turkish interface with an in-app language switch.
- `tools/selftest.sh` covers the helper protocol and the installer without root.
