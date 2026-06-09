# ElevenLabs Scribe STT — Design

**Date:** 2026-06-09
**Status:** Approved (pending implementation plan)

## Goal

Replace the self-hosted STT (faster-whisper on the i3 CPU) with **ElevenLabs Scribe**, to fix the
two STT pains: frequent transcription errors (mangled long utterances, "Lovell" vs "Lewisville",
dropped words) and slowness (~2s on CPU — the largest slice of the ~5s turn). Keep Kokoro TTS, the
Cerebras agent, and the existing `STT→agent→TTS` pipeline unchanged.

## Background (current state)

`gemma-memory/voice/` is a FastAPI service. `app.py`:
- `_make_stt()` builds the STT engine: `FakeSTT()` when `VOICE_FAKE_ENGINES=1`, else
  `FasterWhisperSTT(WHISPER_MODEL)`. Built once at import (`_stt = _make_stt()`).
- `/v1/voice/turn`: `text, lang = _stt.transcribe(wav)` → `call_agent(text, threadId, timezone, lang)`
  → `_tts.synthesize(reply, lang)`.
- `lang` flows to the agent (firm reply-language pinning, fix #1) and to Kokoro (voice selection).

`engines.py` defines the `STTEngine` Protocol (`transcribe(wav_bytes) -> (text, lang)`) with
`FakeSTT` and `FasterWhisperSTT`. Engines are intentionally swappable.

## Design

### 1. New engine `ElevenLabsScribeSTT` (`voice/engines.py`)

Conforms to `STTEngine`. On `transcribe(wav_bytes)`:

- `POST https://api.elevenlabs.io/v1/speech-to-text` via `httpx`, multipart form:
  - `file`: the wav bytes (filename `audio.wav`, content-type `audio/wav`).
  - `model_id`: from `ELEVENLABS_STT_MODEL` (default `scribe_v1`).
  - `language_code`: from `STT_LANGUAGE` when set (we force English) — omitted ⇒ Scribe
    auto-detects. (Confirm the exact code form `en` vs ISO-639-3 `eng` against the live API during
    implementation; the design is unaffected.)
  - Header `xi-api-key: <ELEVENLABS_API_KEY>`.
  - `timeout` ~30s (httpx).
- Parse the JSON response: take the transcript text field (confirm exact key — `text`) and the
  language. **Returns `(text, forced_lang or detected_lang)`** — when `STT_LANGUAGE` is set we return
  that forced value (so a forced "en" pins the agent + TTS deterministically), else the detected
  language code.
- `__init__(api_key, model="scribe_v1", language=None)` reads nothing from env itself — the factory
  passes config in (keeps the class testable).

No faster-whisper import here; this engine has no local model.

### 2. Engine selection (`voice/app.py` `_make_stt()`)

```
def _make_stt():
    if VOICE_FAKE_ENGINES == "1": return FakeSTT()
    if STT_ENGINE == "elevenlabs" or ELEVENLABS_API_KEY:   # opt-in by flag or key presence
        return ElevenLabsScribeSTT(api_key=ELEVENLABS_API_KEY,
                                   model=ELEVENLABS_STT_MODEL or "scribe_v1",
                                   language=STT_LANGUAGE or None)
    return FasterWhisperSTT(WHISPER_MODEL)   # unchanged fallback
```

Only the selected engine is instantiated, so choosing ElevenLabs means whisper's model is **never
loaded** (frees i3 CPU/RAM). If `STT_ENGINE=elevenlabs` is set but the key is missing, fail fast with
a clear error at startup (don't silently fall back — the user explicitly chose ElevenLabs).

### 3. Config (i3 `~/Projects/gemma-memory/.env` + `docker-compose.yml` `voice` service)

- `ELEVENLABS_API_KEY` — the key (in `.env`, never committed).
- `STT_ENGINE=elevenlabs`
- `STT_LANGUAGE=en` (force English; also drives the agent's reply-language pinning)
- `ELEVENLABS_STT_MODEL=scribe_v1` (optional; default in code)

`docker-compose.yml` passes `ELEVENLABS_API_KEY`, `STT_ENGINE`, `STT_LANGUAGE`,
`ELEVENLABS_STT_MODEL` into the `voice` service env. The now-unused `WHISPER_*` vars can stay (the
fallback path still reads them) or be left as-is.

## Error handling

- HTTP/transport error or non-2xx from ElevenLabs → raise (the existing `/v1/voice/turn` handler
  already maps an STT exception to HTTP 502 with a clear detail). No silent fallback to whisper.
- Empty/short audio is already rejected upstream (the handler checks `len(wav) < 200`).

## Testing

All with mocks — never call the real ElevenLabs API in tests.

- `test_elevenlabs_stt_parses_response`: monkeypatch `httpx.post` (or the client) to return a canned
  Scribe JSON; assert `transcribe(b"...")` returns the text and the forced/detected language.
- `test_elevenlabs_stt_forces_language`: with `language="en"`, assert the returned lang is `"en"`
  regardless of the response's detected language, and that `language_code` is sent in the request.
- `test_elevenlabs_stt_raises_on_http_error`: non-2xx → raises (so the handler returns 502).
- The existing `voice/test_app.py` suite stays green (it uses `VOICE_FAKE_ENGINES=1`, so engine
  selection is unaffected).

## Scope / non-goals

- STT only. TTS (Kokoro) and the agent are untouched.
- No realtime/streaming STT, no ElevenLabs Conversational AI — the turn-based wav→text shape stays.
- English is forced for now (`STT_LANGUAGE=en`); auto-detect remains available by unsetting it.
