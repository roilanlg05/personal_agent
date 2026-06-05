# Agent Gateway — Distributed JARVIS, Phase 1a (text) — Design Spec

**Date:** 2026-06-05
**Status:** Approved (brainstorm), pending plan
**Repo:** `gemma-memory` (i3 server). The macOS app is unchanged in this phase.

---

## 1. Motivation

The user's real goal is **distributed JARVIS**: any device — an ESP32 in a room, the phone, the laptop, anything — is a thin voice endpoint to one always-available brain. Today the agent (the JARVIS loop + tools) lives *inside* the macOS app (Swift); a thin device can't run it. The brain must become a **network service** that does the agentic turn for any caller.

Decided architecture: the gateway runs on the **always-on i3** (which already hosts the memory service), using the existing **Model Router** (the Mac's local mlx over the LAN when awake, cloud otherwise) — so the assistant is genuinely available 24/7. This spec covers **Phase 1a: the text agent gateway** — porting the brain to a service that takes text in and returns Gemma's full agentic reply (memory + tools). Audio (STT/TTS) bolts on in Phase 1b without touching the brain.

**Initiative decomposition (for context):**
- **Phase 1a (this spec):** text agent gateway on the i3 (`POST /v1/agent/turn`).
- **Phase 1b:** add STT/TTS → audio↔audio.
- **Phase 2:** wake word ("Hey Gemma") + always-listening on the first endpoint.
- **Phase 3:** more devices — ESP32 firmware, phone client.
- **Phase 4:** streaming, barge-in, multi-room.

## 2. Goals

1. A `POST /v1/agent/turn { text, threadId } → { reply }` endpoint on the i3 that runs the **full agentic loop** (tool-calling) with **memory + the 11 tools**, reaching the model via the Model Router.
2. **Tool parity** with the app's agent (same tools, same JARVIS prompt → same behavior), but the tools hit the store **directly** (co-located, no HTTP hop).
3. Verified via `curl` (a device posts text, gets the agentic reply with memory + tools). The macOS app keeps its local agent unchanged.

## 3. Non-Goals

- **Audio (STT/TTS)** — Phase 1b. This phase is text↔text.
- **Streaming** the reply — deferred (matters for TTS in 1b); 1a is non-streamed.
- **Migrating the macOS app** to call the gateway — deferred (the app keeps its fast local agent; it may migrate or stay as a "local fast path" later).
- **Wake word / device clients / episode-boundary management** — later phases; `threadId` is caller-supplied here.
- The `reflect` agent tool — dropped on the gateway (consolidation is automatic via the scheduler after each turn).

## 4. Design

### 4.1 Architecture (co-located in the memory service)

```
device ── POST /v1/agent/turn {text, threadId} ──▶ i3 memory service
  1. recall (services.retriever, direct)
  2. prompt = systemPrompt(JARVIS) + nowContext + recall-injection + history
  3. agentic LOOP (max 5 iterations):
       ToolCallingClient.generate(prompt, toolSpecs)  ──▶ Model Router (mlx Mac via LAN / cloud)
       if tool_calls → run server-side tools (store DIRECT) → augment prompt → next iteration
       else → final reply
  4. append transcript (user+assistant) + arm consolidation (scheduler)
                              ◀── {reply}
```

New components, all in `gemma-memory/memory-service`:

- **`AgentHandlers` + `POST /v1/agent/turn`** — non-streamed; decodes `{text, threadId?}`, runs the loop, returns `{reply}`. Registered in the `/v1` bearer group like the others.
- **`ToolCallingClient`** — a tool-calling model client (the existing `RemoteModelClient` does plain `generate` only). It reads the **agent** model config from `ModelConfigStore`, builds the OpenAI chat request with `tools` (function specs), and parses `tool_calls` from the response. Ports `ServerRuntime.generate(prompt:tools:options:)` from the app (which already does OpenAI tool-calling against mlx + cloud). Non-streamed parse (collect the full response, read `choices[0].message.{content,tool_calls}`).
- **Agent loop** — ports `Agent.run`: build the prompt, call `ToolCallingClient` with the tool specs; if the model returns tool calls, execute the server-side tools, append `[You called tool X(args) → result]` to the prompt, re-iterate (max 5); else return the final text. Mirrors the app's loop structure.
- **Server-side `AgentTool` protocol + 11 tools** — see §4.2.
- **Prompt assembly** — ports the app's `systemPromptText` + `scheduleConventions` + `nowContext(date)` (verbatim, so behavior matches) and the recall **`injectionBlock`** (built server-side from `services.retriever.retrieve` + `coreMemories` + summaries + recentTurns).
- **Post-turn writes** — append the user + assistant turns to `services.transcript` (server-assigned `seq`) and arm consolidation via `services.scheduler` — direct calls (the app does these over HTTP).

### 4.2 Server-side tools

A server `AgentTool` protocol: `{ name, description, parameters, run(argsJSON:, services:) async -> String }`, with `functionSpec`/`jsonSchema` built from `parameters` exactly like the app's. The 11 tools (descriptions ported verbatim from the app so the model behaves identically), each hitting the store directly:

| Tool | Server-side implementation |
|---|---|
| `current_time` | `Date()` + timezone |
| `save_memory` | the `save` handler logic (`upsertSelf` for kind=self, else `upsertMergingSemantic`) |
| `forget` | `store.forgetById` / `store.forgetByLabel` |
| `load_messages` | `transcript.range(threadId, from, to)` |
| `list_topics` | `store.distinctTags()` |
| `recall_by_topic` | the `by_topic` logic (topic→tag resolve + `store.nodesWithTag`) |
| `why` | the `why` logic (locate insight via FTS/semantic + traverse `derivesFrom`) |
| `check_schedule` | `store.scheduleConflicts(start, end)` |
| `create_event` | `store.createEventChecked(...)` |
| `query_schedule` | `store.scheduleWindow(from, to, includeCancelled)` |
| `cancel_events` | `store.cancelEvents(ids/from/to)` |

**DRY:** the `by_topic`, `why`, and `save` logic currently inline in the HTTP handlers is **extracted into shared functions** (in `Services` or free functions over the store) that BOTH the existing HTTP handlers and the new gateway tools call — no duplication. `reflect` is omitted (consolidation is automatic).

### 4.3 Contract, model config, errors

- **Contract (device-agnostic):** `POST /v1/agent/turn` (bearer) `{ "text": String, "threadId": String? }` → `{ "reply": String }`. Non-streamed. The same endpoint serves curl now and the phone/ESP32 later (audio wraps it in 1b). `threadId` is caller-supplied (a thin device passes a stable id); episode-boundary logic stays the caller's concern this phase.
- **Model config:** the gateway uses an **`agent` model config** stored on the i3 via the existing `ModelConfigStore` + `ConfigHandlers` (the app pushes it, mirroring how it already pushes the `consolidation` config) — so the agent uses the chat-quality model the user chose, not the consolidation model. The config selects the Model Router endpoint (Mac mlx over LAN / cloud).
- **Errors:** model unreachable → a clear reply ("I can't reach my model right now"), not a 500. A tool error → the tool returns an error string and the loop continues (as in the app). Empty `text` → 400.

### 5. Testing (Phase 1a)

- **Server (unit):** `ToolCallingClient` builds the OpenAI `tools` body + parses `tool_calls` from a canned response, reading the `agent` config. Each server-side tool's `run` calls the right store method + formats output (seeded data: `current_time`, `save_memory`, `recall_by_topic`, `why`, `query_schedule`). **Agent loop** with a FAKE model client (mirror the app's `Agent.run` test): (a) final-text → returns it; (b) one tool_call then final → executes the tool, re-feeds, returns final; (c) max-iterations cap. `/v1/agent/turn` handler: POST `{text}` with a canned client → `{reply}`, appends transcript (user+assistant), arms consolidation, 400 on empty `text`. Prompt assembly injects a seeded memory.
- **E2E manual (i3, real model):** `curl POST /v1/agent/turn {"text":"¿qué hora es?"}` → `current_time` → time reply; `{"text":"me llamo Roilan, recuérdalo"}` → `save_memory` → new turn "¿cómo me llamo?" → recalls "Roilan"; `{"text":"agéndame dentista mañana 3pm"}` → `create_event` (conflict-checked). Confirms the full agentic brain as a service.

## 6. Implementation order

1. `ToolCallingClient` (OpenAI tools request + tool_calls parse, reads the `agent` model config).
2. Extract shared `by_topic`/`why`/`save` logic from the HTTP handlers into reusable functions.
3. Server-side `AgentTool` protocol + the 11 tools (over the store/shared logic).
4. Prompt assembly (port `systemPromptText`/`scheduleConventions`/`nowContext` + the recall `injectionBlock`).
5. Agent loop (port `Agent.run`, server-side, non-streamed).
6. `POST /v1/agent/turn` handler + register + post-turn transcript/consolidation; `agent` model config on the i3.
7. Deploy server + manual E2E (curl).

Server rebuild/redeploy; no DB migration (reuses existing tables/store).
