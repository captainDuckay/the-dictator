#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-unsigned-release-artifacts.sh --version X.Y.Z [options]

Required:
  --version X.Y.Z

Optional:
  --project PATH       (default: the-dictator/the-dictator.xcodeproj)
  --scheme NAME        (default: the-dictator)
  --output-dir PATH    (default: out/release)
  --arch arm64         (default: arm64)
  --manifest-url URL   (pass-through to scripts/release-preflight.sh)
  -h, --help
EOF
}

VERSION=""
PROJECT="the-dictator/the-dictator.xcodeproj"
SCHEME="the-dictator"
OUTPUT_DIR="out/release"
ARCH="arm64"
MANIFEST_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
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

if [[ -z "$VERSION" ]]; then
  echo "❌ --version is required"
  usage
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Version must match X.Y.Z format (received: $VERSION)"
  exit 1
fi

for cmd in xcodebuild create-dmg shasum ditto lipo codesign; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Required command not found: $cmd"
    exit 1
  fi
done

if [[ ! -f "$PROJECT" ]]; then
  detected_projects=()
  while IFS= read -r p; do
    detected_projects+=("$p")
  done < <(find . -maxdepth 4 -type d -name "*.xcodeproj" | sort)

  if [[ "${#detected_projects[@]}" -eq 1 ]]; then
    PROJECT="${detected_projects[0]#./}"
    echo "⚠️ Provided project path not found; auto-detected project: $PROJECT"
  else
    echo "❌ Project not found: $PROJECT"
    if [[ "${#detected_projects[@]}" -gt 1 ]]; then
      echo "   Multiple .xcodeproj files detected. Pass --project explicitly."
      for p in "${detected_projects[@]}"; do
        echo "   - $p"
      done
    fi
    exit 1
  fi
fi

APP_NAME="The Dictator"
BUILD_DIR="$OUTPUT_DIR/build"
APP_BUILD_DIR="$BUILD_DIR/Build/Products/Release"
APP_PATH="$APP_BUILD_DIR/${APP_NAME}.app"
DMG_SRC_DIR="$OUTPUT_DIR/dmg-src"
DMG_PATH="$OUTPUT_DIR/the-dictator-${VERSION}-${ARCH}.dmg"
ZIP_PATH="$OUTPUT_DIR/the-dictator-${VERSION}-${ARCH}.zip"
SHA_PATH="$OUTPUT_DIR/the-dictator-${VERSION}-${ARCH}.sha256"

rm -rf "$BUILD_DIR" "$DMG_SRC_DIR" "$DMG_PATH" "$ZIP_PATH" "$SHA_PATH"
mkdir -p "$OUTPUT_DIR" "$DMG_SRC_DIR"

echo "==> Building unsigned app"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ Built app not found: $APP_PATH"
  exit 1
fi

APP_BINARY="$APP_PATH/Contents/MacOS/the-dictator"
ARCHS="$(lipo -archs "$APP_BINARY" 2>/dev/null || true)"
if [[ "$ARCH" == "arm64" && "$ARCHS" != "arm64" ]]; then
  echo "❌ Expected arm64-only build, got: $ARCHS"
  exit 1
fi

echo "✅ App binary architecture: $ARCHS"

echo "==> Applying ad-hoc signature (non-notarized)"
codesign --force --sign - --timestamp=none --deep "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "✅ Ad-hoc signature verified"

echo "==> Running release bundle preflight"
if [[ -n "$MANIFEST_URL" ]]; then
  scripts/release-preflight.sh "$APP_PATH" "$MANIFEST_URL"
else
  scripts/release-preflight.sh "$APP_PATH"
fi

cp -R "$APP_PATH" "$DMG_SRC_DIR/"

echo "==> Creating DMG"
create-dmg \
  --volname "$APP_NAME" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "${APP_NAME}.app" 175 190 \
  --app-drop-link 425 190 \
  "$DMG_PATH" \
  "$DMG_SRC_DIR"

echo "==> Creating ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Writing checksums"
{
  shasum -a 256 "$DMG_PATH"
  shasum -a 256 "$ZIP_PATH"
} > "$SHA_PATH"

echo "✅ Artifacts ready:"
echo "   $DMG_PATH"
echo "   $ZIP_PATH"
echo "   $SHA_PATH"
