#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="quick-launch"
APP_DISPLAY_NAME="Quick Launch"
SWIFT_TARGET="QuickLaunch"
APP_BUNDLE="$ROOT_DIR/build/${APP_DISPLAY_NAME}.app"
VERSION="$(tr -d '\n' < "$ROOT_DIR/.version")"
ICON_SOURCE="$ROOT_DIR/Sources/Resources/AppIcon.icns"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/quick-launch.entitlements}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

codesign_path() {
    local target="$1"
    shift || true

    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" "$@" "$target"
    else
        codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@" "$target"
    fi
}

sign_bundle() {
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true

    if [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
        codesign_path "$APP_BUNDLE" \
            --requirements '=designated => identifier "com.tristanmcinnis.quick-launch"' \
            --entitlements "$ENTITLEMENTS"
    else
        codesign_path "$APP_BUNDLE" \
            --requirements '=designated => identifier "com.tristanmcinnis.quick-launch"'
    fi

    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

print "==> Building ${APP_NAME} ${VERSION}"
swift build -c release --package-path "$ROOT_DIR"
BIN_DIR="$(swift build -c release --show-bin-path --package-path "$ROOT_DIR")"
BIN_PATH="${BIN_DIR}/${SWIFT_TARGET}"

mkdir -p "$ROOT_DIR/build"
touch "$ROOT_DIR/build/.metadata_never_index"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# ...and record WHICH COMMIT went in, ALONGSIDE the two version stamps above
# (never replacing them), so an installed binary is always traceable even when
# the version alone cannot say. A dirty tree is marked, because such a build
# traces to no commit at all; `make install` refuses one unless QL_ALLOW_DIRTY=1.
# A plain build is never refused here, only marked. This runs before
# sign_bundle, so the signature covers the stamp.
COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || print unknown)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]]; then
    COMMIT="${COMMIT}-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :QuickLaunchBuiltFromCommit string ${COMMIT}" "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :QuickLaunchBuiltFromCommit ${COMMIT}" "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# RTI consumes this same package from a different repository. Record the
# source fingerprint as well as the app commit so either installed app can
# identify the shared implementation it contains.
python3 "$ROOT_DIR/scripts/chat-core-provenance.py" --plist "$APP_BUNDLE/Contents/Info.plist"

[[ -f "$ICON_SOURCE" ]] && cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
[[ -f "$ROOT_DIR/PrivacyInfo.xcprivacy" ]] && cp "$ROOT_DIR/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/"
# The licence and the credits for every bundled dependency travel with the app.
cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"

print "==> Signing bundle (${SIGN_IDENTITY})"
sign_bundle

print "==> Built ${APP_BUNDLE}"
