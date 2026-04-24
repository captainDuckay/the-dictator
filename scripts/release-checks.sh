#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-checks.sh --version X.Y.Z

Hard-fail checks:
  - clean git working tree
  - release tag vX.Y.Z exists and points to HEAD
  - current branch has upstream
  - local branch is fully synced with upstream (no ahead/behind)
EOF
}

VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
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

TAG="v$VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "❌ Working tree is dirty. Commit/stash changes before release."
  exit 1
fi

echo "✅ Working tree is clean"

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "❌ Tag not found: $TAG"
  exit 1
fi

echo "✅ Tag exists: $TAG"

TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
HEAD_COMMIT="$(git rev-parse HEAD)"
if [[ "$TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
  echo "❌ Tag $TAG does not point to HEAD"
  echo "   tag:  $TAG_COMMIT"
  echo "   head: $HEAD_COMMIT"
  exit 1
fi

echo "✅ Tag $TAG points to HEAD"

if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  echo "❌ Current branch has no upstream tracking branch"
  exit 1
fi

UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
read -r BEHIND AHEAD <<<"$(git rev-list --left-right --count "${UPSTREAM}...HEAD")"

if [[ "$AHEAD" != "0" || "$BEHIND" != "0" ]]; then
  echo "❌ Branch is not fully synced with upstream ($UPSTREAM)."
  echo "   behind=$BEHIND ahead=$AHEAD"
  exit 1
fi

echo "✅ Branch is synced with upstream: $UPSTREAM"
echo "✅ Release checks passed for $TAG"
