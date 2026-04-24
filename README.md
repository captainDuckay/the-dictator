# the-dictator

## Documentation

- [Audio input routing manual test plan](docs/audio-input-routing-manual-test-plan.md)
- [v1 release runbook](docs/release-runbook-v1.md)
- [release notes template](docs/release-notes-template.md)

## Release (v1)

Prereqs:
- `create-dmg` installed (`brew install create-dmg`)
- Developer ID Application certificate in Keychain
- notarytool keychain profile configured (example: `AC_NOTARY`)
- `vX.Y.Z` tag exists on `HEAD`

Build + sign + notarize DMG:

```bash
scripts/release-dmg.sh \
  --version 1.0.0 \
  --identity "Developer ID Application: YOUR NAME (TEAMID)" \
  --notary-profile AC_NOTARY
```

Create draft GitHub release (after manual DMG install smoke test):

```bash
scripts/release-publish-draft.sh --version 1.0.0
```

Artifacts are written to `out/release/`:
- `the-dictator-<version>-arm64.dmg`
- `the-dictator-<version>-arm64.sha256`
