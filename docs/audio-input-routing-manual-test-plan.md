# Audio Input Routing Manual Test Plan

Use this checklist to verify microphone switching, preferred-device fallback, and route-safe capture behavior.

## Preconditions
- Build includes commit `43bc7c1`.
- App has Microphone permission.
- At least two input devices available for testing (e.g., built-in mic + AirPods Pro).
- Push-to-talk hotkey is configured and working.

---

## Test 1 — System Default mode: switch while idle

**Goal:** No crash, next capture follows current macOS default input.

### Steps
1. Open **Settings → Audio**.
2. Set **Input microphone** to **System Default**.
3. Confirm app is idle (not recording).
4. In macOS Sound settings, set input to **Built-in Mic**.
5. Press/hold push-to-talk briefly and release (sanity capture).
6. Change macOS input to **AirPods Pro** while app remains idle.
7. Press/hold push-to-talk again and release.

### Expected
- No crash.
- Recording starts/stops normally after each switch.
- No tap format mismatch failure.

---

## Test 2 — Specific mode, preferred device available

**Goal:** Selected preferred mic is used when available.

### Steps
1. Open **Settings → Audio**.
2. Select a specific mic (e.g., **AirPods Pro**) in **Input microphone**.
3. Ensure that device is connected/available.
4. Trigger push-to-talk recording.

### Expected
- Recording starts successfully.
- Status text indicates preferred mic in use (e.g., “Using AirPods Pro.”).
- No fallback notification appears.

---

## Test 3 — Specific mode, preferred device unavailable (fallback)

**Goal:** App falls back to System Default with one transition notification.

### Steps
1. Keep specific mic selected (e.g., AirPods Pro).
2. Disconnect/turn off selected mic.
3. Verify Settings shows selected entry as unavailable.
4. Trigger push-to-talk recording.

### Expected
- Recording still succeeds using System Default.
- Notification appears once:
  - “Preferred microphone unavailable. Using System Default input.”
- Repeated captures in same fallback state do **not** spam notifications.

---

## Test 4 — Preferred device restore

**Goal:** App returns to preferred mic and notifies once.

### Steps
1. Stay in fallback state from Test 3.
2. Reconnect selected preferred mic.
3. Trigger push-to-talk recording.

### Expected
- Recording succeeds.
- Preferred mic is used again.
- Notification appears once:
  - “Preferred microphone reconnected. Using <device name>.”

---

## Test 5 — Mid-recording physical input change

**Goal:** No mid-capture reroute; current capture completes safely.

### Steps
1. Start recording with push-to-talk held down.
2. While still recording, change/disconnect input device.
3. Release push-to-talk.
4. Start another capture.

### Expected
- In-progress capture ends without crash.
- Route adjustment applies on next capture.
- No format mismatch/tap install crash.

---

## Test 6 — Stress: repeated rapid route churn + PTT

**Goal:** Robustness under quick switching.

### Steps
1. Alternate between Built-in and AirPods input quickly (connect/disconnect and/or system default changes).
2. Repeatedly perform short push-to-talk captures during transitions.
3. Repeat for 1–2 minutes.

### Expected
- No crash.
- No uncaught exceptions from `installTapOnBus` format mismatch.
- If capture fails, app returns to idle gracefully and shows actionable recording failure message.

---

## Optional Diagnostics to Collect
- Console logs containing:
  - selected preference
  - resolved route (preferred/default/fallback)
  - device UID/name
  - input sample rate/channels
- Any notification timestamps to verify transition-only behavior.

---

## Pass Criteria
All six tests pass with no crashes and expected fallback/restore behavior.
