# the-dictator

## Documentation

- [Audio input routing manual test plan](docs/audio-input-routing-manual-test-plan.md)
- [v1 release runbook](docs/release-runbook-v1.md)
- [release notes template](docs/release-notes-template.md)
- [unsigned macOS install guide](docs/install-macos-unsigned.md)

## Release (v1)

Canonical release path is GitHub Actions on **GitHub Release published** (stable releases only).

Workflow output artifacts:
- `the-dictator-<version>-arm64.dmg`
- `the-dictator-<version>-arm64.zip`
- `the-dictator-<version>-arm64.sha256`

Optional local build verification:

```bash
scripts/build-unsigned-release-artifacts.sh --version 1.0.0
```
