# Model Router — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plan
**Repos touched:** `personal_agent` (macOS app — primary, built first) + `gemma-memory` (`memory-service`, the i3 server — built second).
**Sibling (already done):** Consolidation Hardening (`2026-06-04-consolidation-hardening-design.md`). This sub-project is the other half of the user's request.

---

## 1. Motivation

The local Gemma 4 26B (mlx) is not disciplined enough for the agent's job: it forces past schedule conflicts, doesn't reliably call tools, and miscomputes dates (diagnosed from real transcripts — see `agent-behavior-failure-modes`). Consolidation Hardening made the *system* correct regardless of model; this sub-project lets the user **plug in a much more capable model** (Gemini, Cerebras, Groq) while keeping the local Gemma as an option. All three cloud providers expose OpenAI-compatible `/v1/chat/completions`, which the existing `ServerRuntime` (app) and `RemoteModelClient` (server) already speak — so this is mostly a parameterization + configuration effort, not a new protocol.

## 2. Goals

1. The user picks the **chat** model provider (Local / Gemini / Cerebras / Groq) and the **consolidation** model provider **independently**, both from the macOS app.
2. Cloud providers work for chat (tools + streaming) and for consolidation (JSON extraction).
3. API keys are configured **only in the app**; the consolidation provider + key are pushed to the i3 and stored **encrypted at rest**.
4. The 15 GB local mlx model is spawned **only when a side actually uses "local"** (save RAM when fully cloud).
5. On provider error: **show a clear error, no fallback**.

## 3. Non-Goals

- Automatic fallback to local on cloud failure (explicitly rejected — show error).
- A "Test connection" button (deferred post-MVP).
- Streaming-token fan-in changes, new tool-calling formats (cloud providers are native OpenAI tools).
- Per-message/per-task routing or load-balancing across providers (YAGNI).
- Encrypting non-secret config (provider/model/baseURL stay plaintext).

## 4. Architecture

A **provider** is `{kind: local|gemini|cerebras|groq, baseURL, model, apiKey?}`. Two independent provider configs exist: **chat** (used by the app's runtime directly) and **consolidation** (pushed to the i3, used by `RemoteModelClient`). The app's Settings is the single configuration surface for both.

```
macOS app (personal_agent)
├─ Settings "Models": chat provider + consolidation provider (+ keys in Keychain)
├─ chat runtime  ── ServerRuntime(provider: chat)  ──► local mlx :8080  OR  cloud API
├─ ServerManager ── spawns local mlx ONLY IF chat==local OR consolidation==local
└─ on consolidation-config change/launch ── POST /v1/config/model ──► i3

i3 server (gemma-memory)
├─ POST/GET /v1/config/model  ── ModelConfigStore (sqlite, apiKey AES-GCM encrypted)
└─ consolidation ── RemoteModelClient(reads ModelConfigStore) ──► local mlx (Mac) OR cloud API
```

## 5. Provider registry (shared concept)

A `ModelProvider` kind enum + presets (each preset = default baseURL + default model; `model` is user-editable):

| kind | baseURL | default model | auth | mlx quirk |
|---|---|---|---|---|
| local | `http://localhost:8080` | `unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit` | none | `chat_template_kwargs:{enable_thinking:false}` |
| gemini | `https://generativelanguage.googleapis.com/v1beta/openai/` | `gemini-2.5-flash` | `Authorization: Bearer <key>` | omit |
| cerebras | `https://api.cerebras.ai/v1/` | `llama-3.3-70b` | `Authorization: Bearer <key>` | omit |
| groq | `https://api.groq.com/openai/v1/` | `llama-3.3-70b-versatile` | `Authorization: Bearer <key>` | omit |

The cloud `model` defaults are editable free-text (providers add/rename models often). The registry lives once per side (app Swift enum; server mirrors the kind→baseURL/quirk mapping).

## 6. Component design

### 6.1 App runtime (`personal_agent/Gemma/Gemma/Runtime/`)

- `ModelProvider` (new): `kind`, `baseURL: URL`, `model: String`, `apiKey: String?`; static `preset(for:)` and `defaultModel(for:)`.
- `ServerRuntime` gains `apiKey: String?` and derives auth + the mlx quirk from the provider `kind` (no separate boolean flag). Per-request:
  - cloud → add `Authorization: Bearer <apiKey>`; **omit** `chat_template_kwargs`.
  - local → unchanged (no auth; `enable_thinking:false`).
  - `baseURL`/`model` come from the provider. Tool-calls + SSE parsing unchanged (standard OpenAI).
- Error mapping in `ServerRuntime`: HTTP 401 → "API key inválida", 403 → "acceso denegado", 429 → "rate limit — intenta luego", URLError (offline/timeout) → "sin conexión a <provider>", other non-2xx → "<provider> error <code>". Surfaced as the turn's failure (`.generationFailed`-style), no retry.
- `RuntimeFactory.make` takes a `ModelProvider` (not just a kind) and constructs `ServerRuntime(provider:)`; `.dummy` stays. `HarnessModel` builds the chat provider from settings and rebuilds the runtime when chat settings change.

### 6.2 App Settings + key storage (`personal_agent/Gemma/Gemma/Settings/`)

- `SettingsView` "Models" section: two blocks (Chat, Consolidation), each = provider picker + editable `model` field + `SecureField` API key (shown only for cloud; placeholder "•••• guardada" when a key already exists).
- Non-secret prefs → `UserDefaults`: `chatProvider`, `chatModel`, `consolidationProvider`, `consolidationModel`.
- API keys → **Keychain**, one entry per provider kind (`apiKey.gemini`, `apiKey.cerebras`, `apiKey.groq`). New minimal `KeychainStore` (`get/set/delete(account:)`) wrapping `SecItem*`.
- On chat-config change → `HarnessModel.rebuildRuntime()`.
- On consolidation-config change (and on app launch) → push to the i3 (§6.4).

### 6.3 Local mlx lifecycle (`ServerManager`)

- `HarnessModel` computes `needsLocalModel = (chatProvider == .local) || (consolidationProvider == .local)` and drives `ServerManager`: the mlx server is spawned/keep-warmed **only when** `needsLocalModel`. When both sides are cloud, it does not spawn (and stops a running owned server). Switching either side to local triggers spawn-on-demand.
- The server status pill reflects local lifecycle only when local is in use; otherwise it shows the active chat provider name (e.g. "Gemini") with no process management.

### 6.4 Consolidation config push + persistence (`gemma-memory/memory-service`)

- New endpoint `POST /v1/config/model` (bearer-authed). Body: `{provider: String, baseURL: String, model: String, apiKey: String?}`. Updates `ModelConfigStore` (memory + sqlite). The app calls it when the consolidation config changes and on launch.
- New endpoint `GET /v1/config/model` (bearer-authed) → `{provider, baseURL, model, hasKey: Bool}` — **never returns the key**. For the app to display active state.
- `ModelConfigStore` (new, `MemoryCore`): a single-row `service_config` table `{provider, baseURL, model, apiKeyCipher BLOB?}`. Loads at boot into memory; if empty, defaults to `AppConfig.modelURL`/`modelName` (local mlx) so nothing breaks pre-push.
- App `MemoryClient` gains `setModelConfig(...)` and `modelConfig()`.

### 6.5 Server model client made dynamic (`RemoteModelClient`)

- `RemoteModelClient` reads the current provider from `ModelConfigStore` per call (or is reconfigured when the store changes). For cloud → adds `Authorization: Bearer <decrypted key>`, omits the mlx quirk; for local → current behavior. Consolidation does JSON-only extraction (no tools), so any provider works.

### 6.6 API key encryption at rest (i3)

- Dependency: **`swift-crypto`** (`import Crypto`) added to `memory-service/Package.swift` (Linux-compatible CryptoKit API).
- Key derivation: `encKey = HKDF<SHA256>(inputKeyMaterial: bearerToken, salt: "model-config-key", info: "apiKey", outputByteCount: 32)`. The bearer token is an existing server env secret and is **not** stored in the DB.
- Storage: `apiKeyCipher` = `AES.GCM.seal(plaintextKey, using: encKey).combined` (nonce+ciphertext+tag), stored as a BLOB. Decrypted in memory only when `RemoteModelClient` needs it.
- Threat model satisfied: copying `memory.sqlite` (as was done via `scp` during diagnosis) no longer exposes the API key — it's unreadable without the bearer token.

## 7. Data flow

- **Chat turn (cloud):** app reads chat provider from settings + key from Keychain → `ServerRuntime` POSTs to the provider with `Authorization` + tools, streams `tool_calls`/content → agent loop runs tools locally → renders. On error → mapped message, end turn.
- **Consolidation config change:** app → `POST /v1/config/model` (key in body, over Tailscale) → i3 encrypts key, persists → subsequent consolidation cycles use it.
- **Consolidation cycle:** `RemoteModelClient` reads `ModelConfigStore`, decrypts key if cloud, POSTs JSON-extraction prompt to the provider.

## 8. Error handling

- App cloud errors: mapped, surfaced, no fallback (§6.1).
- Missing key for a selected cloud provider: the app blocks sending + prompts to add a key in Settings; the i3 endpoint rejects a cloud config with no key (400).
- i3 boot with no persisted config: defaults to local mlx (no error).
- Decryption failure (e.g. bearer token rotated after a key was stored): `RemoteModelClient` logs and the consolidation phase no-ops for that cycle (existing `catch { return "" }` path); the app re-pushing the config fixes it.

## 9. Testing

**App (unit, no real network — `URLProtocol` mock):**
- `ServerRuntime`: cloud request has `Authorization: Bearer`, no `chat_template_kwargs`; local request has the quirk, no auth; correct baseURL/model per provider.
- Error mapping (401/403/429/offline → expected messages).
- `ModelProvider` presets (baseURL + default model per kind).
- `KeychainStore` get/set/delete round-trip.
- `HarnessModel` rebuilds runtime on chat-provider change; `needsLocalModel` logic (spawn iff either side local) across the 4×4 combinations (sampled).

**Server (unit):**
- `ModelConfigStore` persist/load; empty → `AppConfig` default.
- AES-GCM round-trip with HKDF-from-bearer key; DB holds ciphertext not plaintext; wrong token → decrypt fails.
- `POST /v1/config/model` requires auth, updates store, rejects cloud-without-key; `GET` returns config **without** key.
- `RemoteModelClient` reads dynamic config, adds auth for cloud, omits quirk for cloud.

**Integration / manual:**
- One full cloud chat turn via `URLProtocol` mock (CI, zero real calls).
- **Manual gated** verification against real Gemini/Cerebras/Groq (needs keys) — not in CI.

## 10. Implementation order (one plan, app-first)

1. App: `ModelProvider` + registry; `ServerRuntime` apiKey/quirk/error-mapping; `RuntimeFactory`/`HarnessModel` wiring.
2. App: `KeychainStore`; Settings "Models" UI (chat + consolidation blocks).
3. App: `needsLocalModel` spawn logic in `ServerManager`.
4. Server: `ModelConfigStore` + `swift-crypto` encryption; `POST/GET /v1/config/model`.
5. Server: `RemoteModelClient` dynamic provider + cloud auth.
6. App: `MemoryClient.setModelConfig/modelConfig` + push-on-change/launch.
7. Manual gated cloud verification.

## 11. Security notes

- App keys in Keychain (not UserDefaults).
- i3 key encrypted at rest (AES-GCM, HKDF-from-bearer); travels app→i3 in the request body over the authed channel — **recommend Tailscale (WireGuard) over plain LAN**.
- `GET /v1/config/model` never returns the key.
