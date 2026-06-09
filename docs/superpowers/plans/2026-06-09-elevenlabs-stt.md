# ElevenLabs Scribe STT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the self-hosted faster-whisper STT with ElevenLabs Scribe in the voice service, fixing transcription errors and CPU slowness, while keeping Kokoro TTS and the Cerebras agent untouched.

**Architecture:** Add an `ElevenLabsScribeSTT` engine (conforms to the existing `STTEngine` protocol) that POSTs the WAV to the ElevenLabs Scribe API; select it in `_make_stt()` by env so only the chosen engine is instantiated (whisper's model is never loaded). Force English so the returned language deterministically pins the agent reply + Kokoro voice.

**Tech Stack:** Python, FastAPI, `httpx` (already a dependency), pytest. Service at `gemma-memory/voice/`. Deployed on the i3 (SSH host `HomeLab`) via `docker compose`.

**Verified API (ElevenLabs Scribe):** `POST https://api.elevenlabs.io/v1/speech-to-text`; auth header `xi-api-key`; `multipart/form-data` fields `file` (binary), `model_id` (`scribe_v1`), `language_code` (ISO-639-1, e.g. `en`); JSON response fields `text` and `language_code`.

**Conventions:** Run tests from the repo root: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -q`. The current `_make_stt()` (`voice/app.py:20-25`) returns `FakeSTT()` when `VOICE_FAKE_ENGINES=1`, else `FasterWhisperSTT(WHISPER_MODEL)`. The `STTEngine` protocol (`voice/engines.py`) is `transcribe(wav_bytes: bytes) -> Tuple[str, str]` returning `(text, language_code)`.

---

### Task 1: `ElevenLabsScribeSTT` engine

**Files:**
- Modify: `gemma-memory/voice/engines.py` (add the class + a top-level `import httpx`)
- Test: `gemma-memory/voice/test_app.py` (append engine tests)

- [ ] **Step 1: Write the failing tests**

Append to `gemma-memory/voice/test_app.py` (before the end of the file):

```python
import httpx  # noqa: E402
import pytest  # noqa: E402
from engines import ElevenLabsScribeSTT  # noqa: E402


def test_elevenlabs_stt_parses_text_and_forces_language(monkeypatch):
    captured = {}

    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"text": " hello world ", "language_code": "es"}  # detected es

    def fake_post(url, **kw):
        captured["url"] = url
        captured["headers"] = kw.get("headers")
        captured["data"] = kw.get("data")
        captured["files"] = kw.get("files")
        return FakeResp()

    monkeypatch.setattr(httpx, "post", fake_post)
    stt = ElevenLabsScribeSTT(api_key="k", model="scribe_v1", language="en")
    text, lang = stt.transcribe(b"RIFF....")
    assert text == "hello world"          # trimmed
    assert lang == "en"                   # forced, ignores detected "es"
    assert captured["url"] == "https://api.elevenlabs.io/v1/speech-to-text"
    assert captured["headers"]["xi-api-key"] == "k"
    assert captured["data"]["model_id"] == "scribe_v1"
    assert captured["data"]["language_code"] == "en"
    assert captured["files"]["file"][0] == "audio.wav"


def test_elevenlabs_stt_autodetect_when_language_none(monkeypatch):
    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"text": "hola", "language_code": "es"}

    monkeypatch.setattr(httpx, "post", lambda url, **kw: FakeResp())
    stt = ElevenLabsScribeSTT(api_key="k", language=None)
    text, lang = stt.transcribe(b"x")
    assert (text, lang) == ("hola", "es")  # returns detected language


def test_elevenlabs_stt_raises_on_http_error(monkeypatch):
    class FakeResp:
        def raise_for_status(self):
            raise httpx.HTTPStatusError("boom", request=None, response=None)
        def json(self): return {}

    monkeypatch.setattr(httpx, "post", lambda url, **kw: FakeResp())
    stt = ElevenLabsScribeSTT(api_key="k")
    with pytest.raises(httpx.HTTPStatusError):
        stt.transcribe(b"x")


def test_elevenlabs_stt_requires_api_key():
    with pytest.raises(RuntimeError):
        ElevenLabsScribeSTT(api_key="")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -q -k elevenlabs`
Expected: FAIL — `ImportError: cannot import name 'ElevenLabsScribeSTT'`.

- [ ] **Step 3: Implement the engine**

In `gemma-memory/voice/engines.py`, add `import httpx` to the top imports, then add this class after `FasterWhisperSTT` (and before the `# --- TTS ---` section):

```python
class ElevenLabsScribeSTT:
    """ElevenLabs Scribe speech-to-text (cloud). Expects 16 kHz mono WAV bytes.
    `language` (ISO-639-1, e.g. "en") forces the language AND is returned verbatim, so the
    downstream agent reply + TTS voice are pinned deterministically; leave None for auto-detect.
    No local model is loaded."""
    _URL = "https://api.elevenlabs.io/v1/speech-to-text"

    def __init__(self, api_key: str, model: str = "scribe_v1", language: str | None = None):
        if not api_key:
            raise RuntimeError("ElevenLabsScribeSTT requires ELEVENLABS_API_KEY")
        self._api_key = api_key
        self._model = model
        self._language = language or None

    def transcribe(self, wav_bytes: bytes) -> Tuple[str, str]:
        data = {"model_id": self._model}
        if self._language:
            data["language_code"] = self._language
        files = {"file": ("audio.wav", wav_bytes, "audio/wav")}
        r = httpx.post(self._URL, headers={"xi-api-key": self._api_key},
                       data=data, files=files, timeout=30)
        r.raise_for_status()
        body = r.json()
        text = (body.get("text") or "").strip()
        # Forced language wins (deterministic pinning); else the detected code; else "en".
        lang = self._language or body.get("language_code") or "en"
        return text, lang
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -q -k elevenlabs`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent/gemma-memory
git add voice/engines.py voice/test_app.py
git commit -m "feat(voice): ElevenLabsScribeSTT engine (cloud STT, forced language)"
```

---

### Task 2: Select ElevenLabs in `_make_stt()`

**Files:**
- Modify: `gemma-memory/voice/app.py:20-25` (`_make_stt`)
- Test: `gemma-memory/voice/test_app.py` (append selection tests)

- [ ] **Step 1: Write the failing tests**

Append to `gemma-memory/voice/test_app.py`:

```python
def test_make_stt_selects_elevenlabs_when_engine_flag_set(monkeypatch):
    monkeypatch.delenv("VOICE_FAKE_ENGINES", raising=False)
    monkeypatch.setenv("STT_ENGINE", "elevenlabs")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    monkeypatch.setenv("STT_LANGUAGE", "en")
    stt = appmod._make_stt()
    assert isinstance(stt, ElevenLabsScribeSTT)
    assert stt._language == "en"


def test_make_stt_elevenlabs_without_key_raises(monkeypatch):
    monkeypatch.delenv("VOICE_FAKE_ENGINES", raising=False)
    monkeypatch.setenv("STT_ENGINE", "elevenlabs")
    monkeypatch.delenv("ELEVENLABS_API_KEY", raising=False)
    with pytest.raises(RuntimeError):
        appmod._make_stt()


def test_make_stt_fake_when_fake_engines(monkeypatch):
    monkeypatch.setenv("VOICE_FAKE_ENGINES", "1")
    from engines import FakeSTT
    assert isinstance(appmod._make_stt(), FakeSTT)
```

(`appmod` is already imported at the top of `test_app.py` as `import app as appmod`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -q -k make_stt`
Expected: FAIL — `_make_stt` still returns `FasterWhisperSTT` (which would try to load a model) / does not branch on `STT_ENGINE`.

- [ ] **Step 3: Implement the selection**

Replace `_make_stt()` in `gemma-memory/voice/app.py` (currently lines 20-25) with:

```python
def _make_stt():
    if os.environ.get("VOICE_FAKE_ENGINES") == "1":
        from engines import FakeSTT
        return FakeSTT()
    engine = os.environ.get("STT_ENGINE", "").lower()
    api_key = os.environ.get("ELEVENLABS_API_KEY", "")
    # Opt into ElevenLabs by explicit flag, or implicitly when a key is present and no other engine
    # was chosen. Fail fast if the flag is set without a key (don't silently fall back to whisper).
    if engine == "elevenlabs" or (engine == "" and api_key):
        if not api_key:
            raise RuntimeError("STT_ENGINE=elevenlabs but ELEVENLABS_API_KEY is not set")
        from engines import ElevenLabsScribeSTT
        return ElevenLabsScribeSTT(
            api_key=api_key,
            model=os.environ.get("ELEVENLABS_STT_MODEL", "scribe_v1"),
            language=os.environ.get("STT_LANGUAGE") or None,
        )
    from engines import FasterWhisperSTT
    return FasterWhisperSTT(os.environ.get("WHISPER_MODEL", "small"))
```

- [ ] **Step 4: Run the tests to verify they pass + full voice suite**

Run: `cd /Users/hashdown/Projects/personal_agent/gemma-memory && python3 -m pytest voice/test_app.py -q`
Expected: all pass (the new selection + engine tests plus the existing suite which uses
`VOICE_FAKE_ENGINES=1`). If `python-multipart` is missing locally, install once:
`python3 -m pip install --break-system-packages python-multipart`.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent/gemma-memory
git add voice/app.py voice/test_app.py
git commit -m "feat(voice): _make_stt selects ElevenLabs by env (fail-fast without key)"
```

---

### Task 3: Compose env + deploy to the i3 + smoke

**Files:**
- Modify: `gemma-memory/docker-compose.yml` (the `voice` service `environment:` block)
- (i3) `~/Projects/gemma-memory/.env` — add the key (manual, not committed)

- [ ] **Step 1: Add env vars to the compose `voice` service**

In `gemma-memory/docker-compose.yml`, under the `voice:` service `environment:` list, add these lines
(next to the existing `WHISPER_*` lines, which stay as the inert fallback):

```yaml
      - ELEVENLABS_API_KEY=${ELEVENLABS_API_KEY}
      - STT_ENGINE=elevenlabs
      - STT_LANGUAGE=en
      - ELEVENLABS_STT_MODEL=scribe_v1
```

- [ ] **Step 2: Commit + push the compose change**

```bash
cd /Users/hashdown/Projects/personal_agent/gemma-memory
git add docker-compose.yml
git commit -m "chore(voice): wire ElevenLabs STT env into compose"
git push origin main
```

- [ ] **Step 3: Put the API key in the i3 `.env` (USER action)**

The user adds their key to `~/Projects/gemma-memory/.env` on the i3 (do NOT paste it in chat). For
example, over SSH: append a line `ELEVENLABS_API_KEY=<the key>` to that file. Verify it's set
(without printing the value):

```bash
ssh HomeLab 'grep -q "^ELEVENLABS_API_KEY=." ~/Projects/gemma-memory/.env && echo "key present" || echo "KEY MISSING"'
```
Expected: `key present`.

- [ ] **Step 4: Pull + rebuild the voice container on the i3**

```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && git pull --ff-only && docker compose up -d --build voice'
```
Expected: voice container Recreated + Started.

- [ ] **Step 5: Smoke — confirm the request reaches Scribe (auth OK), not whisper**

Confirm the engine wired up (no whisper model load) and a request reaches ElevenLabs. A synthetic
silent WAV will reach Scribe and come back as empty text (our handler then returns 400 with an empty
`X-STT-Text`), proving auth + path work; a 401/“key” error would mean a bad key.

```bash
ssh HomeLab 'TOKEN=$(grep -E "^MEMORY_BEARER_TOKEN=" ~/Projects/gemma-memory/.env | cut -d= -f2-)
# 0.5s of silence as a 16k mono wav
python3 - <<"PY" > /tmp/s.wav
import wave,io
b=io.BytesIO()
w=wave.open(b,"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"\x00\x00"*8000); w.close()
open("/tmp/s.wav","wb").write(b.getvalue())
PY
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8082/v1/voice/turn \
  -H "Authorization: Bearer $TOKEN" -F "audio=@/tmp/s.wav;type=audio/wav" -F "threadId=elsmoke"
echo "=== voice logs (should show NO faster-whisper load) ==="
docker logs gemma-memory-voice-1 --since 2m 2>&1 | grep -iE "whisper|scribe|stt|error" | tail -10'
```
Expected: an HTTP code of `400` (empty transcript ⇒ Scribe ran and returned nothing for silence) or
`200`; NOT `502` with an auth error. Logs show no faster-whisper model download/load.

- [ ] **Step 6: Real mic E2E (USER)**

The user speaks a real English sentence through the app and confirms accurate transcription + faster
turn. (Generating real speech audio from a script is out of scope; the synthetic smoke only proves
the path/auth.)

---

## Self-Review

**Spec coverage:**
- `ElevenLabsScribeSTT` engine (POST, headers, multipart fields, response parse, forced language) → Task 1. ✓
- `_make_stt()` selection (env opt-in, fail-fast without key, only-instantiate-chosen) → Task 2. ✓
- Compose env + i3 `.env` key + deploy → Task 3. ✓
- Mocked tests (parse, force-language, autodetect, http-error, requires-key, selection) → Tasks 1–2. ✓
- Keep Kokoro/agent/pipeline untouched → no task modifies them. ✓

**Placeholder scan:** none — every code step is complete. The only manual step is the user adding
the key to the i3 `.env` (Task 3 Step 3), which is inherently a human action.

**Type consistency:** `ElevenLabsScribeSTT(api_key, model="scribe_v1", language=None)` and its
`transcribe(wav_bytes) -> (text, lang)` are used identically in the engine, its tests, and
`_make_stt()`. Env var names (`ELEVENLABS_API_KEY`, `STT_ENGINE`, `STT_LANGUAGE`,
`ELEVENLABS_STT_MODEL`) match across `_make_stt`, compose, and the spec.

**Scope:** single subsystem (the voice service's STT engine). TTS, agent, pipeline untouched.
