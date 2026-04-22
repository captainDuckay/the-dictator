# Model Management Delivery Checklist

## Current status

### Done
- Managed model settings with migration from legacy `modelPath`
- Model catalog types for `tiny/base/small/medium/large`
- App-managed model storage in Application Support
- Manifest fetch + compatibility filtering
- Download with progress + cancel
- SHA-256 verification (when hash is provided)
- Managed model resolution in transcription path
- Bundled `whisper-cli` lookup (bundle-first, PATH fallback)
- Model Manager UI with status/actions/size+RAM hints
- Fallback catalog indicator + retry/backoff status
- Bundled base model registration logic
- Configurable `ModelManifestURL` via Info.plist key
- Xcode staging phase creates expected bundle paths (`Contents/Resources/bin` and `Contents/Resources/models/base`) for production artifacts

### Remaining for ship-ready
1. Bundle actual production artifacts
   - `Resources/bin/whisper-cli`
   - `Resources/models/base/model.bin`
2. Wire release manifest + model assets in GitHub Releases
   - real URLs
   - real SHA-256 values
   - versioned descriptors
3. End-to-end acceptance pass
   - fresh install offline path (base bundled)
   - online download/update/delete
   - hash mismatch handling
   - fallback-catalog behavior
4. Release documentation
   - user-facing setup/FAQ
   - internal packaging & release runbook

## Suggested finish sequence
1. Bundle artifacts and verify startup detects bundled base model.
   - Optional helper: `scripts/verify-bundled-assets.sh /path/to/the-dictator.app`
   - Ship preflight: `scripts/release-preflight.sh /path/to/the-dictator.app`
2. Publish first real manifest + one downloadable non-base model.
3. Re-run release preflight, then run manual QA matrix and fix any regression.
4. Freeze UI copy and prepare release build.
