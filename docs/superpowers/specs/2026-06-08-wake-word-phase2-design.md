# Wake Word "Hey Jarvis" (Gemma macOS app) — Phase 2 Design Spec

**Date:** 2026-06-08
**Status:** Approved (brainstorm), pending plan
**Repo:** `Gemma` (the macOS SwiftUI app, part of the `personal_agent` monorepo). The i3 backend is unchanged.
**Builds on:** Phase 1b in-app voice recorder (`VoiceController` / `AudioRecorder` / `VoiceClient`) + the i3 voice backend (`POST /v1/voice/turn`).

---

## 1. Motivation

Phase 1b made voice work via a manual mic tap. Phase 2 makes it **hands-free**: the app continuously listens for the wake phrase **"Hey Jarvis"** on-device, and on detection auto-captures the user's utterance, runs it through the existing voice pipeline, and speaks the reply — no tap. This is the next step toward the "distributed JARVIS" vision.

Per the user's architecture principle (i3 does heavy audio processing, devices are thin), only the **tiny wake-word model** runs on-device — it must, because the mic is on the Mac and streaming audio 24/7 to the i3 would defeat thin-client efficiency. The heavy STT → agent → TTS stays on the i3 (unchanged Phase 1b path).

Decisions locked in brainstorm: **openWakeWord** engine, **ONNX-native in Swift** (no extra process), **"Hey Jarvis"** stock pretrained model (no custom training).

## 2. Goals

1. An **always-listening toggle** in the app. When ON, the app continuously detects "Hey Jarvis" on-device via openWakeWord's ONNX pipeline running in Swift (onnxruntime).
2. On wake: auto-capture the user's utterance (16 kHz mono WAV, **energy-VAD silence endpointing**), hand it to the existing `VoiceController.send(wav)` (POST → play → show `you:`/`gemma:` in chat), then **re-arm**.
3. Reuse the Phase 1b voice path unchanged; only the *trigger* and *utterance capture* are new.
4. Robust + private: the mic is held continuously only while the toggle is ON; detection pauses during Gemma's playback; failures degrade to a chat notice without crashing.

## 3. Non-Goals

- **Barge-in / interrupting Gemma while she speaks** — Phase 4b. Detection is paused during playback.
- **Follow-up window** (replying without re-saying "Hey Jarvis") — deferred. Each turn re-arms the wake word.
- **Custom "Hey Gemma" model / training** — deferred; stock `hey_jarvis` is used. (Swapping in a custom `.onnx` later is a drop-in.)
- **Wake word on other devices (ESP32/phone)** — Phase 3.
- **Streaming STT/TTS** — Phase 4b; the per-turn flow stays non-streamed (Phase 1b).
- **Replacing tap-to-talk** — the manual mic button stays; the wake word is additive.
- **Speaker recognition** (only Roilan's voice) — Phase 4a.

## 4. Design

### 4.1 Architecture & data flow

```
[Toggle ON]   AVAudioEngine — one continuous 16 kHz mono input tap
   │ 80 ms frames (1280 samples, 16-bit PCM → Float)
   ▼
WakeWordDetector  (onnxruntime sessions, in-app)
   melspectrogram.onnx → embedding_model.onnx → hey_jarvis.onnx → score (0..1)
   │ score > threshold (0.5, tunable)  → "Hey Jarvis!"
   ▼
Utterance capture (same audio stream)  — buffer frames + energy-VAD endpointer
   │ record until ~0.8 s trailing silence (min speech guard) → 16 kHz mono WAV
   ▼
VoiceController.send(wav)   ← EXISTING (Phase 1b): POST /v1/voice/turn → AVAudioPlayer → append you:/gemma:
   │ wake detection PAUSED during sending + playback (no self-trigger, no barge-in)
   ▼ after reply → re-arm → back to listening
```

One `AVAudioEngine` runs the whole time the toggle is ON: its tap feeds the wake detector while *listening*, and the same frames are buffered for the utterance while *capturing*. The engine never stops between turns, so re-arm is instant.

### 4.2 Components — new in `Gemma/Gemma/Voice/`

**`WakeWordDetector.swift`** — the detection core.
- Loads three bundled ONNX models into `onnxruntime` sessions: `melspectrogram.onnx`, `embedding_model.onnx`, `hey_jarvis_v0.1.onnx` (openWakeWord release artifacts, Apache-2.0).
- Maintains a rolling buffer of embeddings (the wake model consumes a fixed window of recent embedding frames — exact count read from the model at load time / matched to openWakeWord's reference).
- `func process(frame: [Float]) -> Float` — feed one 80 ms frame (1280 samples), returns the current wake score. Internally: append to audio buffer → when enough audio, run melspectrogram → embedding → append to embedding buffer → when enough embeddings, run the wake model → score. Caller fires on `score > threshold`, then calls `reset()` (clear buffers) to avoid immediate re-trigger.
- Exact tensor shapes (melspec output frames, embedding window, wake-model input length) are pinned at implementation by inspecting the model files + openWakeWord's reference inference (`openwakeword/model.py`), not guessed.
- Defined behind a small `WakeDetecting` protocol (`process(frame:) -> Float`, `reset()`) so `WakeListener` is testable with a fake.

**`WakeListener.swift`** (`@MainActor @Observable`) — the always-listening orchestrator.
- Owns one `AVAudioEngine` configured for 16 kHz mono, installs a tap delivering 80 ms buffers (using `AVAudioConverter` if the hardware format differs — convert to 16 kHz mono Float).
- State: `enum WakeState { case off, listening, capturing, busy }` (`busy` = the VoiceController is sending/playing).
- `enabled` (the toggle): `enable()` requests mic permission (reuse `AudioRecorder.requestPermission`), starts the engine → `listening`; `disable()` stops the engine → `off`.
- In `listening`: each frame → `detector.process(frame)`; on wake → `detector.reset()`, switch to `capturing`, start an `EnergyEndpointer`.
- In `capturing`: accumulate raw PCM frames + feed each to the `EnergyEndpointer`; on end-of-utterance (or a max-duration cap, e.g. 15 s) → build a 16 kHz mono WAV → set `busy` → `await voice.send(wav)` (the existing Phase 1b method that POSTs, appends `you:`/`gemma:`, and plays) → on completion → back to `listening` (re-arm). If too little speech was captured → discard, re-arm.
- During `busy`, incoming frames are ignored (no detection while sending/playing — prevents self-trigger and overlap).
- Injected, like `VoiceController`, with `appendLine` (for status/errors in the chat) — reuses the same chat log.

**`EnergyEndpointer.swift`** — pure-logic silence endpointer for the post-wake utterance.
- RMS-energy based: tracks per-frame energy; signals end-of-utterance after `silence_ms` (~800 ms) of sub-threshold frames following at least `min_speech_ms` of speech. Mirrors the Phase-1b client `VadEndpointer` shape (frame-flag in → Bool out), but energy-driven (no webrtcvad dependency). Unit-testable with synthetic energy sequences.

### 4.3 Reuse of Phase 1b

`VoiceController.send(wav:)` is reused **unchanged** — it already POSTs to `/v1/voice/turn`, decodes the reply, appends `you:`/`gemma:` to `agentLog`, and plays the audio, with all the error handling. Wake mode only produces the WAV a different way (auto-capture vs the `AudioRecorder` tap). `WakeListener` calls `model.voice.send(wav)` and observes `model.voice.state` to know when playback finishes (to re-arm). The manual `AudioRecorder` tap-to-talk path is untouched.

### 4.4 Dependency & artifacts

- **onnxruntime** for macOS, added like the existing GRDB SPM package (`XCRemoteSwiftPackageReference`) — via the official onnxruntime Swift/C package or its macOS XCFramework. This is the main new dependency.
- **Model files** bundled in the app target (`Gemma/Gemma/Voice/Models/`): `melspectrogram.onnx`, `embedding_model.onnx`, `hey_jarvis_v0.1.onnx`, fetched once from openWakeWord's GitHub releases. Loaded from the bundle at startup.

### 4.5 UI / control

- An **"Escucha (Hey Jarvis)" toggle** in the chat toolbar (`AgentChatView`), bound to `model.wake.enabled`. When ON, a clear listening indicator (e.g. an animated/colored mic-wave icon) shows the app is listening; the indicator reflects `WakeState` (listening / capturing / busy).
- The existing manual mic button stays. The two can't fight: while the wake toggle is ON and capturing/busy, the manual mic is disabled (and vice-versa, manual recording pauses wake detection).
- `HarnessModel` gains `let wake: WakeListener` (built like `voice`), wired with `appendLine` + a reference to `voice`.

### 4.6 Errors & resilience

| Case | Behavior |
|---|---|
| Mic permission denied | Toggle reverts to OFF + a chat notice. |
| onnxruntime / model load fails | Wake toggle disabled + a chat notice ("wake word no disponible"); manual tap-to-talk still works. |
| Wake fires but no speech | Silence-timeout → discard, re-arm (no turn sent). |
| Wake during Gemma playback | Ignored (`busy` state). |
| Utterance/turn error | Handled by the existing `VoiceController.send` paths; re-arm afterward. |

The mic is only held while the toggle is ON; turning it off stops the engine immediately.

## 5. Testing

- **`WakeWordDetector`** (`GemmaTests/WakeWordDetectorTests.swift`): feed a bundled **"hey jarvis" WAV fixture** (16 kHz) frame-by-frame → assert a score **> 0.5** is produced; feed a **silence / non-wake clip** → assert the score stays low. Deterministic given the fixed ONNX models. (Requires the models + a small audio fixture in the test bundle.)
- **`EnergyEndpointer`** (`GemmaTests/EnergyEndpointerTests.swift`): pure-logic — synthetic energy sequences trigger end-of-utterance after trailing silence; a short blip never triggers. (Mirrors the Phase-1b endpointer tests.)
- **onnxruntime smoke**: load the three models, run one inference with zeroed input → assert output shapes are non-empty (proves the runtime + bundling work).
- **`WakeListener`** (optional, with a fake `WakeDetecting` + fake capture): on a forced "wake" → transitions `listening → capturing → busy` and calls `voice.send`. (If AVAudioEngine makes this hard to unit-test, cover the transitions via the fake detector and leave live mic to manual.)
- **Manual (you):** toggle on, say "Hey Jarvis… ¿qué hora es?" → it captures, answers by voice, shows the turn, and re-arms. Test in a quiet and a noisy environment to tune the threshold.

## 6. Implementation order

1. Add the **onnxruntime** dependency + a trivial load/smoke test (de-risk the runtime first).
2. Bundle the three **ONNX model files**; a smoke test that loads all three.
3. **`WakeWordDetector`** + the audio→melspec→embedding→wake pipeline, matched to openWakeWord's reference; the fixture-based detection test.
4. **`EnergyEndpointer`** + its pure-logic tests.
5. **`WakeListener`** (AVAudioEngine 16 kHz tap, state machine, wake→capture→`voice.send`→re-arm, pause-during-playback).
6. **`HarnessModel.wake`** wiring + the **toggle + listening indicator** in `AgentChatView`.
7. `xcodebuild` build + unit tests green; manual always-listening E2E (you).

Xcode synchronized folders mean new `Voice/*.swift` + test files auto-compile; the onnxruntime SPM package + the bundled model resources are the only `project.pbxproj`/Xcode changes (SPM reference like GRDB; resources added to the app target's bundle).

## 7. Risks

- **onnxruntime on macOS/Swift** — the main unknown (SPM/XCFramework integration, the C/Swift API surface). De-risked by Task 1 (stand up + smoke-test the runtime before building the pipeline). Fallback if it proves intractable: an app-managed Python wake-sidecar (rejected in brainstorm, but the escape hatch).
- **Matching openWakeWord's preprocessing exactly** — wrong melspec params / embedding windowing / wake-model input length = no detection. Mitigated by following openWakeWord's reference inference code + the fixture test (a real "hey jarvis" clip must score > 0.5 before anything else is trusted).
- **Continuous-inference CPU** — three small ONNX models per 80 ms on an M4 is trivial; confirm no audio-thread stalls (run inference off the audio callback thread).
