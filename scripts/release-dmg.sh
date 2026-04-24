#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-dmg.sh --version X.Y.Z --identity "Developer ID Application: ..." --notary-profile PROFILE [options]

Required:
  --version X.Y.Z
  --identity "Developer ID Application: ..."
  --notary-profile PROFILE

Optional:
  --project PATH                    (default: the-dictator/the-dictator.xcodeproj)
  --scheme NAME                     (default: the-dictator)
  --export-options-plist PATH       (default: scripts/ExportOptions-DeveloperID.plist)
  --output-dir PATH                 (default: out/release)
  --arch arm64                      (default: arm64)
  --manifest-url URL                (pass-through to release-preflight.sh)
  --force-preflight                 (continue even if release preflight fails)
  -h, --help
EOF
}

VERSION=""
IDENTITY=""
NOTARY_PROFILE=""
PROJECT="the-dictator/the-dictator.xcodeproj"
SCHEME="the-dictator"
EXPORT_OPTIONS="scripts/ExportOptions-DeveloperID.plist"
OUTPUT_DIR="out/release"
ARCH="arm64"
MANIFEST_URL=""
FORCE_PREFLIGHT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --export-options-plist)
      EXPORT_OPTIONS="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    --manifest-url)
      MANIFEST_URL="${2:-}"
      shift 2
      ;;
    --force-preflight)
      FORCE_PREFLIGHT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  echo "❌ --version, --identity, and --notary-profile are required"
  usage
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Version must match X.Y.Z format (received: $VERSION)"
  exit 1
fi

if [[ "$IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "❌ Signing identity must start with 'Developer ID Application:'"
  exit 1
fi

for cmd in xcodebuild create-dmg codesign spctl xcrun shasum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Required command not found: $cmd"
    exit 1
  fi
done

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
  echo "❌ Export options plist not found: $EXPORT_OPTIONS"
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -F "$IDENTITY" >/dev/null 2>&1; then
  echo "❌ Signing identity not found in keychain: $IDENTITY"
  exit 1
fi

echo "==> Running git safety checks"
scripts/release-checks.sh --version "$VERSION"

echo "==> Verifying project exists"
if [[ ! -f "$PROJECT" ]]; then
  echo "❌ Project not found: $PROJECT"
  exit 1
fi

ARCHIVE_PATH="$OUTPUT_DIR/the-dictator.xcarchive"
EXPORT_DIR="$OUTPUT_DIR/export"
APP_PATH="$EXPORT_DIR/the-dictator.app"
DMG_PATH="$OUTPUT_DIR/the-dictator-${VERSION}-${ARCH}.dmg"
SHA_PATH="$OUTPUT_DIR/the-dictator-${VERSION}-${ARCH}.sha256"
TMP_DMG_DIR="$OUTPUT_DIR/dmg-src"

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$TMP_DMG_DIR" "$DMG_PATH" "$SHA_PATH"
mkdir -p "$OUTPUT_DIR" "$TMP_DMG_DIR"

echo "==> Building archive"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  clean archive

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ Exported app not found at expected path: $APP_PATH"
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
APP_BINARY="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"

if [[ ! -f "$APP_BINARY" ]]; then
  echo "❌ App executable not found: $APP_BINARY"
  exit 1
fi

ARCHS="$(lipo -archs "$APP_BINARY" 2>/dev/null || true)"
if [[ "$ARCH" == "arm64" ]]; then
  if [[ "$ARCHS" != "arm64" ]]; then
    echo "❌ Expected arm64-only build, got architectures: $ARCHS"
    exit 1
  fi
fi

echo "✅ App binary architecture: $ARCHS"

echo "==> Running release bundle preflight"
if [[ -n "$MANIFEST_URL" ]]; then
  if ! scripts/release-preflight.sh "$APP_PATH" "$MANIFEST_URL"; then
    if [[ "$FORCE_PREFLIGHT" -eq 1 ]]; then
      echo "⚠️ release-preflight failed, continuing due to --force-preflight"
    else
      echo "❌ release-preflight failed"
      exit 1
    fi
  fi
else
  if ! scripts/release-preflight.sh "$APP_PATH"; then
    if [[ "$FORCE_PREFLIGHT" -eq 1 ]]; then
      echo "⚠️ release-preflight failed, continuing due to --force-preflight"
    else
      echo "❌ release-preflight failed"
      exit 1
    fi
  fi
fi

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

cp -R "$APP_PATH" "$TMP_DMG_DIR/"

echo "==> Building DMG via create-dmg"
create-dmg \
  --volname "the-dictator" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "the-dictator.app" 175 190 \
  --app-drop-link 425 190 \
  "$DMG_PATH" \
  "$TMP_DMG_DIR"

echo "==> Signing DMG"
codesign --force --sign "$IDENTITY" --timestamp --options runtime "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Final Gatekeeper assessment"
spctl --assess --type open --verbose=4 "$DMG_PATH"

echo "==> Generating checksum"
shasum -a 256 "$DMG_PATH" > "$SHA_PATH"

echo

echo "✅ Release artifacts ready:"
echo "   DMG: $DMG_PATH"
echo "   SHA: $SHA_PATH"
echo "\nNext: perform manual DMG install QA, then create draft GitHub release."
