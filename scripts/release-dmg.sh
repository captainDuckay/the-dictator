#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then
  cat <<'EOF'
Deprecated: scripts/release-dmg.sh

This project now uses unsigned public release artifacts and GitHub Actions as the canonical release path.

Use:
  scripts/build-unsigned-release-artifacts.sh --version X.Y.Z

GitHub release publishing is triggered from GitHub Release (published) events.
EOF
  exit 0
fi

VERSION=""
ARGS=("$@")
for ((i=0; i<$#; i++)); do
  if [[ "${ARGS[$i]}" == "--version" && $((i+1)) -lt $# ]]; then
    VERSION="${ARGS[$((i+1))]}"
    break
  fi
done

if [[ -z "$VERSION" ]]; then
  echo "❌ Missing --version X.Y.Z"
  exit 1
fi

echo "⚠️ scripts/release-dmg.sh is deprecated; delegating to build-unsigned-release-artifacts.sh"
exec scripts/build-unsigned-release-artifacts.sh --version "$VERSION"
