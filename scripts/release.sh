#!/usr/bin/env bash
# Builds the installer: dist/Pollymetric-<version>.dmg
#
#   scripts/release.sh            # distributable: Developer ID + notarized, or it stops
#   scripts/release.sh --local    # this-Mac build signed with Pollymetric Local (not notarized)
#   add --publish to create GitHub release v<version> with docs/releases/<version>.md as notes
#
# Distributable releases need, once per Mac:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. A notarytool profile named "pollymetric":
#      xcrun notarytool store-credentials pollymetric --apple-id <you> --team-id <TEAMID>
#      (it prompts for an app-specific password from account.apple.com).
set -euo pipefail
cd "$(dirname "$0")/.."

LOCAL=false
PUBLISH=false
for arg in "$@"; do
    case "$arg" in
        --local) LOCAL=true ;;
        --publish) PUBLISH=true ;;
    esac
done
PROFILE="${POLLYMETRIC_NOTARY_PROFILE:-pollymetric}"
VERSION="$(cat VERSION)"
DMG="dist/Pollymetric-${VERSION}.dmg"

DEVELOPER_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -z "$DEVELOPER_ID" ] && ! $LOCAL; then
    cat >&2 <<MSG
No "Developer ID Application" certificate found, so this build couldn't open cleanly on
other Macs. Create one (Xcode → Settings → Accounts → Manage Certificates → + →
Developer ID Application), or run with --local for a build for this Mac only.
MSG
    exit 1
fi
NOTARIZE=false
if [ -n "$DEVELOPER_ID" ] && ! $LOCAL; then
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        NOTARIZE=true
    else
        cat >&2 <<MSG
No notarytool profile named "$PROFILE". Create it once:
  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id <team ID>
MSG
        exit 1
    fi
fi

if $LOCAL; then
    POLLYMETRIC_SIGN_IDENTITY="$(cat .sign-identity 2>/dev/null || echo -)" scripts/assemble-app.sh --universal
else
    POLLYMETRIC_SIGN_IDENTITY="$DEVELOPER_ID" scripts/assemble-app.sh --universal
fi
APP="build/Pollymetric.app"

notarize() {
    echo "Notarizing $(basename "$1")… (usually a few minutes)" >&2
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

# Notarize and staple the app itself, so it opens offline and after being copied out.
if $NOTARIZE; then
    ditto -c -k --keepParent "$APP" build/Pollymetric-notarize.zip
    notarize build/Pollymetric-notarize.zip
    xcrun stapler staple "$APP"
fi

# Installer window artwork, drawn by the app (retina TIFF from 1× + 2×).
rm -rf build/dmg && mkdir -p build/dmg dist
"$APP/Contents/MacOS/Pollymetric" --make-dmg-background build/dmg
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff >/dev/null

# dmgbuild runs where the signing key is usable, so install exactly the reviewed,
# hash-locked versions (Support/dmgbuild-requirements.txt), never whatever PyPI serves.
rm -rf build/dmgbuild-env
uv venv --quiet --python 3.11 build/dmgbuild-env
uv pip install --quiet --python build/dmgbuild-env --require-hashes -r Support/dmgbuild-requirements.txt

rm -f "$DMG"
build/dmgbuild-env/bin/dmgbuild -s Support/dmg-settings.py \
    -D app="$APP" -D background=build/dmg/background.tiff \
    -D volume_icon="$APP/Contents/Resources/AppIcon.icns" \
    "Pollymetric" "$DMG"

if [ -n "$DEVELOPER_ID" ] && ! $LOCAL; then
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
$LOCAL && echo "Local build: signed with Pollymetric Local, not notarized. Other Macs will block it."

# Publish: tag v<version>, notes from docs/releases/<version>.md, and the DMG under a
# stable name so .../releases/latest/download/Pollymetric.dmg always gets the newest.
if $PUBLISH; then
    NOTES="docs/releases/${VERSION}.md"
    [ -f "$NOTES" ] || { echo "Write $NOTES first (what's new, for people)." >&2; exit 1; }
    git diff --quiet && git diff --cached --quiet || { echo "Commit your changes before publishing." >&2; exit 1; }
    cp "$DMG" dist/Pollymetric.dmg
    shasum -a 256 dist/Pollymetric.dmg | sed 's|dist/||' > dist/Pollymetric.dmg.sha256
    git tag -a "v${VERSION}" -m "Pollymetric ${VERSION}" 2>/dev/null || true
    git push -q origin "v${VERSION}"
    gh release create "v${VERSION}" dist/Pollymetric.dmg dist/Pollymetric.dmg.sha256 \
        --title "Pollymetric ${VERSION}" --notes-file "$NOTES" --verify-tag
    echo "Published $(gh release view "v${VERSION}" --json url --jq .url)"
fi

