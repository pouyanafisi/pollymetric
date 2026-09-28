#!/usr/bin/env bash
# Builds and signs build/Pollymetric.app. Shared by build-app.sh (dev install) and
# release.sh (DMG).
#
#   scripts/assemble-app.sh [--universal]
#
# Signing identity, first match wins:
#   1. POLLYMETRIC_SIGN_IDENTITY
#   2. a "Developer ID Application" certificate in the keychain (what releases need)
#   3. the local identity hash in .sign-identity (self-signed "Pollymetric Local")
#   4. ad-hoc, with a warning
# macOS ties permissions (Full Disk Access, Automation) to the signature, so changing
# identity means granting them once more.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64)
[ "${1:-}" = "--universal" ] && ARCHS=(--arch arm64 --arch x86_64)

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

IDENTITY="${POLLYMETRIC_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ] && [ -f .sign-identity ]; then IDENTITY="$(cat .sign-identity)"; fi
if [ -z "$IDENTITY" ]; then
    echo "warning: ad-hoc signing; macOS permissions reset on every rebuild" >&2
    IDENTITY="-"
fi

swift build -c release "${ARCHS[@]}" >&2
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Pollymetric"

APP="build/Pollymetric.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pollymetric"

# App icon, drawn by the app's own LogoMark code (same geometry as design/logo.svg).
rm -rf build/AppIcon.iconset
"$BIN" --make-iconset build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Pollymetric</string>
    <key>CFBundleDisplayName</key><string>Pollymetric</string>
    <key>CFBundleIdentifier</key><string>com.pouyanafisi.pollymetric</string>
    <key>CFBundleExecutable</key><string>Pollymetric</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Pouya Nafisi</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Pollymetric opens tools like btop, dua and Lynis in a new iTerm2 tab.</string>
</dict>
</plist>
PLIST

# Developer ID signatures need a secure timestamp for notarization; local ones don't.
TIMESTAMP=(--timestamp=none)
case "$IDENTITY" in "Developer ID"*) TIMESTAMP=(--timestamp) ;; esac
codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" \
    --entitlements Support/Pollymetric.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Assembled $APP $VERSION ($BUILD), $(lipo -archs "$APP/Contents/MacOS/Pollymetric"), signed by: $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}')" >&2
