#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
Deprecated: scripts/release-publish-draft.sh

Canonical release path is GitHub Actions on release.published events.

How to publish now:
1) Create/publish a GitHub Release for tag vX.Y.Z
2) Workflow .github/workflows/release-artifacts.yml builds and uploads artifacts

No local draft publish script is used in the new flow.
EOF
