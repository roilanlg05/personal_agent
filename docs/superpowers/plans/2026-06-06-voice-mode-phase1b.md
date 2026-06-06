# Voice Mode Phase 1b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A turn-based voice loop for Gemma — you speak, the i3 transcribes (faster-whisper), runs the existing agent (`/v1/agent/turn`), synthesizes the reply (Kokoro-82M), and speaks it back; a thin Mac client captures and plays.

**Architecture:** A new Python FastAPI **`voice` service** on the i3 (docker-compose, beside `embedder`/`memory`) exposes `POST /v1/voice/turn` (audio in → audio out), chaining STT → agent (localhost HTTP) → TTS. STT/TTS sit behind swappable engine interfaces. A standalone **`voice-client/voice_client.py`** runs on the Mac: webrtcvad silence-endpointing → POST → playback → loop. All audio processing is on the i3; devices are thin.

**Tech Stack:** Python 3.11, FastAPI + uvicorn, faster-whisper (CTranslate2, CPU int8), Kokoro-82M (`kokoro` + torch CPU), soundfile, webrtcvad + sounddevice (client), Docker Compose. Mirrors the existing `gemma-memory/embedder/` sidecar pattern.

**Repo / branch:** `gemma-memory` (git root at `/Users/hashdown/Projects/personal_agent/gemma-memory`). Create and work on branch `sp-voice-1b`. The Swift `memory-service` is **unchanged** — the voice service only *calls* its existing `/v1/agent/turn`.

**Spec:** `docs/superpowers/specs/2026-06-06-voice-mode-phase1b-design.md`.

---

## File Structure

All new. Service in `gemma-memory/voice/`, client in `gemma-memory/voice-client/`.

| File | Responsibility |
|---|---|
| `voice/app.py` | FastAPI app: `/healthz`, bearer dep, `POST /v1/voice/turn` handler, engine factories, `call_agent`. |
| `voice/engines.py` | `STTEngine`/`TTSEngine` protocols + `FasterWhisperSTT`, `KokoroTTS`, `FakeSTT`, `FakeTTS`, `LANG_VOICE`. |
| `voice/test_app.py` | pytest (FastAPI TestClient) — handler behavior with fake engines + monkeypatched agent. |
| `voice/requirements.txt` | Pinned deps. |
| `voice/Dockerfile` | python:3.11-slim, system libs, pip install, **pre-pull models**, uvicorn on :8082. |
| `voice/.dockerignore` | Exclude caches. |
| `docker-compose.yml` (modify) | Add the `voice` service + `voice-models` volume. |
| `voice-client/voice_client.py` | Mac thin client: capture + `VadEndpointer` + POST + playback loop. |
| `voice-client/test_endpointer.py` | pytest for the pure `VadEndpointer` logic (no hardware). |
| `voice-client/requirements.txt` | Client deps. |
| `voice-client/README.md` | How to run the client on the Mac. |

**Engine boundary:** the handler depends only on the `STTEngine`/`TTSEngine` protocols (`transcribe(wav_bytes)->(text,lang)`, `synthesize(text,lang)->wav_bytes`). Real engines load models; fakes return canned data so unit tests never load torch/whisper. This is the abstraction that lets VibeVoice/Piper/cloud drop in later.

---

## Task 1: `voice` service scaffold (FastAPI + /healthz + requirements)

**Files:**
- Create: `voice/app.py`, `voice/requirements.txt`, `voice/test_app.py`, `voice/.dockerignore`

- [ ] **Step 1: Create `voice/requirements.txt`**

```
fastapi==0.115.6
uvicorn[standard]==0.32.1
pydantic==2.10.3
python-multipart==0.0.12
httpx==0.28.1
faster-whisper==1.1.1
soundfile==0.12.1
numpy==1.26.4
kokoro==0.9.4
torch==2.6.0
pytest==8.3.4
```
(If pip cannot resolve this exact set at build time in Task 5, bumping the `kokoro`/`torch`/`numpy` patch versions to the nearest compatible release is acceptable — that is normal dependency resolution, not a design change. Keep `fastapi`/`uvicorn`/`pydantic` pinned to match the `embedder`.)

- [ ] **Step 2: Create `voice/.dockerignore`**

```
__pycache__
*.pyc
.pytest_cache
```

- [ ] **Step 3: Create `voice/app.py` (scaffold only — engines + endpoint come in later tasks)**

```python
"""Voice gateway for the Gemma assistant. Chains STT -> the agent (/v1/agent/turn)
-> TTS, exposing POST /v1/voice/turn (audio in -> audio out). CPU-only; runs on the i3.
All audio processing lives here; devices are thin clients."""
import os
from fastapi import FastAPI

app = FastAPI(title="Gemma Voice Gateway", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
```

- [ ] **Step 4: Create `voice/test_app.py` (healthz)**

```python
"""Voice gateway tests. Run with:
    python3 -m pytest voice/test_app.py -v
Uses fake engines (VOICE_FAKE_ENGINES=1) so no models load."""
import os, sys
os.environ["VOICE_FAKE_ENGINES"] = "1"
os.environ["VOICE_BEARER_TOKEN"] = "test-token"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
import app as appmod

client = TestClient(appmod.app)


def test_healthz_returns_200():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -v`
Expected: `test_healthz_returns_200 PASSED`. (Requires `pip install fastapi pydantic httpx pytest` in the dev env; the heavy ML deps are NOT needed yet because `VOICE_FAKE_ENGINES=1` and engines are imported lazily — but `app.py` here imports nothing heavy anyway.)

- [ ] **Step 6: Commit**

```bash
git add voice/app.py voice/requirements.txt voice/test_app.py voice/.dockerignore
git commit -m "feat(voice): FastAPI scaffold + /healthz (Phase 1b voice gateway)"
```

---

## Task 2: STT engine (protocol + FasterWhisper + Fake)

**Files:**
- Create: `voice/engines.py`
- Modify: `voice/test_app.py`

- [ ] **Step 1: Write the failing test — append to `voice/test_app.py`**

```python
from engines import FakeSTT, FasterWhisperSTT  # noqa: E402


def test_fake_stt_returns_configured_text():
    stt = FakeSTT(text="hola mundo", lang="es")
    text, lang = stt.transcribe(b"ignored")
    assert text == "hola mundo"
    assert lang == "es"


def test_faster_whisper_stt_is_constructible_symbol():
    # The real class must exist and expose .transcribe; we do NOT load the model here.
    assert hasattr(FasterWhisperSTT, "transcribe")
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'engines'` / import error.

- [ ] **Step 3: Create `voice/engines.py` (STT half)**

```python
"""STT/TTS engine interfaces + concrete (faster-whisper, Kokoro) and fake impls.
The handler depends only on the protocols, so engines are swappable (VibeVoice/Piper/cloud later)."""
import io
import os
import wave
from typing import Protocol, Tuple


class STTEngine(Protocol):
    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        """Return (recognized_text, detected_language_code)."""
        ...


class FakeSTT:
    """Deterministic STT for unit tests (no model)."""
    def __init__(self, text: str = "hola", lang: str = "es"):
        self.text = text
        self.lang = lang

    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        return self.text, self.lang


class FasterWhisperSTT:
    """CPU faster-whisper (CTranslate2 int8). Expects 16 kHz mono WAV bytes."""
    def __init__(self, model_name: str = "small"):
        from faster_whisper import WhisperModel
        download_root = os.environ.get("WHISPER_CACHE") or None
        self._model = WhisperModel(
            model_name, device="cpu", compute_type="int8", download_root=download_root
        )

    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        import numpy as np
        import soundfile as sf
        data, _sr = sf.read(io.BytesIO(wav_bytes), dtype="float32")
        if getattr(data, "ndim", 1) > 1:  # downmix to mono
            data = data.mean(axis=1)
        # Client guarantees 16 kHz; faster-whisper assumes 16 kHz for ndarray input.
        segments, info = self._model.transcribe(np.ascontiguousarray(data), beam_size=1)
        text = "".join(seg.text for seg in segments).strip()
        return text, info.language
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -k "stt or healthz" -v`
Expected: PASS (the FasterWhisper test only checks the symbol; no model loads).

- [ ] **Step 5: Commit**

```bash
git add voice/engines.py voice/test_app.py
git commit -m "feat(voice): STT engine interface + FasterWhisperSTT + FakeSTT"
```

---

## Task 3: TTS engine (protocol + Kokoro + Fake + language→voice map)

**Files:**
- Modify: `voice/engines.py`, `voice/test_app.py`

- [ ] **Step 1: Write the failing test — append to `voice/test_app.py`**

```python
from engines import FakeTTS, KokoroTTS, LANG_VOICE  # noqa: E402


def test_fake_tts_returns_valid_wav():
    out = FakeTTS().synthesize("hola", "es")
    # Valid WAV header ("RIFF"...."WAVE") and non-trivial length.
    assert out[:4] == b"RIFF"
    assert out[8:12] == b"WAVE"
    assert len(out) > 44


def test_lang_voice_map_has_es_and_en():
    assert "es" in LANG_VOICE and "en" in LANG_VOICE
    # Each entry is (kokoro_lang_code, voice_name).
    assert len(LANG_VOICE["es"]) == 2 and len(LANG_VOICE["en"]) == 2


def test_kokoro_tts_is_constructible_symbol():
    assert hasattr(KokoroTTS, "synthesize")
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -k tts -v`
Expected: FAIL — `ImportError: cannot import name 'FakeTTS'`.

- [ ] **Step 3: Append the TTS half to `voice/engines.py`**

```python
# --- TTS ---------------------------------------------------------------------

# Kokoro lang_code per language + a default voice. 'a'=American English, 'e'=Spanish.
# Voices: 'af_heart' (American female), 'ef_dora' (Spanish female).
LANG_VOICE = {
    "en": ("a", "af_heart"),
    "es": ("e", "ef_dora"),
}
_DEFAULT_LANG = "es"  # Gemma's user speaks Spanish; fall back here for unknown langs.


class TTSEngine(Protocol):
    def synthesize(self, text: str, lang: str) -> bytes:
        """Return WAV bytes (mono PCM16) for `text`, voiced per `lang`."""
        ...


class FakeTTS:
    """Deterministic TTS for unit tests: 0.1 s of silence as a valid 24 kHz WAV (stdlib only)."""
    SR = 24000

    def synthesize(self, text: str, lang: str) -> bytes:
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(self.SR)
            w.writeframes(b"\x00\x00" * (self.SR // 10))
        return buf.getvalue()


class KokoroTTS:
    """Kokoro-82M on CPU. One KPipeline per language (lazy), reused across calls."""
    SR = 24000

    def __init__(self, override_voice: str = ""):
        self._override_voice = override_voice or ""
        self._pipelines = {}  # lang_code -> KPipeline

    def _pipeline(self, lang_code: str):
        if lang_code not in self._pipelines:
            from kokoro import KPipeline
            self._pipelines[lang_code] = KPipeline(lang_code=lang_code)
        return self._pipelines[lang_code]

    def synthesize(self, text: str, lang: str) -> bytes:
        import numpy as np
        import soundfile as sf
        lang_code, voice = LANG_VOICE.get(lang, LANG_VOICE[_DEFAULT_LANG])
        if self._override_voice:
            voice = self._override_voice
        pipe = self._pipeline(lang_code)
        chunks = []
        for _gs, _ps, audio in pipe(text, voice=voice):
            arr = audio.numpy() if hasattr(audio, "numpy") else np.asarray(audio)
            chunks.append(arr.astype("float32"))
        data = np.concatenate(chunks) if chunks else np.zeros(1, dtype="float32")
        buf = io.BytesIO()
        sf.write(buf, data, self.SR, format="WAV", subtype="PCM_16")
        return buf.getvalue()
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -k tts -v`
Expected: PASS (no model loads — `FakeTTS` uses stdlib `wave`; the Kokoro test only checks the symbol).

- [ ] **Step 5: Commit**

```bash
git add voice/engines.py voice/test_app.py
git commit -m "feat(voice): TTS engine interface + KokoroTTS + FakeTTS + lang->voice map"
```

---

## Task 4: `POST /v1/voice/turn` handler + bearer + agent client + error paths

**Files:**
- Modify: `voice/app.py`, `voice/test_app.py`

- [ ] **Step 1: Write the failing tests — append to `voice/test_app.py`**

```python
import io, wave  # noqa: E402
from urllib.parse import unquote  # noqa: E402
from engines import FakeSTT  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}


def _wav_16k(seconds: float = 0.5) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\x01\x00" * int(16000 * seconds))
    return buf.getvalue()


def test_voice_turn_returns_audio_and_headers(monkeypatch):
    monkeypatch.setattr(appmod, "call_agent", lambda text, tid, tz: "hola Roilan")
    r = client.post(
        "/v1/voice/turn", headers=AUTH,
        files={"audio": ("u.wav", _wav_16k(), "audio/wav")},
        data={"threadId": "T", "timezone": "America/Havana"},
    )
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/wav"
    assert unquote(r.headers["x-stt-text"]) == "hola"          # FakeSTT default
    assert unquote(r.headers["x-reply-text"]) == "hola Roilan"
    assert len(r.content) > 44                                  # real audio body


def test_voice_turn_requires_bearer():
    r = client.post("/v1/voice/turn", files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 401


def test_voice_turn_empty_transcript_is_400(monkeypatch):
    monkeypatch.setattr(appmod, "_stt", FakeSTT(text="", lang="es"))
    called = {"agent": False}
    monkeypatch.setattr(appmod, "call_agent", lambda *a: called.__setitem__("agent", True) or "x")
    r = client.post("/v1/voice/turn", headers=AUTH,
                    files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 400
    assert r.headers.get("x-stt-text", "") == ""
    assert called["agent"] is False                             # never reached the agent


def test_voice_turn_missing_audio_is_400():
    r = client.post("/v1/voice/turn", headers=AUTH, data={"threadId": "T"})
    assert r.status_code in (400, 422)                          # FastAPI 422 if field absent


def test_voice_turn_agent_error_speaks_fallback(monkeypatch):
    def boom(text, tid, tz):
        raise RuntimeError("memory down")
    monkeypatch.setattr(appmod, "call_agent", boom)
    r = client.post("/v1/voice/turn", headers=AUTH,
                    files={"audio": ("u.wav", _wav_16k(), "audio/wav")})
    assert r.status_code == 200
    assert "cerebro" in unquote(r.headers["x-reply-text"]).lower()
    assert len(r.content) > 44                                  # the fallback was spoken
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -k voice_turn -v`
Expected: FAIL — `404 Not Found` (route absent) / `AttributeError: module 'app' has no attribute 'call_agent'`.

- [ ] **Step 3: Replace `voice/app.py` with the full handler**

```python
"""Voice gateway for the Gemma assistant. Chains STT -> the agent (/v1/agent/turn)
-> TTS, exposing POST /v1/voice/turn (audio in -> audio out). CPU-only; runs on the i3.
All audio processing lives here; devices are thin clients."""
import os
from urllib.parse import quote

import httpx
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Response, UploadFile

AGENT_FALLBACK = "No pude contactar el cerebro ahora."
MEMORY_URL = os.environ.get("MEMORY_URL", "http://memory:8081")
MEMORY_BEARER = os.environ.get("MEMORY_BEARER_TOKEN", "")


def _make_stt():
    if os.environ.get("VOICE_FAKE_ENGINES") == "1":
        from engines import FakeSTT
        return FakeSTT()
    from engines import FasterWhisperSTT
    return FasterWhisperSTT(os.environ.get("WHISPER_MODEL", "small"))


def _make_tts():
    if os.environ.get("VOICE_FAKE_ENGINES") == "1":
        from engines import FakeTTS
        return FakeTTS()
    from engines import KokoroTTS
    return KokoroTTS(os.environ.get("KOKORO_VOICE", ""))


# Built once at import (engines load their models once); fakes when VOICE_FAKE_ENGINES=1.
_stt = _make_stt()
_tts = _make_tts()


def call_agent(text: str, thread_id: str, timezone: str | None) -> str:
    """POST to the Swift agent gateway and return its reply text. Raises on transport/HTTP error."""
    body = {"text": text, "threadId": thread_id}
    if timezone:
        body["timezone"] = timezone
    headers = {"Authorization": f"Bearer {MEMORY_BEARER}", "Content-Type": "application/json"}
    r = httpx.post(f"{MEMORY_URL}/v1/agent/turn", json=body, headers=headers, timeout=180)
    r.raise_for_status()
    return r.json().get("reply", "")


def require_bearer(authorization: str = Header(default="")):
    expected = os.environ.get("VOICE_BEARER_TOKEN", "")
    if not expected or authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="unauthorized")


app = FastAPI(title="Gemma Voice Gateway", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/v1/voice/turn", dependencies=[Depends(require_bearer)])
async def voice_turn(
    audio: UploadFile = File(...),
    threadId: str = Form(default="voice"),
    timezone: str | None = Form(default=None),
):
    wav = await audio.read()
    if not wav or len(wav) < 200:
        raise HTTPException(status_code=400, detail="audio required")

    try:
        text, lang = _stt.transcribe(wav)
    except Exception as exc:  # STT failure
        raise HTTPException(status_code=502, detail=f"stt failed: {exc}")

    if not text.strip():  # silence/noise -> client just re-listens
        return Response(status_code=400, headers={"X-STT-Text": ""})

    try:
        reply = call_agent(text, threadId, timezone)
    except Exception:
        reply = AGENT_FALLBACK  # agent unreachable -> speak the failure, still 200

    try:
        out = _tts.synthesize(reply, lang)
    except Exception as exc:  # TTS failure -> 502, but surface the (unspoken) text
        return Response(
            status_code=502,
            headers={"X-STT-Text": quote(text), "X-Reply-Text": quote(reply), "X-Error": f"tts: {exc}"},
        )

    return Response(
        content=out,
        media_type="audio/wav",
        headers={"X-STT-Text": quote(text), "X-Reply-Text": quote(reply)},
    )
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -v`
Expected: ALL pass (healthz + stt + tts + the 5 voice_turn tests). No models load (`VOICE_FAKE_ENGINES=1`).

- [ ] **Step 5: Commit**

```bash
git add voice/app.py voice/test_app.py
git commit -m "feat(voice): POST /v1/voice/turn (STT->agent->TTS) + bearer + error paths + X- headers"
```

---

## Task 5: Dockerfile (pre-pull models) + docker-compose wiring

**Files:**
- Create: `voice/Dockerfile`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Create `voice/Dockerfile`**

```dockerfile
FROM python:3.11-slim AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential espeak-ng libsndfile1 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py engines.py test_app.py ./

# Pre-pull models into the image so the first request is warm.
ENV HF_HUB_CACHE=/models
ENV WHISPER_CACHE=/models
RUN python -c "from faster_whisper import WhisperModel; WhisperModel('small', device='cpu', compute_type='int8', download_root='/models')"
RUN python -c "import warnings; warnings.filterwarnings('ignore'); from kokoro import KPipeline; \
[list(KPipeline(lang_code=lc)(t, voice=v)) for lc, v, t in [('a','af_heart','hi'), ('e','ef_dora','hola')]]"

EXPOSE 8082
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8082"]
```
(The two pre-pull `RUN`s download faster-whisper-small + Kokoro-82M weights and the two voices into `/models`. On first `docker compose up`, Docker initializes the empty named `voice-models` volume from this image content — same mechanism the `embedder` relies on.)

- [ ] **Step 2: Add the `voice` service to `docker-compose.yml`**

Insert this service after the `memory:` service block (before the top-level `volumes:` key):

```yaml
  voice:
    build:
      context: ./voice
    ports:
      - "8082:8082"
    environment:
      - VOICE_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}
      - MEMORY_URL=http://memory:8081
      - MEMORY_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}
      - WHISPER_MODEL=small
      - WHISPER_CACHE=/models
      - HF_HUB_CACHE=/models
      - KOKORO_VOICE=
      - TZ=${TZ:-America/Havana}
    volumes:
      - voice-models:/models
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

- [ ] **Step 3: Add the named volume**

In the top-level `volumes:` block at the bottom of `docker-compose.yml` (which currently has `embedder-models:`), add:

```yaml
  voice-models:
```

So the block reads:
```yaml
volumes:
  embedder-models:
  voice-models:
```

- [ ] **Step 4: Verify compose parses**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && docker compose config >/dev/null && echo COMPOSE_OK`
Expected: `COMPOSE_OK` (no YAML/schema errors). The actual image build + run happens on the i3 in Task 7 (building the ML image locally on the Mac is unnecessary and slow).

- [ ] **Step 5: Commit**

```bash
git add voice/Dockerfile docker-compose.yml
git commit -m "feat(voice): Dockerfile (pre-pull whisper+kokoro) + docker-compose voice service"
```

---

## Task 6: Thin Mac client (`voice_client.py`) + endpointer unit test

**Files:**
- Create: `voice-client/voice_client.py`, `voice-client/test_endpointer.py`, `voice-client/requirements.txt`, `voice-client/README.md`

- [ ] **Step 1: Write the failing test — `voice-client/test_endpointer.py`**

```python
"""Pure-logic test for the VAD endpointer (no audio hardware). Run with:
    python3 -m pytest voice-client/test_endpointer.py -v"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from voice_client import VadEndpointer


def test_endpointer_triggers_after_trailing_silence():
    # 30 ms frames; end after 300 ms (10 frames) of silence following >=90 ms (3 frames) of speech.
    ep = VadEndpointer(frame_ms=30, silence_ms=300, min_speech_ms=90)
    for _ in range(5):
        assert ep.update(True) is False          # speech: never ends mid-speech
    results = [ep.update(False) for _ in range(10)]
    assert results[-1] is True                    # ends on the 10th silent frame
    assert True not in results[:9]                # not before


def test_endpointer_ignores_short_blip():
    # Needs 300 ms (10 frames) of speech to "start"; a 90 ms blip must never trigger an end.
    ep = VadEndpointer(frame_ms=30, silence_ms=300, min_speech_ms=300)
    for _ in range(3):
        ep.update(True)                           # only 90 ms speech -> not started
    results = [ep.update(False) for _ in range(20)]
    assert True not in results
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice-client/test_endpointer.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'voice_client'`.

- [ ] **Step 3: Create `voice-client/voice_client.py`**

```python
"""Thin Mac voice client for Gemma. Captures one utterance (webrtcvad silence-endpointing),
POSTs it to the i3 voice gateway, plays the spoken reply, loops. The i3 does all processing.

Run:
    pip install -r requirements.txt
    I3_HOST=http://192.168.1.50:8082 VOICE_BEARER_TOKEN=<token> python3 voice_client.py
Ctrl-C to quit."""
import io
import os
import sys
import wave
from urllib.parse import unquote

SR = 16000
FRAME_MS = 30
FRAME_SAMPLES = SR * FRAME_MS // 1000   # 480 samples = 960 bytes @ 16-bit mono


class VadEndpointer:
    """Signals end-of-utterance after `silence_ms` of trailing silence, but only once at least
    `min_speech_ms` of speech has occurred. Pure logic — fed one voiced/unvoiced flag per frame."""
    def __init__(self, frame_ms: int = 30, silence_ms: int = 800, min_speech_ms: int = 300):
        self.silence_needed = max(1, silence_ms // frame_ms)
        self.min_speech = max(1, min_speech_ms // frame_ms)
        self.speech_frames = 0
        self.trailing_silence = 0
        self.started = False

    def update(self, is_voiced: bool) -> bool:
        if is_voiced:
            self.speech_frames += 1
            self.trailing_silence = 0
            if self.speech_frames >= self.min_speech:
                self.started = True
        elif self.started:
            self.trailing_silence += 1
        return self.started and self.trailing_silence >= self.silence_needed


def _record_utterance(vad, ep) -> bytes:
    import sounddevice as sd
    frames = []
    with sd.RawInputStream(samplerate=SR, channels=1, dtype="int16",
                           blocksize=FRAME_SAMPLES) as stream:
        while True:
            data, _ = stream.read(FRAME_SAMPLES)
            pcm = bytes(data)
            if len(pcm) < FRAME_SAMPLES * 2:
                continue
            voiced = vad.is_speech(pcm, SR)
            if ep.started or voiced:
                frames.append(pcm)
            if ep.update(voiced):
                break
    return b"".join(frames)


def _to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm)
    return buf.getvalue()


def _play(wav_bytes: bytes) -> None:
    import sounddevice as sd
    import soundfile as sf
    data, sr = sf.read(io.BytesIO(wav_bytes), dtype="float32")
    sd.play(data, sr)
    sd.wait()


def main() -> None:
    import requests
    import webrtcvad
    host = os.environ.get("I3_HOST", "http://localhost:8082").rstrip("/")
    token = os.environ.get("VOICE_BEARER_TOKEN", "")
    thread_id = os.environ.get("THREAD_ID", "mac-voice")
    timezone = os.environ.get("TIMEZONE", "America/Havana")
    print(f"Voice client -> {host} (thread={thread_id}). Listening… Ctrl-C to quit.")
    while True:
        vad = webrtcvad.Vad(2)
        ep = VadEndpointer()
        pcm = _record_utterance(vad, ep)
        if len(pcm) < int(SR * 2 * 0.3):    # <300 ms captured -> ignore
            continue
        try:
            r = requests.post(
                f"{host}/v1/voice/turn",
                headers={"Authorization": f"Bearer {token}"},
                files={"audio": ("u.wav", _to_wav(pcm), "audio/wav")},
                data={"threadId": thread_id, "timezone": timezone},
                timeout=180,
            )
        except Exception as exc:
            print("net error:", exc)
            continue
        if r.status_code == 400:             # silence/no transcript -> just listen again
            continue
        if r.status_code != 200:
            print("error", r.status_code, unquote(r.headers.get("X-Reply-Text", "")))
            continue
        print("you:  ", unquote(r.headers.get("X-STT-Text", "")))
        print("gemma:", unquote(r.headers.get("X-Reply-Text", "")))
        _play(r.content)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
```

- [ ] **Step 4: Run to verify the endpointer test passes**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice-client/test_endpointer.py -v`
Expected: both endpointer tests PASS. (The test imports `voice_client`, which only imports stdlib at module level — `sounddevice`/`webrtcvad`/`requests`/`soundfile` are imported lazily inside functions, so the test needs no audio libs.)

- [ ] **Step 5: Create `voice-client/requirements.txt`**

```
sounddevice==0.5.1
webrtcvad==2.0.10
requests==2.32.3
soundfile==0.12.1
numpy==1.26.4
```

- [ ] **Step 6: Create `voice-client/README.md`**

```markdown
# Gemma Mac voice client

Thin client: captures your speech, sends it to the i3 voice gateway, plays the reply.

## Setup (macOS)
```
brew install portaudio        # if the sounddevice wheel doesn't bundle PortAudio
cd voice-client
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Run
```
I3_HOST=http://192.168.1.50:8082 \
VOICE_BEARER_TOKEN=<the MEMORY_BEARER_TOKEN from the i3 .env> \
python3 voice_client.py
```
Speak after "Listening…"; pause ~0.8 s to end your turn. Gemma answers by voice. Ctrl-C quits.
Env: `I3_HOST`, `VOICE_BEARER_TOKEN`, `THREAD_ID` (default `mac-voice`), `TIMEZONE` (default `America/Havana`).
```

- [ ] **Step 7: Commit**

```bash
git add voice-client/voice_client.py voice-client/test_endpointer.py voice-client/requirements.txt voice-client/README.md
git commit -m "feat(voice): thin Mac voice client (webrtcvad endpointing + POST + playback) + endpointer test"
```

---

## Task 7: Deploy to the i3 + curl E2E + live client

**Files:** none (deployment + verification).

- [ ] **Step 1: Push the branch and merge to main (or merge locally), then deploy**

The i3 pulls `main`. Either open a PR/merge per the team flow, or merge `sp-voice-1b` → `main` locally and push. Then on the i3:

```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && git pull origin main && docker compose up -d --build voice'
```
Expected: the `voice` image builds (pulls whisper-small + Kokoro — several minutes) and the container starts. If pip resolution fails, adjust the `kokoro`/`torch`/`numpy` pins in `voice/requirements.txt`, commit, re-pull, rebuild.

- [ ] **Step 2: Wait for healthy + confirm healthz**

```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && for i in $(seq 1 24); do s=$(docker inspect --format "{{.State.Health.Status}}" gemma-memory-voice-1 2>/dev/null); echo "$i: $s"; [ "$s" = healthy ] && break; sleep 5; done; curl -s -o /dev/null -w "healthz %{http_code}\n" http://localhost:8082/healthz'
```
Expected: `healthy` then `healthz 200`.

- [ ] **Step 3: curl E2E (WAV in → WAV out)** — from the Mac, make a 16 kHz mono WAV with built-in tools and POST it to the i3:

```bash
# On the Mac: synthesize a Spanish test utterance and downsample to 16k mono WAV (afconvert is built-in).
say -v Paulina "qué hora es" -o /tmp/q.aiff
afconvert /tmp/q.aiff /tmp/q.wav -d LEI16@16000 -c 1 -f WAVE
TOK=$(ssh HomeLab 'grep "^MEMORY_BEARER_TOKEN=" ~/Projects/gemma-memory/.env | cut -d= -f2-')
curl -s -D /tmp/h.txt -o /tmp/reply.wav \
  -H "Authorization: Bearer $TOK" \
  -F "audio=@/tmp/q.wav" -F "threadId=e2e-voice" -F "timezone=America/Havana" \
  http://192.168.1.50:8082/v1/voice/turn
grep -i "^x-stt-text\|^x-reply-text\|HTTP" /tmp/h.txt
afplay /tmp/reply.wav     # you should HEAR the spoken reply
```
Expected: `HTTP/1.1 200`, `X-STT-Text` ≈ `qu%C3%A9%20hora%20es` (percent-encoded), `X-Reply-Text` contains the time, and `/tmp/reply.wav` is an audible spoken reply with the current Havana time.

- [ ] **Step 4: Live client session (the real E2E)** — from the Mac:

```bash
cd /Users/hashdown/Projects/personal_agent/gemma-memory/voice-client
python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
I3_HOST=http://192.168.1.50:8082 VOICE_BEARER_TOKEN="$TOK" python3 voice_client.py
```
Expected: say **"¿qué hora es?"** → hear the time; say **"recuerda que me gusta el café cubano"** → next turn say **"¿qué bebida me gusta?"** → it answers café — all by voice. Prints `you:`/`gemma:` transcripts each turn.

- [ ] **Step 5: Confirm the voice container is healthy after the session**

```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && docker compose ps --format "table {{.Service}}\t{{.Status}}"'
```
Expected: `embedder`, `memory`, `voice` all `healthy`.

---

## Self-Review

**1. Spec coverage:**
- §4.1 data flow → Tasks 4 (handler chains STT→agent→TTS) + 6 (client capture/play). ✓
- §4.2 voice service (endpoint, STTEngine/FasterWhisper, TTSEngine/Kokoro, lang→voice, /healthz, engines built once) → Tasks 1–4. ✓
- §4.3 thin client (sounddevice, webrtcvad endpointing, POST, playback, config, --ptt note) → Task 6. ✓ (`--ptt` flag itself not implemented — it was described in the spec as a trivial alternative, not a 1b requirement; the manual VAD client is the deliverable. Acceptable per YAGNI; noted here so it's not a silent gap.)
- §4.4 docker-compose (ports 8082, env, depends_on, healthcheck, model pre-download, named volume) → Task 5. ✓
- §4.5 contract (multipart audio+threadId+timezone → audio/wav + X- headers, non-streamed) → Task 4. ✓
- §4.6 errors (missing/short→400, empty transcript→400+X-STT-Text, agent unreachable→spoken fallback 200, STT→502, TTS→502+X-Reply-Text, bearer 401) → Task 4 tests + handler. ✓
- §5 testing (mocked engines + fake agent unit tests; curl + live E2E) → Tasks 1–4 (unit) + 7 (E2E). ✓
- §4.7 latency → informational, no task needed. ✓

**2. Placeholder scan:** No "TBD/handle errors/etc." All steps have concrete code + commands. The two allowances (requirements pin-bump in Task 1/5; `kokoro`/`faster-whisper` real-model API validated at build/E2E not unit tests) are explicit, bounded build-time activities, not vague placeholders — consistent with the spec's "unit tests mock engines, E2E uses real models."

**3. Type consistency:** `STTEngine.transcribe(wav_bytes)->(text,lang)` and `TTSEngine.synthesize(text,lang)->bytes` are used identically in `engines.py`, the handler (`_stt.transcribe`, `_tts.synthesize`), and tests. `call_agent(text, thread_id, timezone)` signature matches its definition, the monkeypatch lambdas (`lambda text, tid, tz`/`lambda *a`), and the handler call. `LANG_VOICE` keys (`"es"`,`"en"`) match the map and tests. `VadEndpointer(frame_ms, silence_ms, min_speech_ms)` matches between client and its test. Header names `X-STT-Text`/`X-Reply-Text` consistent (handler sets, client + E2E read, case-insensitively). Env vars (`VOICE_FAKE_ENGINES`, `VOICE_BEARER_TOKEN`, `MEMORY_URL`, `MEMORY_BEARER_TOKEN`, `WHISPER_MODEL`, `WHISPER_CACHE`, `HF_HUB_CACHE`, `KOKORO_VOICE`) consistent across app.py, Dockerfile, compose. ✓
