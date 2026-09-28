#!/usr/bin/env bash
# Development install: builds, signs, installs to /Applications and relaunches.
#
#   scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/assemble-app.sh
APP="build/Pollymetric.app"
DEST="${POLLYMETRIC_INSTALL_DIR:-/Applications}"

pkill -x Pollymetric 2>/dev/null || true
rm -rf "$DEST/Pollymetric.app"
cp -R "$APP" "$DEST/"
# An older copy in ~/Applications would show up twice in Spotlight and Launchpad.
if [ "$DEST" != "$HOME/Applications" ] && [ -d "$HOME/Applications/Pollymetric.app" ]; then
    rm -rf "$HOME/Applications/Pollymetric.app"
fi
# Nudge Launch Services so Finder, the Dock and System Settings pick up icon changes.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Pollymetric.app"
sleep 1
open "$DEST/Pollymetric.app"
echo "Installed $DEST/Pollymetric.app ($(du -sh "$DEST/Pollymetric.app" | cut -f1))"
