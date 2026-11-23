#!/bin/bash
# Assembly only; never installs, registers a login item or starts the app.
# ./build-app.sh [debug|release] [--preview]
# Release: export HEYDOT_APPROVED_CERT_SHA1 (40 hex) for an identity in `security find-identity -v -p codesigning`.
# --preview: an unsigned bundle for fixtures and screenshots only. Never ad-hoc signed, never distributed.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
PREVIEW="${2:-}"
APP="HeyDot.app"
[[ "$PREVIEW" != "--preview" ]] || APP="HeyDotPreview.app"
[[ "$CONFIG" == "debug" || "$CONFIG" == "release" ]] || { echo "Expected debug or release" >&2; exit 64; }
[[ -z "$PREVIEW" || "$PREVIEW" == "--preview" ]] || { echo "Expected --preview" >&2; exit 64; }
MODEL=sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
if [[ "$PREVIEW" != "--preview" ]]; then
  CERT="${HEYDOT_APPROVED_CERT_SHA1:-}"
  [[ "$CERT" =~ ^[[:xdigit:]]{40}$ ]] || { echo "HEYDOT_APPROVED_CERT_SHA1 (40 hex) is required. No ad-hoc fallback. Use --preview for fixtures only." >&2; exit 78; }
  CERT="$(printf '%s' "$CERT" | tr '[:lower:]' '[:upper:]')"
  IDENTITY="$(security find-identity -v -p codesigning | awk -v cert="$CERT" '$2 == cert {print}')"
  [[ -n "$IDENTITY" ]] || { echo "Certificate $CERT is not a valid code signing identity on this Mac." >&2; exit 78; }
  [[ -s "Vendor/models/$MODEL/tokens.txt" ]] || { echo "Speech model missing: run Scripts/fetch-vendor.sh first." >&2; exit 66; }
fi
swift build -c "$CONFIG" --product HeyDot
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/HeyDot" "$APP/Contents/MacOS/HeyDot"

# The keyword model, where the engine looks for it (Resources/models/<model>).
if [[ -d "Vendor/models/$MODEL" ]]; then
  mkdir -p "$APP/Contents/Resources/models"
  # Runtime model inputs and their provenance (no fp32 copies or sample audio).
  rsync -a --include '*.int8.onnx' --include 'tokens.txt' --include 'bpe.model' --include 'README.md' --exclude '*' \
    "Vendor/models/$MODEL/" "$APP/Contents/Resources/models/$MODEL/"
else
  echo "warning: Vendor/models/$MODEL missing; the bundle cannot listen until Scripts/fetch-vendor.sh runs." >&2
fi

cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R licenses "$APP/Contents/Resources/"
cp licenses/sherpa-onnx/LICENSE "$APP/Contents/Resources/models/$MODEL/LICENSE"

# App icon from the bundled designer master and hinted small reps (no external rasterizer needed).
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
"$BIN_DIR/HeyDot" --render-icon "$ICON_WORK"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>HeyDot</string>
<key>CFBundleDisplayName</key><string>HeyDot</string>
<key>CFBundleIdentifier</key><string>app.heydot.HeyDot</string>
<key>CFBundleExecutable</key><string>HeyDot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>HeyDot listens on this Mac for your dot's name so it can start the call. Wake-word audio is processed on device and never uploaded. During a voice call, microphone audio goes to ChatGPT.</string>
<key>NSHumanReadableCopyright</key><string>HeyDot. Unofficial; not affiliated with OpenAI.</string>
</dict></plist>
PLIST

if [[ "$PREVIEW" == "--preview" ]]; then
  plutil -replace CFBundleIdentifier -string app.heydot.HeyDot.preview "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "HeyDot Preview" "$APP/Contents/Info.plist"
  plutil -insert HeyDotFixtureOnly -bool YES "$APP/Contents/Info.plist"
  echo "Unsigned fixture-only assembly: $PWD/$APP. Not signed, installed or registered."
  exit 0
fi

# Debug symbols are a third of the binary and nothing at run time needs them (Xcode strips release apps the same way).
strip "$APP/Contents/MacOS/HeyDot"
APP_REQ="identifier \"app.heydot.HeyDot\" and certificate leaf = H\"$CERT\""
codesign --force --options runtime --timestamp=none --sign "$CERT" --requirements "=designated => $APP_REQ" \
  --entitlements Resources/HeyDot.entitlements "$APP"
codesign --verify --strict --deep "$APP"
echo "Signed assembly: $PWD/$APP. Not installed or registered."
