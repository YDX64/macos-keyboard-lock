#!/bin/bash
# Self-test that needs no root, no keyboard and no password.
# It exercises the helper protocol on a private socket and the installer script in a scratch folder
# with a fake `launchctl`.   Usage:  ./tools/selftest.sh   (after ./build.sh)
set -u
cd "$(dirname "$0")/.."
APP="KeyboardLock.app"
BIN="$PWD/$APP/Contents/MacOS/KeyboardLock"
[ -x "$BIN" ] || { echo "Build first: ./build.sh"; exit 2; }

T="$(mktemp -d /tmp/kltest.XXXXXX)"
SOCK="$T/h.sock"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected: $3, got: $2)"; fi }
q()    { printf '%s\n' "$1" | nc -U -w 3 "$SOCK" 2>/dev/null; }
cleanup() { pkill -f "$SOCK" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

echo "== helper protocol (no root)"
"$BIN" --daemon "$(id -u)" "$SOCK" >/dev/null 2>&1 &
HP=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.3; done
check "VERSION answers the protocol version"  "$(q VERSION)" "OK 1"
check "STATUS is idle"                         "$(q STATUS)"  "OK 0 0 0 0"
check "malformed LOCK is rejected"             "$(q 'LOCK x y;z')" "ERR syntax"
check "unknown command is rejected"            "$(q 'REBOOT')" "ERR unknown"
LOCK_REPLY="$(q 'LOCK 5 1:1')"
case "$LOCK_REPLY" in OK\ 0\ *) ok "LOCK of an absent keyboard locks nothing ($LOCK_REPLY)";; *) bad "LOCK reply: $LOCK_REPLY";; esac
check "QUIT only unlocks"                      "$(q QUIT)"    "OK 0 0 0 0"
kill -0 $HP 2>/dev/null && ok "service stays alive after QUIT" || bad "service died after QUIT"
"$BIN" --daemon "$(id -u)" "$SOCK" >/dev/null 2>&1 & HP2=$!
sleep 1
kill -0 $HP2 2>/dev/null && bad "a second service instance kept running" || ok "a second instance exits immediately"
( printf 'PIN'; sleep 5 ) | nc -U "$SOCK" >/dev/null 2>&1 &
sleep 0.3
START=$(python3 -c 'import time;print(time.time())')
R="$(q PING)"
END=$(python3 -c 'import time;print(time.time())')
python3 - "$START" "$END" <<'PY' && ok "a slow client cannot block the service (PING answered: $R)" || bad "slow client blocked the service"
import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 2.5 else 1)
PY
kill -TERM $HP; sleep 1
kill -0 $HP 2>/dev/null && bad "service ignored SIGTERM" || ok "SIGTERM exits cleanly"
[ -e "$SOCK" ] && bad "socket file left behind" || ok "socket file removed"

echo "== installer script (fake launchctl, scratch folder)"
CD="$("$BIN" --print-cdhash)"
REAL="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
check "own cdhash equals codesign's CDHash" "$CD" "$REAL"
mkdir -p "$T/Apps" "$T/Daemons"
printf '#!/bin/sh\necho "launchctl $*" >> "%s/launchctl.log"\n' "$T" > "$T/fake-launchctl"; chmod +x "$T/fake-launchctl"
ME="$(id -un):$(id -gn)"
DST="$T/Apps/KeyboardLock.app"; PL="$T/Daemons/helper.plist"
gen() { "$BIN" --print-install-script "$1" "$2" "$PL" "$(id -u)" "$ME" "$T/fake-launchctl" "$3"; }
gen "$PWD/$APP" "$DST" "$CD" > "$T/install.sh"
sh -n "$T/install.sh" && ok "install script is valid shell" || bad "install script syntax"
sh "$T/install.sh" >/dev/null 2>&1 && ok "install succeeds" || bad "install failed"
[ -x "$DST/Contents/MacOS/KeyboardLock" ] && ok "protected copy exists" || bad "copy missing"
[ -e "$DST.new" ] && bad "temporary copy left behind" || ok "no temporary copy left behind"
plutil -lint "$PL" >/dev/null && ok "service plist is valid" || bad "plist invalid"
grep -q 'bootstrap system' "$T/launchctl.log" && ok "service is started (bootstrap)" || bad "no bootstrap call"
sh "$T/install.sh" >/dev/null 2>&1 && ok "re-install over an existing copy works" || bad "re-install failed"
gen "$DST" "$DST" "$CD" > "$T/inplace.sh"; sh "$T/inplace.sh" >/dev/null 2>&1 && ok "in-place update works" || bad "in-place update failed"

rm -f "$PL"
gen "$PWD/$APP" "$T/Apps/Evil.app" "0000000000000000000000000000000000000000" > "$T/evil.sh"
sh "$T/evil.sh" >/dev/null 2>&1 && bad "a copy with the wrong cdhash was accepted" || ok "a copy with the wrong cdhash is refused"
[ -e "$PL" ] && bad "service definition written for a refused copy" || ok "no service definition for a refused copy"
[ -e "$T/Apps/Evil.app" ] || [ -e "$T/Apps/Evil.app.new" ] && bad "refused copy left behind" || ok "refused copy is cleaned up"

cp -R "$PWD/$APP" "$T/tampered.app"; echo x >> "$T/tampered.app/Contents/MacOS/KeyboardLock"
gen "$T/tampered.app" "$T/Apps/Tampered.app" "$CD" > "$T/tampered.sh"
sh "$T/tampered.sh" >/dev/null 2>&1 && bad "a tampered bundle was accepted" || ok "a tampered bundle is refused"

"$BIN" --print-uninstall-script "$PL" "$T/x.sock" "$T/fake-launchctl" > "$T/uninstall.sh"
touch "$PL" "$T/x.sock"; sh "$T/uninstall.sh" >/dev/null 2>&1
[ -e "$PL" ] || [ -e "$T/x.sock" ] && bad "uninstall left files behind" || ok "uninstall removes the plist and the socket"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
