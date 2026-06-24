#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# build_app.sh — assemble a runnable Lumora.app from the Swift Package build.
#
# No Apple Developer ID and no notarization: the app is AD-HOC signed for LOCAL use only. On first launch,
# right-click the app → Open (Gatekeeper blocks unsigned apps on a plain double-click), then it runs normally.
# Needs only the Swift toolchain that ships with Xcode (or the Command Line Tools) — `swift`, `codesign`, `iconutil`.
#
# Usage:  bash Scripts/build_app.sh [output-dir]      (default output: ./build)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Lumora"
EXECUTABLE="LumoraApp"                       # the SPM executable product
APP_DIR="${1:-$ROOT/build}"
APP="$APP_DIR/$APP_NAME.app"
REL="$ROOT/Packages/LumoraApp/.build/release"

echo "▶ Building $EXECUTABLE (release)…"
( cd "$ROOT/Packages/LumoraApp" && swift build -c release )
[ -x "$REL/$EXECUTABLE" ] || { echo "✗ build product not found at $REL/$EXECUTABLE"; exit 1; }

echo "▶ Generating the placeholder app icon (if Pillow is available)…"
if [ ! -f "$ROOT/app/AppIcon.icns" ]; then
    python3 "$ROOT/app/make_icon.py" 2>/dev/null || echo "  (skipped — Pillow not installed; the app will use a default icon)"
fi

echo "▶ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REL/$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/app/AppIcon.icns" ] && cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/$APP_NAME.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶ Ad-hoc code-signing (local use only — NOT notarized)…"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature OK"

echo
echo "✅ Built: $APP"
echo "   Launch it once with:  right-click → Open   (or:  xattr -dr com.apple.quarantine \"$APP\" && open \"$APP\")"
echo "   A status-bar item appears; the wallpaper renders behind your icons."
