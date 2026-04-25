# the-dictator

<p align="center">
  <img src="docs/assets/the-dictator-desktop-artwork.svg" alt="The Dictator artwork" width="720" />
</p>

**Local-first push-to-talk dictation for macOS.**
Built for technical users who want fast speech-to-text without sending audio to the cloud.

## Why this product

The Dictator is designed to feel like a developer tool, not a consumer voice assistant:

- **Private by default** — transcription runs locally via `whisper.cpp`
- **Deterministic workflow** — hold key to record, release to transcribe/insert
- **Reliable fallback behavior** — if paste fails, transcript stays recoverable
- **Low-friction UX** — menu bar app with global shortcuts and minimal UI overhead

## Core capabilities

- Global **push-to-talk** hotkey (including modifier-only shortcuts)
- Local model support with built-in model management
- Optional **custom model path** for advanced users
- Clipboard-safe insertion pipeline with best-effort clipboard restore
- **Paste Last Transcript** action for recovery in blocked/secure app contexts
- Live runtime/permission status in Settings (mic + accessibility)

## How it works (in practice)

1. Hold your shortcut to record.
2. Release to run local transcription.
3. Text is inserted into the focused app (or kept ready for manual paste fallback).

## Installation (v1)

Download release artifacts from GitHub Releases:

- `the-dictator-<version>-arm64.dmg` (recommended)
- `the-dictator-<version>-arm64.zip`
- `the-dictator-<version>-arm64.sha256`

> Current distribution is unsigned/not notarized. See install guide for Gatekeeper steps.

## Documentation

- [Unsigned macOS install guide](docs/install-macos-unsigned.md)
- [v1 release runbook](docs/release-runbook-v1.md)
- [Audio input routing manual test plan](docs/audio-input-routing-manual-test-plan.md)
- [Release notes template](docs/release-notes-template.md)

## Optional local release build verification

```bash
scripts/build-unsigned-release-artifacts.sh --version 1.0.0
```

## Optional diagnostics in Release test builds

To enable audio routing/hotkey diagnostics without enabling full `DEBUG` behavior,
compile with `DIAGNOSTIC_AUDIO_ROUTING`:

```bash
xcodebuild \
  -scheme the-dictator \
  -configuration Release \
  -project the-dictator/the-dictator.xcodeproj \
  OTHER_SWIFT_FLAGS='$(inherited) -DDIAGNOSTIC_AUDIO_ROUTING' \
  build
```

Diagnostic lines are prefixed with `[diag.audio]`.
