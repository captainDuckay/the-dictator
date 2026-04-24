# v1 Release Runbook (Direct DMG Distribution)

Date: 2026-04-23
Owner: @captainDuckay

## 0) Locked decisions

- Distribution: **Direct download via GitHub Releases**
- Installer format: **DMG**
- DMG tool: **create-dmg** (third-party)
- Updates: **Manual in v1**, add auto-update later
- Architecture: **Apple Silicon only (arm64)**
- Base model: **Bundled in app**
- Release gate: **Strict**
- Publish flow: **Draft GitHub Release first**, then manual publish
- Approval: **Two-step** (build+verify → manual publish)
- Signing identity: **Developer ID Application**
- Notarization: **Notarize final DMG**
- Versioning: **Semver-like** (`1.0.0`, `1.0.1`, ...)
- Artifact naming: include version + arch (e.g. `the-dictator-1.0.0-arm64.dmg`)
- Git hygiene: **clean tree required** + tag-based release
- Fresh-machine test: **required for major/minor, optional for patches**
- Same-machine DMG install smoke test: **required every release**
- Launch at login: **setting exists, default OFF**
- First launch UX: **open Settings automatically** (no wizard)

---

## 1) Preconditions

## 1.1 Tooling

- Xcode + command line tools
- `create-dmg` installed
  - Example: `brew install create-dmg`
- Apple notarization tooling (`xcrun notarytool`, `xcrun stapler`)
- `gh` CLI logged in (for GitHub draft release)

## 1.2 Signing + notarization setup

- Valid **Developer ID Application** cert in keychain
- Notarytool keychain profile configured locally
  - Example profile name in this runbook: `AC_NOTARY`

## 1.3 Repo + content prerequisites

- Release commit on `main`
- Working tree clean, no uncommitted changes
- Tag exists for version (`vX.Y.Z`)
- Bundled assets prepared:
  - `Resources/bin/whisper-cli` (real executable)
  - `Resources/models/base/model.bin` (real base model)
- Existing preflight script must pass:
  - `scripts/release-preflight.sh`

---

## 2) Release inputs

Set these for each release:

- `VERSION` (example: `1.0.0`)
- `TAG` = `v$VERSION`
- `APP_NAME` = `the-dictator`
- `ARCH` = `arm64`
- `IDENTITY` = `Developer ID Application: <Your Name/Team>`
- `NOTARY_PROFILE` = `AC_NOTARY`

Artifact names:

- App bundle (exported): `the-dictator.app`
- DMG: `the-dictator-${VERSION}-${ARCH}.dmg`
- Checksums: `the-dictator-${VERSION}-${ARCH}.sha256`

---

## 3) Step-by-step release procedure

## 3.1 Git safety checks (hard fail)

1. Confirm clean tree:
   - `git status --porcelain` must be empty
2. Confirm tag exists and points to release commit:
   - `git rev-parse "v${VERSION}"`
3. Confirm current commit is pushed to remote

If any fails: abort.

## 3.2 Version + build settings

Ensure Xcode project release values are correct:

- `MARKETING_VERSION = ${VERSION}`
- `CURRENT_PROJECT_VERSION` incremented
- Deployment target and arch settings match intended release policy (arm64 only)

## 3.3 Build archive + export app

Example commands:

```bash
mkdir -p out/release

xcodebuild \
  -project the-dictator/the-dictator.xcodeproj \
  -scheme the-dictator \
  -configuration Release \
  -archivePath out/release/the-dictator.xcarchive \
  clean archive
```

Export a signed app from archive (with an `ExportOptions.plist` suitable for Developer ID distribution).

Expected output:

- `out/release/export/the-dictator.app`

## 3.4 Bundle/content preflight (hard fail)

Run existing script:

```bash
scripts/release-preflight.sh out/release/export/the-dictator.app
```

Policy: fail by default; optional future `--force` only for internal emergency drops.

## 3.5 Sign verification (hard fail)

Verify app signature + hardened runtime:

```bash
codesign --verify --deep --strict --verbose=2 out/release/export/the-dictator.app
spctl --assess --type execute --verbose=4 out/release/export/the-dictator.app
```

## 3.6 Build DMG with create-dmg

Stage app in temp folder, then:

```bash
create-dmg \
  --volname "the-dictator" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "the-dictator.app" 175 190 \
  --app-drop-link 425 190 \
  "out/release/the-dictator-${VERSION}-${ARCH}.dmg" \
  "out/release/export/"
```

## 3.7 Sign DMG (hard fail)

```bash
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  "out/release/the-dictator-${VERSION}-${ARCH}.dmg"

codesign --verify --verbose=2 "out/release/the-dictator-${VERSION}-${ARCH}.dmg"
```

## 3.8 Notarize DMG + staple (hard fail)

```bash
xcrun notarytool submit \
  "out/release/the-dictator-${VERSION}-${ARCH}.dmg" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "out/release/the-dictator-${VERSION}-${ARCH}.dmg"
```

## 3.9 Final Gatekeeper assessment (hard fail)

```bash
spctl --assess --type open --verbose=4 "out/release/the-dictator-${VERSION}-${ARCH}.dmg"
```

## 3.10 Generate checksum

```bash
shasum -a 256 "out/release/the-dictator-${VERSION}-${ARCH}.dmg" \
  > "out/release/the-dictator-${VERSION}-${ARCH}.sha256"
```

---

## 4) Required QA gate before draft release

## 4.1 Mandatory every release

1. Install from produced DMG on same machine
2. Move app to `/Applications`
3. Launch app and verify first-launch behavior
   - Settings opens automatically
   - Permissions guidance visible
4. Smoke test core dictation flow
5. Confirm `Paste Last Transcript` menu action works
6. Confirm app runs correctly from `/Applications`

## 4.2 Mandatory for major/minor (`X.Y.0` style)

- Fresh-machine or clean-user-account install test
- Permission flow re-validation (mic + accessibility)
- Core insertion flows in representative target apps

---

## 5) Draft GitHub Release flow

## 5.1 Create draft

- Tag: `v${VERSION}`
- Title: `${VERSION}`
- Upload artifacts:
  - `the-dictator-${VERSION}-${ARCH}.dmg`
  - `the-dictator-${VERSION}-${ARCH}.sha256`
- Add release notes + known issues section

## 5.2 Final manual approval

After confirming downloadable artifact works:

- Publish draft release

No automatic public publishing.

---

## 6) Release checklist (quick)

- [ ] Git clean + tag valid
- [ ] Release archive/export succeeded
- [ ] `release-preflight.sh` passed
- [ ] App signature verified
- [ ] DMG built + signed
- [ ] DMG notarized + stapled
- [ ] Final `spctl` passed
- [ ] SHA256 generated
- [ ] Same-machine DMG install smoke test passed
- [ ] Fresh-machine test passed (if major/minor)
- [ ] Draft GitHub release created with notes + known issues
- [ ] Manual final approval performed
- [ ] Release published

---

## 7) Next implementation items

1. Add `scripts/release-dmg.sh` orchestrator (hard-fail pipeline)
2. Add `scripts/release-checks.sh` for git/version/safety checks
3. Add `scripts/release-publish-draft.sh` for GitHub draft creation
4. Add `docs/release-notes-template.md`
5. Add `ExportOptions.plist` for Developer ID export

This runbook is the contract; scripts should implement it exactly.
