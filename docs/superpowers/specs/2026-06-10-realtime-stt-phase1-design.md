# Realtime STT — Phase 1 (mic button) Design

**Date:** 2026-06-10
**Status:** Approved (pending implementation plan)
**Phase:** 1 of 2 — the manual mic button. Phase 2 ("Hey Jarvis" wake flow) is a separate later spec.

## Goal

Show the user's words **as they speak** (live caption) in the macOS app's voice flow, by replacing the
turn-based batch STT with ElevenLabs **Scribe v2 Realtime** streaming over a websocket. The realtime
transcript becomes authoritative: what the user sees IS what goes to the agent. This phase covers the
**mic button** (manual tap-to-talk) only; the wake-word path stays on the existing batch flow until
Phase 2.

## Background (current state)

The app records a full WAV then `POST`s it to the i3 `voice` service:
`mic → VoiceController.send(wav) → VoiceClient → POST /v1/voice/turn → batch Scribe STT → call_agent
(Cerebras) → Kokoro TTS → audio back`. Text only appears after the round trip (no partials).
The wake path (`WakeListener`) already runs an `AVAudioEngine` 16 kHz mono tap producing PCM frames —
the capture pattern this phase reuses for streaming.

## Verified ElevenLabs facts

- Realtime STT websocket: `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&token=<token>`.
- Auth: a **single-use token** (expires 15 min) minted server-side from the account `xi-api-key`; passed
  as the `token` query param. (Backend mints it via the ElevenLabs single-use-token API with purpose
  `realtime_scribe`; the response field is `token`.)
- Client sends `input_audio_chunk` JSON messages: `{ "audio_base_64": "...", "sample_rate": 16000 }`
  (PCM 16 kHz mono = `pcm_16000`).
- Server sends: `session_started`, `partial_transcript` (`text`, interim), `committed_transcript`
  (`text`, final), plus error types `error`/`auth_error`/`quota_exceeded`/`rate_limited`.
- Turn end: `commit_strategy: "vad"` (server commits on detected silence) OR `manual` (`commit:true`).
  This phase uses **VAD** for hands-free end-of-speech **and** a **manual stop** (tap-to-cut).

## Architecture

The app opens the websocket **directly** to ElevenLabs using an ephemeral token from the i3, so the
account key never leaves the i3. The agent + TTS stay on the i3 but are now invoked with **text**.

```
🎤 tap → GET /v1/voice/realtime-token (i3) ──→ {token, model_id}
       → WS  wss://…/realtime?model_id=…&token=…   (app ↔ ElevenLabs, direct)
            stream mic PCM16k → input_audio_chunk (base64)
            ← partial_transcript  → live caption (the "you:" bubble fills in)
            ← committed_transcript → final text     (VAD silence, or tap-to-cut)
       → POST /v1/voice/say (i3) {text, threadId, …} → call_agent → Kokoro TTS → audio
       → play reply + commit the turn to the chat
```

### Components

**i3 (`voice` service, Python — 2 new endpoints):**

1. `GET /v1/voice/realtime-token` (bearer auth) → mints an ElevenLabs single-use realtime token using
   `ELEVENLABS_API_KEY` and returns `{"token": "...", "model_id": "scribe_v2_realtime"}`. The key stays
   server-side. (Implementation confirms the exact ElevenLabs token REST endpoint/SDK call at build
   time; if minting fails, returns a 5xx error so the app falls back to the batch path.)

2. `POST /v1/voice/say` (bearer auth) → body `{text, threadId, timezone?, language?}` → `call_agent(text,
   threadId, timezone, language)` → `_tts.synthesize(reply, language or "en")` → returns `audio/wav`
   with an `X-Reply-Text` header. This is `/v1/voice/turn` minus the STT step (reuses the existing agent
   + TTS code paths). Same agent-error fallback as `/v1/voice/turn` (speak the failure, still 200).

**App (macOS, `Gemma/Gemma/Voice/`):**

3. `RealtimeSTTClient` (new) — owns the websocket + mic streaming:
   - `start()`: fetch a token (via the existing HTTP client), open `URLSessionWebSocketTask` to the
     realtime URL, send a session config selecting `commit_strategy: "vad"`, then stream the live mic
     (16 kHz mono PCM frames from an `AVAudioEngine` tap — same capture as `WakeListener`) as
     `input_audio_chunk` base64 messages.
   - Publishes `partialText: String` (updated on every `partial_transcript`) for the live caption.
   - On `committed_transcript` (VAD end) → invokes an `onFinal(text)` callback and stops.
   - `stop()` (tap-to-cut): send a manual `commit: true`, finalize with the committed text, close the
     socket. Idempotent.
   - Surfaces errors (`auth_error`/`quota_exceeded`/transport) via an `onError` callback.
   - Has no UI and no agent knowledge — it only turns mic audio into `(partial, final)` text. Testable
     by injecting a fake websocket transport (a protocol over `URLSessionWebSocketTask`).

4. UI (live caption): `HarnessModel` publishes a `liveTranscript: String`. While the mic is active, the
   chat renders a provisional "you:" bubble bound to `liveTranscript`, updating in place; on `onFinal`
   it becomes the committed user message. (Minimal change to the existing chat view.)

5. Mic-button flow (`HarnessModel` + the chat view + `VoiceController`): tapping the mic now starts
   `RealtimeSTTClient` instead of recording a WAV. `liveTranscript` drives the caption; on `onFinal`,
   the app `POST`s `/v1/voice/say` and plays the returned audio via the existing `VoiceController`
   playback path, then appends the turn. A second tap during capture = tap-to-cut (`stop()`); a tap
   during playback stops playback as today.

## Error handling / resilience

- **Token fetch fails, or the websocket errors/`auth_error`/`quota_exceeded`** → fall back to the
  existing batch path for that turn (record a WAV → `POST /v1/voice/turn`), so voice still works when
  realtime is unavailable. The fallback is the current, tested flow — unchanged.
- **Empty final transcript** (silence / immediate cut) → no-op, re-arm the mic (no agent call), matching
  the current empty-transcript behavior.
- **`/v1/voice/say` agent/TTS failure** → same handling as `/v1/voice/turn` today (spoken fallback / 502
  surfaced text).
- **Token expiry** (15 min) is irrelevant per-turn (a turn is seconds); a fresh token is fetched each
  mic tap.

## Testing

**i3 (`voice/test_app.py`, mocked — no real ElevenLabs/agent calls):**
- `/v1/voice/realtime-token`: monkeypatch the token-minting call → returns `{token, model_id}`; bearer
  required (401 without it); minting failure → 5xx.
- `/v1/voice/say`: monkeypatch `call_agent` + `_tts` → returns audio bytes + `X-Reply-Text`; agent error
  → spoken fallback (mirrors the `/turn` tests); bearer required.

**App (`GemmaTests`, with a fake websocket transport + fake token fetch):**
- `RealtimeSTTClient`: feeding `partial_transcript` messages updates `partialText`; a
  `committed_transcript` fires `onFinal` with the text; `stop()` (tap-to-cut) sends a `commit` and
  finalizes; an `auth_error` message fires `onError`. Assert the outbound `input_audio_chunk` shape
  (base64 + `sample_rate: 16000`).
- Fallback: when the token fetch throws, the mic flow uses the batch path (assert it calls the existing
  `VoiceClient` `/v1/voice/turn`).

## Scope / non-goals (Phase 1)

- **Mic button only.** The "Hey Jarvis" wake flow stays on batch until Phase 2 (it reuses
  `RealtimeSTTClient` + `/say` + the token endpoint built here).
- Keep `/v1/voice/turn` (batch) as the fallback path; don't delete it.
- VAD end-of-speech + manual tap-to-cut. No barge-in / interruptible TTS (that's Conversational-AI
  territory, out of scope).
- macOS app only (a future iOS client reuses the same i3 endpoints).
- No change to the agent, memory, or Kokoro TTS beyond the new `/say` entry point.
