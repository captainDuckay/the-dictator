#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
  echo "Usage: $0 /path/to/The\ Dictator.app"
  exit 1
fi

RESOURCES="$APP_PATH/Contents/Resources"
CLI="$RESOURCES/bin/whisper-cli"
BASE_MODEL_A="$RESOURCES/models/base/model.bin"
BASE_MODEL_B="$RESOURCES/models/base.bin"
BASE_MODEL_C="$RESOURCES/base.bin"

echo "Checking bundled assets in: $APP_PATH"

if [[ -x "$CLI" ]]; then
  echo "✅ whisper-cli executable found: $CLI"
else
  echo "❌ whisper-cli missing or not executable: $CLI"
fi

if [[ -f "$BASE_MODEL_A" ]]; then
  echo "✅ base model found: $BASE_MODEL_A"
elif [[ -f "$BASE_MODEL_B" ]]; then
  echo "✅ base model found: $BASE_MODEL_B"
elif [[ -f "$BASE_MODEL_C" ]]; then
  echo "✅ base model found: $BASE_MODEL_C"
else
  echo "❌ base model not found in expected locations"
fi
