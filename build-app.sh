#!/bin/bash
# Assembly only; never installs, registers a login item or starts the app.
# ./build-app.sh [debug|release] [--preview]
# Release: export HEYDOT_APPROVED_CERT_SHA1 (40 hex) for an identity in `security find-identity -v -p codesigning`.
# HEYDOT_NOTARY_PROFILE (a `notarytool store-credentials` profile) also timestamps, notarizes and staples the app.
# --preview: an unsigned bundle for fixtures and screenshots only. Never ad-hoc signed, never distributed.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
PREVIEW="${2:-}"
APP="HeyDot.app"
[[ "$PREVIEW" != "--preview" ]] || APP="HeyDotPreview.app"
[[ "$CONFIG" == "debug" || "$CONFIG" == "release" ]] || { echo "Expected debug or release" >&2; exit 64; }
[[ -z "$PREVIEW" || "$PREVIEW" == "--preview" ]] || { echo "Expected --preview" >&2; exit 64; }
source Scripts/model-files.sh
# Sparkle compares CFBundleVersion, so every release raises HEYDOT_BUILD.
VERSION="${HEYDOT_VERSION:-0.1.0}"
BUILD="${HEYDOT_BUILD:-1}"
# HEYDOT_FEED_URL points a test build at a local appcast; releases use the repo's.
FEED_URL="${HEYDOT_FEED_URL:-https://raw.githubusercontent.com/thaninbew/heydot/main/appcast.xml}"
# Verifies every update's EdDSA signature. The private half stays in the maintainer's keychain.
SPARKLE_PUBLIC_KEY="3Aj+pajIqRlTjpbkGUq4nX027HmsN71RdzQ0SXqQpmA="
if [[ "$PREVIEW" != "--preview" ]]; then
  if [[ -n "${HEYDOT_NOTARY_PROFILE:-}" && ( -z "${HEYDOT_VERSION:-}" || -z "${HEYDOT_BUILD:-}" ) ]]; then
    echo "Set HEYDOT_VERSION and HEYDOT_BUILD explicitly for a notarized build." >&2
    exit 78
  fi
  CERT="${HEYDOT_APPROVED_CERT_SHA1:-}"
  [[ "$CERT" =~ ^[[:xdigit:]]{40}$ ]] || { echo "HEYDOT_APPROVED_CERT_SHA1 (40 hex) is required. No ad-hoc fallback. Use --preview for fixtures only." >&2; exit 78; }
  CERT="$(printf '%s' "$CERT" | tr '[:lower:]' '[:upper:]')"
  IDENTITY="$(security find-identity -v -p codesigning | awk -v cert="$CERT" '$2 == cert {print}')"
  [[ -n "$IDENTITY" ]] || { echo "Certificate $CERT is not a valid code signing identity on this Mac." >&2; exit 78; }
  has_model_files "Vendor/models/$MODEL" || { echo "Speech model missing: run Scripts/fetch-vendor.sh first." >&2; exit 66; }
fi
swift build -c "$CONFIG" --product HeyDot
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/HeyDot" "$APP/Contents/MacOS/HeyDot"

# Sparkle, for self-updates. A non-sandboxed app installs updates without Sparkle's XPC services, so they aren't shipped.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"

# The keyword model, where the engine looks for it (Resources/models/<model>).
if has_model_files "Vendor/models/$MODEL"; then
  dest="$APP/Contents/Resources/models/$MODEL"
  mkdir -p "$dest"
  for file in "${MODEL_FILES[@]}"; do cp "Vendor/models/$MODEL/$file" "$dest/"; done
  cp licenses/sherpa-onnx/LICENSE "$dest/"
  if [[ -f "Vendor/models/$MODEL/README.md" ]]; then cp "Vendor/models/$MODEL/README.md" "$dest/"; fi
else
  echo "warning: speech model incomplete; this fixture bundle cannot listen." >&2
fi

cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R licenses "$APP/Contents/Resources/"

# App icon from the bundled designer master and hinted small reps (no external rasterizer needed).
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
"$BIN_DIR/HeyDot" --render-icon "$ICON_WORK"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>HeyDot</string>
<key>CFBundleDisplayName</key><string>HeyDot</string>
<key>CFBundleIdentifier</key><string>app.heydot.HeyDot</string>
<key>CFBundleExecutable</key><string>HeyDot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>HeyDot listens on this Mac for your dot's name so it can start the call. Wake-word audio is processed on device and never uploaded. During a voice call, microphone audio goes to ChatGPT.</string>
<key>SUFeedURL</key><string>$FEED_URL</string>
<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>NSHumanReadableCopyright</key><string>HeyDot. Unofficial; not affiliated with OpenAI.</string>
</dict></plist>
PLIST

if [[ "$PREVIEW" == "--preview" ]]; then
  plutil -replace CFBundleIdentifier -string app.heydot.HeyDot.preview "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "HeyDot Preview" "$APP/Contents/Info.plist"
  plutil -insert HeyDotFixtureOnly -bool YES "$APP/Contents/Info.plist"
  plutil -remove SUFeedURL "$APP/Contents/Info.plist"
  echo "Unsigned fixture-only assembly: $PWD/$APP. Not signed, installed or registered."
  exit 0
fi

# Debug symbols are a third of the binary and nothing at run time needs them (Xcode strips release apps the same way).
strip "$APP/Contents/MacOS/HeyDot"
# SwiftPM's build-folder rpath would load an unsigned Sparkle from this checkout instead of the bundled one.
otool -l "$APP/Contents/MacOS/HeyDot" | awk '/LC_RPATH/ {getline; getline; print $2}' | { grep "^$PWD/" || true; } | while read -r path; do
  install_name_tool -delete_rpath "$path" "$APP/Contents/MacOS/HeyDot"
done
# Notarization needs a secure timestamp; unnotarized local builds skip that network call.
NOTARY="${HEYDOT_NOTARY_PROFILE:-}"
TIMESTAMP=--timestamp=none
[[ -z "$NOTARY" ]] || TIMESTAMP=--timestamp
# Sparkle ships ad-hoc signed; its helpers are re-signed with the app's certificate, innermost first.
for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force --options runtime "$TIMESTAMP" --sign "$CERT" "$item"
done
# codesign's default designated requirement: the Team ID for an Apple-issued certificate, so it survives renewal.
codesign --force --options runtime "$TIMESTAMP" --sign "$CERT" --entitlements Resources/HeyDot.entitlements "$APP"
codesign --verify --strict --deep "$APP"
if [[ -n "$NOTARY" ]]; then
  ditto -c -k --keepParent "$APP" "$ICON_WORK/HeyDot.zip"
  xcrun notarytool submit "$ICON_WORK/HeyDot.zip" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute -vv "$APP"
fi
echo "Signed assembly: $PWD/$APP. Not installed or registered."
