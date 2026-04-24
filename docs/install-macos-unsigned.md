# Install Guide (Unsigned macOS Build)

This app is currently distributed **without Apple notarization**.

macOS may warn that the app is from an unidentified developer. This is expected for this release channel.

## Install steps

1. Download either:
   - `the-dictator-<version>-arm64.dmg` (recommended), or
   - `the-dictator-<version>-arm64.zip`
2. (Optional) Verify checksum using `the-dictator-<version>-arm64.sha256`.
3. Move `The Dictator.app` to `/Applications`.
4. Launch from `/Applications`.

## If macOS blocks launch

1. In Finder, go to `/Applications`.
2. Right-click `The Dictator.app` → **Open**.
3. Click **Open** in the confirmation dialog.

If still blocked:

1. Open **System Settings → Privacy & Security**.
2. Scroll to security section and click **Open Anyway** for the app.

Advanced fallback:

```bash
xattr -dr com.apple.quarantine "/Applications/The Dictator.app"
```

(Use only if the standard right-click/open flow does not work.)
