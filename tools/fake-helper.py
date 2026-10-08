#!/usr/bin/env python3
"""A stand-in for the root lock service, for UI work and screenshots. It never touches a keyboard.

Run it, then start the app against its socket:

    ./tools/fake-helper.py /tmp/kl-fake.sock --state locked &
    KK_SOCKET=/tmp/kl-fake.sock KeyboardLock.app/Contents/MacOS/KeyboardLock

States: unlocked | locked | waiting (locked but the keyboard is unplugged).
"""
import argparse
import os
import socket
import time

ap = argparse.ArgumentParser()
ap.add_argument("socket")
ap.add_argument("--state", choices=["unlocked", "locked", "waiting"], default="unlocked")
ap.add_argument("--seconds", type=int, default=1725, help="remaining seconds shown when locked (0 = unlimited)")
args = ap.parse_args()

VERSION = 1
locked = args.state != "unlocked"
waiting = args.state == "waiting"
deadline = time.monotonic() + args.seconds if locked and args.seconds else None

if os.path.exists(args.socket):
    os.unlink(args.socket)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(args.socket)
os.chmod(args.socket, 0o600)
srv.listen(8)


def status():
    remaining = max(0, int(deadline - time.monotonic())) if deadline else 0
    seized = 0 if (waiting or not locked) else 2
    return f"OK {seized} 0 {remaining} {1 if locked else 0}"


while True:
    conn, _ = srv.accept()
    with conn:
        conn.settimeout(1)
        try:
            line = conn.makefile().readline().strip()
        except Exception:
            continue
        parts = line.split()
        cmd = parts[0] if parts else ""
        if cmd == "VERSION":
            reply = f"OK {VERSION}"
        elif cmd in ("STATUS", "PING"):
            reply = status()
        elif cmd == "LOCK" and len(parts) == 3:
            locked, waiting = True, False
            secs = int(parts[1])
            deadline = time.monotonic() + secs if secs else None
            reply = status()
        elif cmd in ("UNLOCK", "QUIT"):
            locked, waiting, deadline = False, False, None
            reply = status()
        elif cmd == "INFO":
            reply = "OK fake"
        else:
            reply = "ERR unknown"
        conn.sendall((reply + "\n").encode())
