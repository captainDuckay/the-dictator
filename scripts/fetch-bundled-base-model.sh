#!/usr/bin/env bash
set -euo pipefail

DEST="the-dictator/the-dictator/Resources/models/base/model.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"

mkdir -p "$(dirname "$DEST")"

echo "Downloading base model to $DEST"
curl --fail --location --progress-bar "$URL" -o "$DEST"

echo "Done."
shasum -a 256 "$DEST"
