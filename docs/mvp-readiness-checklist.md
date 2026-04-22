# MVP Readiness Checklist (Audit)

Date: 2026-04-18

## 1) What was verified automatically

### Build
- ✅ `xcodebuild -project the-dictator/the-dictator.xcodeproj -scheme the-dictator -configuration Debug -sdk macosx build`

### Core milestone coverage (code-level)
- ✅ Milestone 1: app shell, settings window, state scaffolding, indicator placeholder, notifications, logging
- ✅ Milestone 2: global hotkey, recording, 250ms threshold, audio cues toggle plumbing
- ✅ Milestone 3: backend abstraction + whisper.cpp integration + cancellation/timeout mapping
- ✅ Milestone 4: clipboard snapshot/restore, Cmd+V insertion, fallback Paste Last Transcript flow
- ✅ Milestone 5: JIT + first-run permission UX for microphone/accessibility
- ✅ Milestone 6: latency tracking, rapid-repeat/session guards, Esc cancellation monitor, whisper thread tuning

### Privacy invariant check
- ✅ Transcript is memory-only (`SessionStore`)
- ✅ No transcript persistence to disk found
- ℹ️ Settings persist to `UserDefaults` (expected)

---

## 2) Manual test plan status (from blueprint)

These still require hands-on testing in real apps:

### Functional manual tests
- ⏳ Hold-to-record/release in Notes/Slack/browser/IDE
- ⏳ <250ms press ignored
- ⏳ Long dictation transcribes and inserts
- ⏳ Esc cancel in transcribing/inserting
- ⏳ No active text field behavior
- ⚠️ Paste Last Transcript from menu works; configurable hotkey not fully wired yet
- ⏳ Clipboard restore with normal text clipboard
- ⏳ Clipboard restore with rich clipboard content (best effort)
- ⏳ Auto-detect language vs preferred language
- ⏳ Audio cues toggle behavior

### Permission tests
- ⏳ Fresh install, no permissions
- ⏳ Microphone denied then granted
- ⏳ Accessibility denied then granted
- ⏳ Permission revoked while app running

### Failure tests
- ⏳ Invalid model path
- ⏳ Backend crash simulation
- ⏳ Paste blocked app simulation
- ⏳ Fast repeated trigger stress

---

## 3) Known gaps before calling MVP “done”

1. **Paste Last Transcript hotkey (configurable) is not fully implemented**
   - Menu action exists.
   - Dedicated configurable shortcut flow still needs wiring.

2. **Insertion verification heuristic is minimal**
   - Current check is primarily frontmost-app consistency after Cmd+V.
   - Could be improved for stronger confidence in secure/blocked contexts.

3. **No-active-text-field detection is best-effort only**
   - Works at app-target level; exact focused text-control verification is limited.

4. **Backend protocol in blueprint included `capabilities()`**
   - Current protocol does not yet expose `capabilities()`.

---

## 4) Suggested immediate manual run order

1. Grant permissions (mic + accessibility), confirm notifications and prompts.
2. Validate hold/release in Notes (baseline).
3. Validate clipboard restore behavior with plain text and rich clipboard payload.
4. Validate failure behavior in Terminal/secure fields (where paste may fail).
5. Validate fallback retry with Paste Last Transcript.
6. Stress test with rapid repeated dictation + Esc cancellation.

---

## 5) MVP decision guidance

- **Not yet ready to declare MVP done** until Section 2 manual tests complete and Section 3 gaps are accepted/closed.
- Codebase is in a strong state for final validation and gap closure.
