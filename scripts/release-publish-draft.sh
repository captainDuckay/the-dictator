#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-publish-draft.sh --version X.Y.Z [options]

Required:
  --version X.Y.Z

Optional:
  --artifact-dir PATH       (default: out/release)
  --arch arm64              (default: arm64)
  --notes-file PATH         (default: docs/release-notes-template.md)
  --repo OWNER/REPO         (default: detected from git remote origin)
  -h, --help
EOF
}

VERSION=""
ARTIFACT_DIR="out/release"
ARCH="arm64"
NOTES_FILE="docs/release-notes-template.md"
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
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

if ! command -v gh >/dev/null 2>&1; then
  echo "❌ gh CLI is required"
  exit 1
fi

if [[ -z "$REPO" ]]; then
  ORIGIN_URL="$(git remote get-url origin)"
  REPO="$(echo "$ORIGIN_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi

TAG="v$VERSION"
DMG_PATH="$ARTIFACT_DIR/the-dictator-${VERSION}-${ARCH}.dmg"
SHA_PATH="$ARTIFACT_DIR/the-dictator-${VERSION}-${ARCH}.sha256"
TMP_NOTES="$(mktemp)"

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "❌ Tag does not exist: $TAG"
  exit 1
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "❌ DMG artifact not found: $DMG_PATH"
  exit 1
fi

if [[ ! -f "$SHA_PATH" ]]; then
  echo "❌ SHA artifact not found: $SHA_PATH"
  exit 1
fi

if [[ ! -f "$NOTES_FILE" ]]; then
  echo "❌ Notes file not found: $NOTES_FILE"
  exit 1
fi

sed "s/{{VERSION}}/${VERSION}/g" "$NOTES_FILE" > "$TMP_NOTES"

echo "==> Creating draft GitHub release $TAG in $REPO"
gh release create "$TAG" \
  --repo "$REPO" \
  --draft \
  --title "$VERSION" \
  --notes-file "$TMP_NOTES" \
  "$DMG_PATH" \
  "$SHA_PATH"

rm -f "$TMP_NOTES"

echo "✅ Draft release created for $TAG"
