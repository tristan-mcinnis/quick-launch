#!/bin/zsh
# make-dmg.sh: package Quick Launch as a free GitHub release download.
#
# Builds with ad hoc signing (no Apple Developer ID needed), wraps the app and
# an /Applications symlink in a compressed DMG, then writes SHA256SUMS,
# RELEASE_NOTES.md and the draft-release command beside it. It pushes nothing
# and creates no GitHub release.
#
# Usage:   ./scripts/make-dmg.sh            (or: make dmg)
# Output:  $RELEASE_OUT, default dist/release
# Options: QL_SKIP_BUILD=1 packages the existing build/Quick Launch.app.
#
# The notarized path (release.sh, build-dist.sh, notarize.sh) is separate and
# needs a Developer ID. This script never uses it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="Quick Launch"
FILE_SLUG="QuickLaunch"
REPO="tristan-mcinnis/quick-launch"
VERSION="$(tr -d '\n' < "$ROOT_DIR/.version")"
APP_BUNDLE="$ROOT_DIR/build/${APP_DISPLAY_NAME}.app"
OUT_DIR="${RELEASE_OUT:-$ROOT_DIR/dist/release}"
PKG_DIR="$ROOT_DIR/Packaging/Release"

if [[ "${QL_SKIP_BUILD:-0}" != "1" ]]; then
    SIGN_IDENTITY="-" "$ROOT_DIR/scripts/build-app.sh"
fi
[[ -d "$APP_BUNDLE" ]] || { print "ERROR: $APP_BUNDLE is missing. Run without QL_SKIP_BUILD." >&2; exit 1; }

ARCHS="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/quick-launch")"
DMG_NAME="${FILE_SLUG}-${VERSION}-macos-${ARCHS}.dmg"
DMG="$OUT_DIR/$DMG_NAME"

mkdir -p "$OUT_DIR"
rm -f "$DMG" "$OUT_DIR/SHA256SUMS" "$OUT_DIR/RELEASE_NOTES.md" "$OUT_DIR/DRAFT_RELEASE_COMMAND.txt" "$OUT_DIR/spctl-assess.txt" "$OUT_DIR/verify.log"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto keeps the signature, the extended attributes and the symlinks intact.
ditto "$APP_BUNDLE" "$STAGE/${APP_DISPLAY_NAME}.app"
ln -s /Applications "$STAGE/Applications"

print "==> Creating $DMG_NAME"
hdiutil create -quiet -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"

(cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)
SHA="$(awk '{print $1}' "$OUT_DIR/SHA256SUMS")"

print "==> Verifying the image"
"$ROOT_DIR/scripts/verify-dmg.sh" "$DMG" "$VERSION" 2>&1 | tee "$OUT_DIR/verify.log"
sed -n '/^---- spctl/,/^---- end spctl/p' "$OUT_DIR/verify.log" > "$OUT_DIR/spctl-assess.txt"

print "==> Writing RELEASE_NOTES.md"
export APP_NAME="$APP_DISPLAY_NAME" VERSION REPO DMG_NAME SHA
export HIGHLIGHTS="$(cat "$PKG_DIR/highlights.md")"
export FIRST_OPEN="$(sed "s|@APP_NAME@|$APP_DISPLAY_NAME|g" "$PKG_DIR/first-open.md.template")"
python3 - "$PKG_DIR/release-notes.md.template" "$OUT_DIR/RELEASE_NOTES.md" <<'PY'
import os, sys
text = open(sys.argv[1]).read()
for key in ("APP_NAME", "VERSION", "REPO", "DMG_NAME", "SHA", "HIGHLIGHTS", "FIRST_OPEN"):
    token = "@SHA256@" if key == "SHA" else f"@{key}@"
    text = text.replace(token, os.environ[key])
open(sys.argv[2], "w").write(text)
PY

cat > "$OUT_DIR/DRAFT_RELEASE_COMMAND.txt" <<CMD
gh release create v${VERSION} --repo ${REPO} --draft --title "${APP_DISPLAY_NAME} ${VERSION}" --notes-file "${OUT_DIR}/RELEASE_NOTES.md" "${DMG}" "${OUT_DIR}/SHA256SUMS"
CMD

print ""
print "==> Created:"
print "    $DMG"
print "    $OUT_DIR/SHA256SUMS"
print "    $OUT_DIR/RELEASE_NOTES.md"
print "    $OUT_DIR/DRAFT_RELEASE_COMMAND.txt"
print "    sha256 $SHA"
print ""
print "Next step (you run this; it needs your GitHub login):"
print "    $(cat "$OUT_DIR/DRAFT_RELEASE_COMMAND.txt")"
