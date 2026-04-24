# v1 Release Runbook (Public Unsigned Distribution)

Date: 2026-04-24

## Distribution model

- Public distribution via GitHub Releases
- **No Apple Developer Program enrollment**
- No Developer ID signing
- No notarization
- CI applies **ad-hoc code signing** to the app bundle before packaging (required release guard)
- Users may hit Gatekeeper warnings; install instructions are mandatory

## Canonical release path

Canonical path is GitHub Actions triggered by:

- `release.published`
- stable releases only (`prerelease == false`)

Workflow builds and uploads:

- `the-dictator-<version>-arm64.dmg`
- `the-dictator-<version>-arm64.zip`
- `the-dictator-<version>-arm64.sha256`

Before upload, CI must pass a release guard that verifies:
- `codesign --verify --deep --strict "out/release/build/Build/Products/Release/The Dictator.app"`
- signature is ad-hoc (`Signature=adhoc`)

## Required user-warning policy

Each public release must include unsigned macOS warning guidance.

The workflow auto-appends the standard warning block if missing.

Reference install guide:

- `docs/install-macos-unsigned.md`

## Local verification command (optional)

```bash
scripts/build-unsigned-release-artifacts.sh --version 1.0.0
```

This builds unsigned artifacts locally and runs existing release preflight checks.

## Release steps

1. Ensure release tag exists (`vX.Y.Z`) and points to intended commit.
2. Publish GitHub Release (stable, not prerelease).
3. GitHub Action builds artifacts and uploads them to the same release.
4. Validate release page contains:
   - DMG
   - ZIP
   - SHA256 file
   - unsigned install warning section

## Operational risks (accepted)

- Some users will see launch blocks/warnings.
- Some users may require right-click Open / Open Anyway flow.
- Support load increases compared to notarized distribution.

## Future upgrade path

When Apple Developer Program enrollment is available, migrate to:

- Developer ID signing
- notarization + staple
- stricter Gatekeeper trust path
