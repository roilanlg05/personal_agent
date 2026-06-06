# In-App Voice Recorder (Gemma macOS app) — Design Spec

**Date:** 2026-06-06
**Status:** Approved (brainstorm), pending plan
**Repo:** `Gemma` (the macOS SwiftUI app). The i3 backend is unchanged.
**Builds on:** Voice Mode Phase 1b (the i3 `voice` service, `POST /v1/voice/turn`, already deployed).

---

## 1. Motivation

Phase 1b shipped a voice backend on the i3 (`POST /v1/voice/turn`, audio→audio) plus a standalone Python `voice-client`. The user wants voice **inside the Gemma macOS app** instead: a microphone button in the chat that records the user's speech, sends it to the i3 voice service, plays the spoken reply, and shows the conversation in the chat. The standalone Python client remains in the repo as a headless reference but is no longer the primary path.

## 2. Goals

1. A **mic button** in the chat input bar: **tap to start, tap to stop** recording.
2. On stop: record **16 kHz mono WAV**, POST it to the i3 `POST /v1/voice/turn`, and on success **play the spoken reply** (`audio/wav`) **and** append `"you: <transcript>"` + `"gemma: <reply>"` to the chat log (from the `X-STT-Text` / `X-Reply-Text` headers).
3. A **Settings** entry for the voice service URL (reusing the existing memory bearer token).
4. Mic permission + sandbox entitlement wired so recording works in the sandboxed app.
5. Robust: the UI never gets stuck recording; permission-denied / silence / network errors degrade gracefully.

## 3. Non-Goals

- **Wake word, always-listening, barge-in, streaming** — later voice phases. This is tap-to-talk, turn-based, one utterance at a time.
- **Auto-stop on silence (VAD)** — explicitly rejected for v1 (explicit tap-to-stop is simpler and reliable; no VAD library on macOS).
- **Routing voice through the app's LOCAL agent** — voice goes to the i3 voice service → i3 gateway agent (the backend is the brain). Typed chat keeps using the app's local agent path unchanged.
- **Replacing the typed-chat flow** — the mic is additive; `runAgentTurn(_:)` and the text input are untouched.
- **Removing the Python `voice-client/`** — it stays as a headless reference.
- **On-device STT/TTS** — all audio processing stays on the i3.

## 4. Design

### 4.1 Architecture & data flow

```
AgentChatView.inputBar                 VoiceController (@MainActor @Observable)         i3 voice service
  [🎤 mic button] --tap-->  toggleRecording()
                              idle → recording:  AudioRecorder.start()  (16kHz mono WAV)
  [🔴 tap to stop] --tap-->  recording → sending:
                                wav = AudioRecorder.stop()
                                VoiceClient.turn(wav, chatId, tz) ───── POST /v1/voice/turn ──▶ STT→agent→TTS
                                                                       ◀── audio/wav + X-STT/X-Reply ──
                              sending → playing:
                                model.agentLog += "you: <stt>", "gemma: <reply>"
                                AVAudioPlayer.play(audio)
                              playing → idle
```

### 4.2 Components — new `Gemma/Gemma/Voice/`

**`AudioRecorder.swift`** — wraps `AVAudioRecorder`.
- Settings: `AVFormatIDKey = kAudioFormatLinearPCM`, `AVSampleRateKey = 16000`, `AVNumberOfChannelsKey = 1`, `AVLinearPCMBitDepthKey = 16`, little-endian, non-float → records a **16 kHz mono PCM16 WAV** directly (AVAudioRecorder resamples from the device's native rate; no manual conversion). Output to a temp `.wav` file.
- `requestPermission() async -> Bool` (via `AVCaptureDevice.requestAccess(for: .audio)` / `AVAudioApplication.requestRecordPermission` as available on macOS 15).
- `start() throws` / `stop() -> Data` (reads the temp file bytes, returns WAV `Data`, deletes the temp file).
- Defined behind a small `Recording` protocol (`start`/`stop`/`requestPermission`) so `VoiceController` can be unit-tested with a fake.

**`VoiceClient.swift`** — mirrors `MemoryClient` (same `init(baseURL:bearerToken:session:)` + `URLSession` pattern).
- `struct VoiceReply { let audio: Data; let sttText: String; let replyText: String }`.
- `func turn(wav: Data, threadId: String, timezone: String) async throws -> VoiceReply`:
  - Builds a `multipart/form-data` body: part `audio` (filename `u.wav`, `Content-Type: audio/wav`, the WAV bytes) + fields `threadId`, `timezone`.
  - `POST voiceBaseURL/v1/voice/turn`, header `Authorization: Bearer <token>`, ~180 s timeout.
  - On `200`: `VoiceReply(audio: body, sttText: pctDecode(X-STT-Text), replyText: pctDecode(X-Reply-Text))`.
  - On `400`: throw `VoiceError.silence` (the controller treats it as "nothing heard" → no chat append, reset to idle).
  - Else: throw `VoiceError.http(status, replyText?)`.
  - Defined behind a `VoiceTurning` protocol so the controller is testable with a fake.

**`VoiceController.swift`** (`@MainActor @Observable`) — the state machine + orchestration.
- `enum VoiceState { case idle, recording, sending, playing }` (published).
- Owns: a `Recording`, a `VoiceTurning`, an `AVAudioPlayer` (held strongly during playback), and a weak ref to `HarnessModel` (to append to `agentLog`) + a way to read the current chat_id.
- `func toggleRecording()`:
  - `idle` → ensure permission; if granted `start()` → `recording`; if denied append `"voice: micrófono denegado (Ajustes → Privacidad)"` to the log, stay `idle`.
  - `recording` → `stop()` → `sending`; `Task { send(wav) }`.
- `private func send(_ wav: Data) async`:
  - `let reply = try await client.turn(wav:, threadId: currentChatId, timezone: TimeZone.current.identifier)`.
  - append `"you: \(reply.sttText)"` then `"gemma: \(reply.replyText)"` to `model.agentLog`; play `reply.audio` (`playing`); on finish → `idle`.
  - `catch VoiceError.silence` → `idle` (no append). `catch` else → append `"voice: \(error)"`, `idle`.
- Rebuildable from settings (`configure(baseURL:token:)`), called on Settings change (mirrors `ensureMemory()`).

### 4.3 HarnessModel + UI wiring

- `HarnessModel` gains a `voice: VoiceController` (built in init / a `ensureVoice()` like `ensureMemory()`), reading `voiceBaseURL` + `memoryBearerToken` from `UserDefaults`, and exposing the current chat_id (from the existing `ChatSession`).
- `AgentChatView.inputBar`: add a mic `Button` left of the TextField/Send, bound to `model.voice.toggleRecording()`. Icon/state by `model.voice.state`: `idle`→`mic`, `recording`→`stop.circle.fill` (red), `sending`→`ProgressView`, `playing`→`speaker.wave.2.fill`. Disabled while `model.agentRunning` (and Send disabled while `model.voice.state != .idle`, to avoid overlap).
- Voice turns append to the same `agentLog`, so the spoken exchange shows inline with typed chat.

### 4.4 Settings

- New section in `SettingsView`:
  ```
  Section("Voice Service") {
      TextField("Voice base URL", text: $voiceBaseURL)   // @AppStorage("voiceBaseURL") default "http://localhost:8082"
      Text("Servicio de voz en el i3. Usa el mismo bearer token que Memory.")
  }
  .onChange(of: voiceBaseURL) { _, _ in model.ensureVoice() }
  ```
- Reuses `@AppStorage("memoryBearerToken")` (the i3 voice service uses the same token). The `voiceBaseURL` default is `http://localhost:8082`; the user points it at the i3 (e.g. the Tailscale/LAN host) like `memoryBaseURL`.

### 4.5 Capability (sandbox + permission)

- `Gemma/Gemma/Gemma.entitlements`: add `<key>com.apple.security.device.audio-input</key><true/>`.
- Info.plist is auto-generated (`GENERATE_INFOPLIST_FILE = YES`), so add the mic usage string via the build setting `INFOPLIST_KEY_NSMicrophoneUsageDescription = "Gemma graba tu voz para enviarla al asistente."` in the project (Debug + Release).

### 4.6 Audio format contract

- **Record:** 16 kHz, mono, PCM16, WAV — REQUIRED, because the i3 STT (`faster_whisper` on a numpy array) assumes 16 kHz; sending 44.1/48 kHz would garble transcription. `AVAudioRecorder` with the §4.2 settings guarantees this.
- **Play:** the reply WAV is 24 kHz mono (Kokoro); `AVAudioPlayer` handles it directly from `Data`.

### 4.7 Errors & resilience

| Case | Behavior |
|---|---|
| Mic permission denied | One-line chat notice; state stays `idle`; no recording. |
| Empty/very short / silence (`400`) | Silent reset to `idle`; no chat append. |
| Network / 5xx / timeout | `"voice: <short error>"` line; reset to `idle`. |
| Playback failure | Chat text already appended; log a warning; reset to `idle`. |
| Recording while a typed turn runs | Mic disabled when `model.agentRunning`; Send disabled when voice is non-idle. |

State always returns to `idle`; no stuck-recording UI.

## 5. Testing

- **`VoiceClient`** (`GemmaTests/VoiceClientTests.swift`) — using the existing `StubProtocol`/`URLProtocol` pattern (`MemoryClientTests`/`Helpers/FakeMemoryClient`):
  - Builds a multipart request to `…/v1/voice/turn` with the bearer (assert method/path/`Authorization`/`Content-Type: multipart`).
  - `200` + `X-STT-Text`/`X-Reply-Text` (percent-encoded) + WAV body → `VoiceReply` with decoded text + the audio bytes.
  - `400` → throws `VoiceError.silence`. `502` → throws `VoiceError.http`.
- **`VoiceController`** (`GemmaTests/VoiceControllerTests.swift`) — with a **fake** `VoiceTurning` + fake `Recording` (protocols) + a stub `HarnessModel`/log sink:
  - `toggleRecording` from `idle` (permission granted) → `recording`; again → `sending` → on fake success appends `you:`/`gemma:` to the log and ends `idle`.
  - permission denied → stays `idle` + appends the notice.
  - `VoiceError.silence` → `idle`, no append. Generic error → `idle` + error line.
- **Manual (hardware):** real `AudioRecorder` capture/permission, real playback, the mic button states — verified in-app by the user.
- **Run:** `xcodebuild test -scheme Gemma -destination 'platform=macOS'` (existing known-fail `HarnessModelTests.test_defaultBaseURL` aside).

## 6. Implementation order

1. Capability: entitlement + `INFOPLIST_KEY_NSMicrophoneUsageDescription` (so the app can record at all).
2. `VoiceClient` + `VoiceError` + `VoiceTurning` protocol + tests (pure networking, TDD).
3. `AudioRecorder` + `Recording` protocol (16 kHz mono WAV; permission).
4. `VoiceController` state machine + tests (fakes).
5. `HarnessModel.ensureVoice()` + `voiceBaseURL` setting + Settings section.
6. `AgentChatView` mic button + state visuals.
7. Add the new files to `project.pbxproj`; `xcodebuild` builds + unit tests green.
8. Manual in-app E2E: tap mic → speak → hear Gemma + see the transcript/reply in chat (the i3 voice service is already deployed).

**Build-integration note:** the Xcode project uses explicit file references (no SPM, no synchronized folders), so each new `Voice/*.swift` and test file must be inserted into `Gemma.xcodeproj/project.pbxproj` (file ref + build-file + group + sources-phase entries). The plan handles this programmatically and verifies via `xcodebuild`.

## 7. Risks

- **pbxproj surgery** — the main integration risk; mitigated by adding files in one focused step and verifying the build immediately.
- **Sandbox mic permission** — without the entitlement + usage string the recorder fails silently; Task 1 does this first so every later manual test can actually record.
- **Sample-rate mismatch** — guarded by forcing 16 kHz in `AVAudioRecorder` (§4.6); a regression here garbles STT, so a comment + the recorder's fixed settings lock it.
