# Voice Mode — Distributed JARVIS, Phase 1b (audio walking skeleton) — Design Spec

**Date:** 2026-06-06
**Status:** Approved (brainstorm), pending plan
**Repo:** `gemma-memory` (the i3 server + a thin Mac client). The macOS app is unchanged in this phase.
**Builds on:** Agent Gateway Phase 1a (`POST /v1/agent/turn`, deployed on the i3).
**Vision doc:** `voice_mode.md` (full-duplex attention-arbitration architecture — this phase is the skeleton it all hangs off).

---

## 1. Motivation

Phase 1a turned the text JARVIS brain into a network service on the always-on i3. Phase 1b gives it **voice**: you speak, it speaks back. Per the user's architecture decision, **all audio processing lives on the i3** and **every device (starting with the Mac) is a thin client** — it only captures microphone audio and plays audio back. This is the distributed-JARVIS shape: one always-on brain + audio pipeline, many dumb endpoints.

`voice_mode.md` describes the full voice "nervous system" (VAD, speaker recognition, attention arbitration, conversational state machine, streaming STT/TTS, full-duplex barge-in). That is a chain of sub-projects, not one. This spec covers **only the walking skeleton**: a turn-based audio↔audio loop. Everything else hangs off it.

### Phase decomposition (for context)
- **1b (this spec):** turn-based voice loop — capture → STT → agent → TTS → playback.
- **2:** wake word ("Hey Gemma") + always-listening VAD gating.
- **3:** more thin clients (ESP32 firmware, phone).
- **4a:** attention arbitration + conversational state machine + speaker recognition (the doc's centerpiece).
- **4b:** full-duplex / barge-in / streaming STT+TTS.

## 2. Goals

1. A new Python **`voice` service** on the i3 exposing `POST /v1/voice/turn` (audio in → audio out) that chains **STT → the existing `/v1/agent/turn` → TTS**, all server-side.
2. A **thin Mac client** (`voice_client.py`) that captures an utterance (client-side VAD endpointing), POSTs it, and plays the spoken reply — then loops.
3. **Fully local audio processing on the i3 (CPU-only):** `faster-whisper` (STT) + **Kokoro-82M** (TTS), both behind swappable engine interfaces.
4. Verified by `curl` (WAV in → WAV out) and a live Mac client session (you talk, Gemma answers by voice — including the "¿qué hora es?" and save→recall flows, now spoken).

## 3. Non-Goals

- **Wake word / always-listening** — Phase 2. The 1b client endpoints one utterance at a time (silence-VAD or push-to-talk) and is started/stopped manually.
- **Barge-in / full-duplex / interruptions** — Phase 4b. 1b is strictly turn-based: the client finishes playing the reply before listening again.
- **Attention arbitration, speaker recognition, conversational state machine** — Phase 4a.
- **Streaming** STT or TTS — deferred (Phase 4b). 1b synthesizes the whole reply before playback (non-streamed, matching 1a).
- **Touching the macOS app** — the app keeps its own local text agent. The voice client is a separate thin program.
- **Multiple simultaneous devices / device auth model** — Phase 3. 1b uses one shared bearer token and a caller-supplied `threadId`.

## 4. Design

### 4.1 Architecture & data flow

```
Mac thin client (voice_client.py)                       i3 (docker-compose)
  mic capture 16 kHz mono ──┐                        ┌──────────────────────────────────┐
  webrtcvad endpointing     │  POST /v1/voice/turn   │  voice service (FastAPI :8082)     │
  (record until ~800 ms     ├───── WAV + bearer ────▶│   1. STT  faster-whisper (CPU)     │
   trailing silence)        │      + threadId/tz     │        → text + detected lang      │
                            │                        │   2. httpx → memory:8081           │
                            │                        │        /v1/agent/turn {text,…}     │
                            │                        │        ◀── {reply} ──              │
  play reply WAV  ◀─────────┘   200 audio/wav        │   3. TTS  Kokoro (lang→voice)      │
  → loop back to listen         + X-STT-Text         │        → WAV                       │
                                + X-Reply-Text        └──────────────────────────────────┘
```

Turn-based loop: record one utterance → one POST → play the spoken reply → listen again.

### 4.2 The `voice` service (new, `gemma-memory/voice/`)

FastAPI + uvicorn, mirroring the established `embedder/` sidecar pattern (Dockerfile pre-loads models, `/healthz`, bearer auth).

- **`POST /v1/voice/turn`** (bearer-protected): `multipart/form-data` with field `audio` (a WAV, 16 kHz mono 16-bit PCM) + optional `threadId` + `timezone`. Pipeline:
  1. **STT** → transcript text + detected language.
  2. **Agent** → `httpx.post("http://memory:8081/v1/agent/turn", json={text, threadId, timezone})` with the bearer; read `{reply}`.
  3. **TTS** → synthesize `reply` to WAV bytes, voice chosen by detected language.
  - **Returns** `200 audio/wav` (the spoken reply) with headers `X-STT-Text` (recognized text) and `X-Reply-Text` (the agent's reply) for observability/logging.
- **`STTEngine` protocol** `transcribe(wav_bytes) -> (text, lang)` + **`FasterWhisperSTT`** impl (`WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")`, default model `small`; language auto-detected so es/en code-switching works).
- **`TTSEngine` protocol** `synthesize(text, lang) -> wav_bytes` + **`KokoroTTS`** impl. A `lang → voice` map (es → a Spanish Kokoro voice by default, en → an English voice); `KOKORO_VOICE` env overrides the default. *These two interfaces are the abstraction that lets VibeVoice (Mac/GPU later), Piper, or a cloud engine drop in without touching the pipeline.*
- **`/healthz`** → `{"status":"ok"}` once both models are loaded.
- Engines are constructed once at startup (models loaded once), reused across requests.

**Why a Python service (not Swift orchestration):** `voice_mode.md` puts all future voice intelligence (VAD, speaker-ID, attention arbitration, state machine, streaming) in Python. This service is that home; Phases 2/4 extend it rather than straddling two languages. The one localhost hop to the Swift agent is negligible and keeps a clean boundary (audio pipeline ⟷ agent brain).

### 4.3 The thin Mac client (`gemma-memory/voice-client/voice_client.py`)

A standalone Python program (no server). Loop:
1. Capture mic at 16 kHz mono via `sounddevice`.
2. **Endpoint with `webrtcvad`**: detect speech start, keep recording until ~800 ms of trailing silence, then cut the utterance. Discard sub-~300 ms blips. (A `--ptt` push-to-talk mode is a trivial alternative: record while a key is held.)
3. POST the WAV to `http://<I3_HOST>:8082/v1/voice/turn` with the bearer, `threadId="mac-voice"`, `timezone="America/Havana"`.
4. Play the returned WAV (`sounddevice`). On non-2xx: log + short beep, resume listening (never crash the loop).
5. Back to step 1. Ctrl-C quits.

Config via env/flags: `I3_HOST`, `VOICE_BEARER_TOKEN`, `THREAD_ID`, `TIMEZONE`. Portable — the same shape later runs on a Pi/phone/ESP32 host (Phase 3).

### 4.4 docker-compose

New service slotting in beside `embedder` + `memory`:
```yaml
  voice:
    build: ./voice
    ports: ["8082:8082"]          # the Mac client reaches it over the LAN
    environment:
      - VOICE_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}   # one shared token in 1b
      - MEMORY_URL=http://memory:8081
      - MEMORY_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}
      - WHISPER_MODEL=small
      - KOKORO_VOICE=                                # blank → language-default
      - TZ=${TZ:-America/Havana}
    volumes: [voice-models:/models]                 # whisper + kokoro cache
    depends_on:
      memory:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8082/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped
```
Whisper + Kokoro model weights are **pre-downloaded at image-build time** (as `embedder` pre-loads BGE-M3) so first request is warm; a named `voice-models` volume persists the cache.

### 4.5 Contract

`POST /v1/voice/turn` (bearer):
- **Request:** `multipart/form-data` — `audio` (WAV 16 kHz mono 16-bit PCM, required), `threadId` (string, optional → `"voice"`), `timezone` (IANA id, optional → server's).
- **Response:** `200 audio/wav` body = the spoken reply; headers `X-STT-Text`, `X-Reply-Text`.
- **Non-streamed**, synchronous (whole reply synthesized before return) — matches Phase 1a.

### 4.6 Errors & resilience

- **Client:** ignore sub-~300 ms captures; on any 4xx/5xx, log + short beep and resume listening — the loop never dies. Network timeout → resume.
- **Service (each stage guarded):**
  - Missing/empty/too-short `audio` → `400`.
  - **Empty transcript** (silence/noise) → `400` with `X-STT-Text: ""`; the client simply re-listens (no agent/TTS call).
  - **Agent unreachable** → speak a short fallback ("No pude contactar el cerebro ahora.") as TTS → `200`, so the user hears the failure; `X-Reply-Text` carries it.
  - **STT failure** → `502`. **TTS failure** → `502` with `X-Reply-Text` set so the client can log the (unspoken) text.
- The voice service validates its own bearer (401 without it), and uses `MEMORY_BEARER_TOKEN` to call the agent.

### 4.7 Latency budget (informational, non-streamed)

Short turn on the i3 CPU: STT (faster-whisper `small`, short clip) ~0.5–1.5 s + agent (Cerebras/local) ~0.5–2 s + TTS (Kokoro ~2× real-time) ~0.3–1 s ≈ **~1.5–4 s**. Acceptable for a skeleton; Phase 4b streaming cuts *perceived* latency by speaking the first words before the full reply is ready.

## 5. Testing

- **Service unit tests** (`pytest`, embedder pattern, mocked engines + fake agent):
  - `/v1/voice/turn` with mocked `STTEngine`/`TTSEngine` + a fake agent HTTP endpoint → asserts `audio/wav` out + `X-STT-Text`/`X-Reply-Text`.
  - Bearer missing → `401`.
  - Mocked empty transcript → `400`, no agent call.
  - Fake agent returns 5xx / times out → spoken-fallback `200` (or `502` per §4.6) — assert the documented behavior.
  - `STTEngine`/`TTSEngine` interface contract tests against fakes (shape, not real models).
- **E2E on the i3 (real models):**
  - `curl -F audio=@sample.wav -H "Authorization: Bearer …" http://localhost:8082/v1/voice/turn -o reply.wav -D headers.txt` → a playable WAV; `X-STT-Text`/`X-Reply-Text` sane.
  - Live Mac client: speak "¿qué hora es?" → hear the time (Havana tz); "recuerda que me gusta el café cubano" → next spoken turn recalls it. Confirms the full spoken loop.

## 6. Implementation order

1. **`voice` service scaffold** — FastAPI app, `/healthz`, bearer middleware, Dockerfile (pre-load models), `requirements.txt`. (Mirror `embedder/`.)
2. **`STTEngine` + `FasterWhisperSTT`** + unit test (mock/real-small).
3. **`TTSEngine` + `KokoroTTS`** + `lang→voice` map + unit test.
4. **`agent_client`** (httpx → `/v1/agent/turn`) + **`POST /v1/voice/turn`** handler wiring STT→agent→TTS, with the §4.6 error paths + `X-` headers; unit tests (mocked engines + fake agent).
5. **docker-compose** `voice` service + build (model pre-download) + healthcheck.
6. **`voice-client/voice_client.py`** — capture + webrtcvad endpointing + POST + playback loop + config.
7. **Deploy to the i3** (`docker compose up -d --build voice`) + `curl` E2E + live Mac-client session.

No DB migration; the Swift memory-service is unchanged (the voice service only *calls* its existing `/v1/agent/turn`).

## 7. Roadmap notes (deferred, not 1b)

- **VibeVoice-Realtime-0.5B** as a `TTSEngine` running on the **Mac's M4 GPU** (real-time there) for max quality on days the LLM is on Cerebras — drops into §4.2's TTS abstraction.
- Phase 2 (wake word), 4a (arbitration/state-machine/speaker-ID), 4b (streaming/barge-in) all extend the **`voice` service**.
- The i3 `MEMORY_BEARER_TOKEN` is still the default placeholder — rotate it (the voice service inherits it).
