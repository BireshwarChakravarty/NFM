#!/usr/bin/env bash
# Builds NFM.app for Apple silicon (macOS 27+) into ./build.
#
# The version comes from the VERSION file at the repository root.
#
#   scripts/build-app.sh                       # release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   NFM_MACOS_MIN=26.0 scripts/build-app.sh    # test build that runs on macOS 26
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="NFM"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
ARCHS="${ARCHS:-arm64}"
export NFM_MACOS_MIN="${NFM_MACOS_MIN:-27.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT="${OUT_DIR:-$ROOT/build}"
APP="$OUT/$APP_NAME.app"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "▸ Compiling ($ARCHS)"
swift build -c release "${arch_flags[@]}"
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/Resources/nfm.js" "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__MIN_MACOS__/$NFM_MACOS_MIN/" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▸ Signing ($SIGN_IDENTITY)"
sign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "✓ Built $APP (version $VERSION, macOS $NFM_MACOS_MIN+, $ARCHS)"
