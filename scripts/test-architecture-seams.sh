#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BIN="$(mktemp -t architecture-seams-tests)"

swiftc \
  scripts/tests/architecture_seams_tests.swift \
  the-dictator/the-dictator/Core/AppSettingsInterfaces.swift \
  the-dictator/the-dictator/Core/ModelManagerModule.swift \
  the-dictator/the-dictator/Models/WhisperModelCatalog.swift \
  the-dictator/the-dictator/Services/AppLogger.swift \
  the-dictator/the-dictator/Services/ModelCatalogService.swift \
  the-dictator/the-dictator/Services/ModelDownloadService.swift \
  the-dictator/the-dictator/Services/ModelIntegrityService.swift \
  the-dictator/the-dictator/Services/ModelStoreService.swift \
  the-dictator/the-dictator/Services/RuntimeReadinessService.swift \
  -o "$BIN"

"$BIN"
rm -f "$BIN"
