# Local macOS Push-to-Talk Transcription App

## Planning Session Blueprint

This document captures the full planning decisions and implementation blueprint from the initial project planning session.

---

## 0) Locked decisions

### Core behavior
1. **Push-to-talk only** (press and hold to record, release to transcribe)
2. **No other trigger modes** (no toggle, no hands-free in MVP)
3. Ignore accidental taps with **minimum hold threshold = 250ms**
4. **Esc** cancels processing/insertion but keeps transcript recoverable

### Insertion policy
5. Transcribe on key release
6. Insert via **clipboard + simulated Cmd+V**
7. Use **best-effort clipboard restore** after paste attempt
8. If paste likely fails, show notification and keep transcript available via **Paste Last Transcript**
9. Never lose latest transcript in-session (memory-only)
10. If no target text field is active: no paste, notify, keep recoverable transcript

### Privacy/data behavior
11. **No persistence of transcript history**
12. Transcript is **memory-only**, plus temporary clipboard usage for paste flow
13. Local-only is a **product policy**, not hard network enforcement

### UX
14. Visual recording indication: **both**
   - menu bar icon state
   - floating on-screen indicator
15. Audio cues: **optional toggle**, default OFF
16. Error feedback: **macOS notification only**
17. Menu bar menu: **Settings + Paste Last Transcript + Quit**
18. Paste Last Transcript remains available **until next successful dictation**

### Settings scope (MVP)
19. Hotkey
20. Backend/model selection
21. Model path
22. Preferred language + auto-detect toggle
23. Audio cues on/off
24. Polished output toggle (default ON)

### Platform/stack
25. Native **Swift + SwiftUI** menu bar app
26. Distribution target: **personal/dev use only** (no notarization initially)
27. First engine: **whisper.cpp**
28. Backend architecture: **pluggable interface from day 1**
29. Performance target: **~1–2s latency** for short utterances

### Explicit non-goals for MVP
30. No persistent transcript history
31. No cloud sync
32. No hands-free mode
33. No voice commands
34. No per-app writing styles
35. No onboarding wizard

---

## 1) Product requirements (implementation-level)

### Functional requirements
1. Global hotkey down starts capture if app state = idle
2. While key held:
   - mic captures audio
   - recording indicator visible
3. Hotkey up ends capture
4. If hold < 250ms, discard and return idle
5. If valid capture:
   - run local transcription backend
   - produce polished text (unless toggle off)
6. Insert text into currently focused app using paste pipeline
7. If insertion fails:
   - notify
   - store transcript in memory for manual “Paste Last Transcript”
8. “Paste Last Transcript” command available from:
   - menu item
   - hotkey (configurable)
9. Clipboard restore best-effort after insertion attempt
10. On cancel (Esc) during processing:
   - stop processing/insertion
   - keep recoverable transcript
11. No transcript persistence to disk

### Non-functional requirements
1. App remains responsive during transcription
2. No crashes on permission denial
3. Graceful backend failure handling
4. All failures user-visible via notification
5. Stable behavior under rapid repeat use

---

## 2) Technical architecture (module plan)

### App modules
1. **AppShell**
   - SwiftUI app lifecycle
   - MenuBarExtra + settings window

2. **HotkeyService**
   - Global hotkey registration
   - keyDown/keyUp events
   - debouncing and suppression rules

3. **AudioCaptureService**
   - AVAudioEngine input capture
   - buffer lifecycle
   - encode to WAV/PCM for backend

4. **TranscriptionService**
   - orchestrates backend calls
   - timeout + cancellation
   - output normalization

5. **BackendProtocol** (pluggable interface)
   - `load(config)`
   - `transcribe(audioURL, options) -> TranscriptResult`
   - `capabilities()`

6. **WhisperCppBackend** (first implementation)
   - manage model path/runtime
   - invoke whisper.cpp binary/library
   - parse output + errors

7. **TextInsertionService**
   - focused target checks (best-effort)
   - clipboard save/set/restore
   - Cmd+V event injection
   - paste failure detection heuristic

8. **ClipboardService**
   - snapshot pasteboard contents/types
   - set transcript string
   - restore best-effort

9. **IndicatorService**
   - menu icon states
   - floating recording indicator window

10. **NotificationService**
   - unified macOS notification display

11. **PermissionsService**
   - microphone access flow
   - accessibility permission checks
   - actionable prompts

12. **SettingsStore**
   - persist app settings (not transcript data)
   - validation of keybinds/model path/backend choice

13. **SessionStore (memory-only)**
   - last transcript
   - current workflow state
   - no disk writes

---

## 3) State machine (must implement exactly)

States:
1. `idle`
2. `recording`
3. `transcribing`
4. `inserting`
5. `error` (transient routing state)

Transitions:
- `idle -> recording` on hotkeyDown (if permissions OK)
- `recording -> idle` if keyUp and duration < 250ms
- `recording -> transcribing` on valid keyUp
- `transcribing -> inserting` on transcript success
- `transcribing -> idle` on cancel/error (with notifications as needed)
- `inserting -> idle` on success
- `inserting -> idle` on failure (last transcript remains recoverable)

Global interrupt:
- Esc during transcribing/inserting => cancel + `idle`

---

## 4) Insert/paste pipeline spec (precise behavior)

1. Capture target context (best-effort)
2. Save clipboard snapshot
3. Set pasteboard string = transcript
4. Dispatch Cmd+V to focused app
5. Wait verification window (500–800ms)
6. If likely success:
   - best-effort restore clipboard
   - clear recoverable transcript only after confirmed successful cycle
7. If likely failure:
   - keep transcript in memory
   - show notification with “use Paste Last Transcript”
   - best-effort restore clipboard

Manual fallback:
- “Paste Last Transcript” repeats set clipboard + Cmd+V flow with current in-memory transcript

---

## 5) Permissions and OS integration checklist

### Required permissions
1. Microphone
2. Accessibility (for input simulation / UI automation paths)

### JIT permission UX
1. User action triggers capability
2. If permission missing:
   - show exact reason
   - provide actionable steps to System Settings location
3. Retry path immediately available

---

## 6) Settings schema (MVP)

1. `pushToTalkHotkey`
2. `pasteLastTranscriptHotkey`
3. `backendType` (initially whisper.cpp)
4. `modelPath`
5. `languageAutoDetect: Bool`
6. `preferredLanguage`
7. `audioCuesEnabled: Bool` (default false)
8. `polishedOutputEnabled: Bool` (default true)

No transcript settings. No history toggle in MVP.

---

## 7) Error handling matrix (must cover)

1. No microphone permission
2. Accessibility permission missing
3. Mic hardware unavailable
4. Model path missing/invalid
5. Backend load failure
6. Backend runtime crash/timeout
7. Empty transcript result
8. Paste injection failure
9. Clipboard restore partial failure
10. No active target field
11. App focus changed mid-process
12. Cancellation by Esc

All should yield deterministic notification copy and safe return to idle.

---

## 8) Detailed implementation backlog (non-compact)

### Milestone 1 — App skeleton + state foundation
1. Create SwiftUI menu bar app shell
2. Implement central `AppState` + state machine scaffolding
3. Implement menu items: Settings, Paste Last Transcript, Quit
4. Implement placeholder floating indicator window
5. Add notification utility wrapper
6. Add settings window scaffold + persistent settings store
7. Add logging scaffolding (dev-only)

### Milestone 2 — Input + recording
1. Implement global hotkey registration
2. Handle keyDown/keyUp lifecycle
3. Enforce 250ms threshold
4. Implement AVAudioEngine capture start/stop
5. Buffer and write audio clips for backend
6. Add recording indicator live states
7. Add optional audio cues toggle plumbing (OFF default)

### Milestone 3 — Backend abstraction + whisper.cpp
1. Define backend protocol/interfaces
2. Implement whisper.cpp backend adapter
3. Load model from user-selected path
4. Add language options + auto-detect mapping
5. Add polished output post-processing toggle branch
6. Add cancellation support for in-flight transcription
7. Add timeout/error translation to app-level errors

### Milestone 4 — Insertion and recovery flow
1. Implement clipboard snapshot/restore best-effort
2. Implement text paste (Cmd+V event injection)
3. Implement insertion verification heuristic
4. Implement fail path notification
5. Implement memory-only last transcript store
6. Implement “Paste Last Transcript” action
7. Implement cleanup: clear last transcript on next successful dictation

### Milestone 5 — Permissions + UX hardening
1. JIT permission prompts with guided instructions
2. Add first-run checks without blocking app usage
3. Add robust handling for denied/revoked permissions
4. Confirm indicator behavior across Spaces/fullscreen apps
5. Confirm menu bar and settings reliability under repeated sessions

### Milestone 6 — Reliability and performance tuning
1. Measure latency pipeline segments (capture stop → transcript ready → inserted)
2. Tune whisper.cpp settings for 1–2s target
3. Optimize temporary file flow
4. Harden against repeated rapid dictations
5. Validate Esc cancellation race conditions
6. Add protective guards for concurrent sessions (single active only)

---

## 9) Test plan (must run before calling MVP done)

### Manual functional tests
1. Hold-to-record/release flow in Notes, Slack, browser, IDE
2. <250ms press ignored
3. Long dictation transcribes and inserts
4. Esc cancel in transcribing and inserting states
5. No active text field behavior
6. Paste Last Transcript from menu and hotkey
7. Clipboard restoration with normal text clipboard
8. Clipboard restoration with rich clipboard content (best-effort expected)
9. Auto-detect language vs preferred language fallback
10. Audio cues toggle behavior

### Permission tests
1. Fresh install, no permissions
2. Microphone denied then granted
3. Accessibility denied then granted
4. Permission revoked while app running

### Failure tests
1. Invalid model path
2. Backend crash simulation
3. Paste blocked app simulation
4. Fast repeated trigger stress

---

## 10) Definition of done (MVP)

MVP is done when:
1. All product decisions are implemented exactly
2. No transcript is persisted to disk
3. Push-to-talk flow is stable across common macOS apps
4. Fallback recovery path works every time
5. User always gets clear notifications on failure
6. Average short-utterance latency is within target band in normal conditions

---

## 11) Notes from Wispr Flow research (inspiration reference)

Research from public Wispr Flow docs suggests:
1. Desktop insertion is clipboard + simulated paste keystroke
2. They save and restore clipboard contents after insertion
3. They provide explicit **Paste Last Transcript** fallback shortcuts and tray actions
4. They acknowledge blocked environments (Citrix/VDI, some terminals, secure apps)

This project intentionally adopts a similar insertion reliability model while remaining strictly local-model focused and minimal.
