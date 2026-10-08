# Security and trust model

Keyboard Lock installs a small helper that runs as **root**. This page explains exactly what that
helper can do, what it protects against, and what it cannot.

## What runs as root

The same `KeyboardLock` binary, started by launchd with `--daemon <your uid>` from a root-owned copy
in `/Applications/KeyboardLock.app`. It does one thing: ask macOS to give it exclusive access to the
HID interfaces of the keyboard you chose (`IOHIDDeviceOpen` with `kIOHIDOptionsTypeSeizeDevice`), and
release it again.

- It **never reads key events.** It registers no input callbacks. Check it yourself:
  `grep -rn "InputValue\|InputReport" Sources` finds nothing.
- It understands a handful of plain-text commands: `LOCK`, `UNLOCK`, `STATUS` (alias `PING`), `VERSION`,
  `INFO` and `QUIT` (which only releases the lock). `LOCK` input is validated (digits, `:` and `,` only; duration 0–86400 s). Nothing is passed to a shell.
- It listens on `/var/run/<bundle id>.sock`. `/var/run` is writable by root only, so another user cannot
  plant a fake server there. The socket is world-connectable, but every connection is checked with
  `getpeereid`: only the user who ran the setup (and root) is served.
- The app talks to the service only if the peer is root (on the default path), so a fake socket owned by
  an unprivileged process is ignored.
- It never locks the built-in keyboard, never locks interfaces that also carry a mouse or touch surface,
  and never touches vendor lighting interfaces.

## What a malicious process running as *you* could do

Talk to the socket and lock or unlock your keyboard. That is all: the helper has no file, network or
execution features. The damage is a denial of service, and it is bounded:

- A 20-second heartbeat releases the keyboard when the app stops polling.
- Without a built-in keyboard a lock lasts at most one hour, enforced **inside the helper**.
- The mouse, trackpad and built-in keyboard keep working; screen lock, sleep and reboot release the lock.

## How the installer is protected

The one-time setup runs a shell script as root through the standard macOS administrator prompt.

1. The app is copied to `/Applications/KeyboardLock.app.new`, made `root:wheel`, group/world write removed,
   and checked with `codesign --verify --strict`.
2. The script then compares the copy's **code directory hash (cdhash)** with the cdhash of the app that is
   actually running (read through the Security framework). If they differ, the install aborts and the
   copy is deleted. A bundle swapped between launch and install is therefore never trusted.
3. Only then are the old service stopped, the copy moved into place and the service definition written.

This is covered by `tools/selftest.sh` (wrong hash refused, tampered bundle refused, nothing left behind).

## What this does not protect against

- **You launching a malicious app.** If you run a modified app and click Install, you authorize it. Build from
  source you have read, from this repository. There are deliberately no pre-built binaries.
- **Ad-hoc signing.** The app is signed ad hoc, not with a Developer ID, and is not notarized. `codesign`
  therefore proves integrity, not identity. This is why the cdhash comparison above is bound to the running
  app instead of a certificate.
- **The Input Monitoring permission follows the bundle identifier, not one exact build.** `build.sh` sets the
  designated requirement to `identifier "<bundle id>"` so the permission survives rebuilds. The trade-off: a
  different ad-hoc binary that claims the same identifier would also match the permission. It would still not
  be root.
- **`/Applications` is group-writable for administrators.** An administrator-group process could race the
  copy → verify → move steps of the installer. Administrators can already become root, so this adds no new
  power.
- **macOS background-item notice.** macOS 13+ may show a notice that a background item was added. That is the
  LaunchDaemon; you can review it in System Settings → General → Login Items.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security tab → *Report a vulnerability*) rather than a
public issue. Include macOS version, steps to reproduce and the impact you see.
