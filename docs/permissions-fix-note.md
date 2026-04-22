# Permission Fix Note (Microphone)

Date: 2026-04-22

## Issue

The app could request microphone permission but still not appear under:

- System Settings → Privacy & Security → Microphone

Accessibility permission worked, which made the issue confusing.

## Root cause

The app was signed with Hardened Runtime and lacked the microphone entitlement:

- `com.apple.security.device.audio-input`

Without this entitlement, microphone access can fail and the app may never be listed in microphone privacy settings.

## Fix

1. Added entitlements file:
   - `the-dictator/the-dictator/the-dictator.entitlements`
2. Added microphone entitlement:
   - `com.apple.security.device.audio-input = true`
3. Wired entitlements in target build settings (Debug + Release):
   - `CODE_SIGN_ENTITLEMENTS = "the-dictator/the-dictator.entitlements"`
4. Kept microphone usage string in Info.plist generation:
   - `NSMicrophoneUsageDescription`
5. Updated runtime permission API path to prefer `AVAudioApplication` on modern macOS.

## Follow-up UX improvements

- Added menu action: **Open Microphone Privacy Settings**
- Added Settings → Permissions section with live status + refresh action
- Removed redundant unused microphone permission method from `AudioCaptureService`
