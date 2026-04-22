#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
MANIFEST_OVERRIDE="${2:-}"

if [[ -z "$APP_PATH" ]]; then
  echo "Usage: $0 /path/to/the-dictator.app [manifest-url-override]"
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ App bundle not found: $APP_PATH"
  exit 1
fi

RESOURCES="$APP_PATH/Contents/Resources"
CLI="$RESOURCES/bin/whisper-cli"
BASE_MODEL_A="$RESOURCES/models/base/model.bin"
BASE_MODEL_B="$RESOURCES/models/base.bin"
BASE_MODEL_C="$RESOURCES/base.bin"
PLACEHOLDER_CLI="$RESOURCES/BUNDLED-WHISPER-CLI.txt"
PLACEHOLDER_MODEL="$RESOURCES/BUNDLED-BASE-MODEL.txt"

failures=0

check_ok() {
  echo "✅ $1"
}

check_fail() {
  echo "❌ $1"
  failures=$((failures + 1))
}

echo "Release preflight for: $APP_PATH"

if [[ -f "$PLACEHOLDER_CLI" || -f "$PLACEHOLDER_MODEL" ]]; then
  check_fail "Placeholder marker files are still present in bundle resources."
else
  check_ok "No placeholder marker files detected in bundle resources."
fi

if [[ -x "$CLI" ]]; then
  if file "$CLI" | grep -Eq 'Mach-O.*executable'; then
    check_ok "Bundled whisper-cli is present and executable."
  else
    check_fail "whisper-cli exists but is not a Mach-O executable: $CLI"
  fi
else
  check_fail "Bundled whisper-cli is missing or not executable: $CLI"
fi

BASE_MODEL=""
for candidate in "$BASE_MODEL_A" "$BASE_MODEL_B" "$BASE_MODEL_C"; do
  if [[ -f "$candidate" ]]; then
    BASE_MODEL="$candidate"
    break
  fi
done

if [[ -n "$BASE_MODEL" ]]; then
  size_bytes=$(stat -f%z "$BASE_MODEL")
  if [[ "$size_bytes" -lt 10000000 ]]; then
    check_fail "Base model exists but is suspiciously small (${size_bytes} bytes): $BASE_MODEL"
  else
    check_ok "Bundled base model found: $BASE_MODEL (${size_bytes} bytes)"
  fi
else
  check_fail "Bundled base model not found in expected locations."
fi

plist="$APP_PATH/Contents/Info.plist"
manifest_url="$MANIFEST_OVERRIDE"
if [[ -z "$manifest_url" ]]; then
  manifest_url=$(defaults read "$plist" ModelManifestURL 2>/dev/null || true)
fi
if [[ -z "$manifest_url" ]]; then
  manifest_url="https://github.com/captainDuckay/the-dictator-models/releases/latest/download/manifest.json"
fi

check_ok "Manifest URL: $manifest_url"

tmp_manifest=$(mktemp)
if curl --fail --silent --show-error --location "$manifest_url" -o "$tmp_manifest"; then
  check_ok "Downloaded manifest successfully."

  if python3 - "$tmp_manifest" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open('r', encoding='utf-8') as f:
    data = json.load(f)

required_top = {"schemaVersion", "models"}
missing_top = required_top - data.keys()
if missing_top:
    raise SystemExit(f"Missing top-level keys: {', '.join(sorted(missing_top))}")

if not isinstance(data["models"], list) or not data["models"]:
    raise SystemExit("Manifest 'models' must be a non-empty array")

required_model = {
    "id", "level", "displayName", "technicalName", "diskBytes", "estimatedRamBytes",
    "sha256", "version", "bundled", "minAppVersion"
}

levels = {"tiny", "base", "small", "medium", "large"}
ids = set()
has_downloadable_non_base = False

for i, model in enumerate(data["models"]):
    if not isinstance(model, dict):
        raise SystemExit(f"Model at index {i} is not an object")
    missing = required_model - model.keys()
    if missing:
        raise SystemExit(f"Model '{model.get('id', i)}' missing keys: {', '.join(sorted(missing))}")

    if model["level"] not in levels:
        raise SystemExit(f"Model '{model['id']}' has invalid level: {model['level']}")

    ids.add(model["id"])
    if model.get("id") != "base" and model.get("downloadURL"):
        has_downloadable_non_base = True

if "base" not in ids:
    raise SystemExit("Manifest must include base model")

if not has_downloadable_non_base:
    raise SystemExit("Manifest should include at least one downloadable non-base model")

print("Manifest schema checks passed")
PY
  then
    check_ok "Manifest schema/content checks passed."
  else
    check_fail "Manifest schema/content validation failed."
  fi
else
  check_fail "Unable to download manifest from URL."
fi

rm -f "$tmp_manifest"

if [[ "$failures" -gt 0 ]]; then
  echo "\nPreflight failed with $failures issue(s)."
  exit 1
fi

echo "\nPreflight passed. Bundle + manifest are ship-ready."
