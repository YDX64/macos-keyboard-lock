#!/bin/bash
# Keyboard Lock: build script.   Usage:  ./build.sh        (output: ./KeyboardLock.app)
# Needs only Xcode or the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

# If the Xcode license has not been accepted, fall back to the Command Line Tools toolchain.
if ! swiftc --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP="KeyboardLock.app"
ARCH="$(uname -m)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"

# Fail early if the English and Turkish strings drift apart.
python3 tools/check-strings.py

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building ($ARCH)…"
swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework Carbon -framework Security \
  -o "$APP/Contents/MacOS/KeyboardLock" \
  Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

# Local (ad-hoc) signature. The default designated requirement of an ad-hoc signature is the
# cdhash, which changes with every build and invalidates the Input Monitoring permission macOS
# stored for the previous build. Binding the requirement to the bundle identifier keeps the
# permission valid across rebuilds (see SECURITY.md for the trade-off).
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null 2>&1 || \
  echo "Warning: signing failed (the app may still run)."

echo "Done: $(pwd)/$APP"
