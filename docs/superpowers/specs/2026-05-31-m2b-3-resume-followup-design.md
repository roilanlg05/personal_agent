# M2b-3 — Conscious resume of reflection + proactive follow-up on wake — Design

> **Parent vision:** `docs/superpowers/specs/2026-05-31-sleep-consolidation-vision.md`. **Phase 3** of the Sleep Consolidation memory. Builds on M2b-2 (`…m2b-2-sleep-consolidation-design.md`): the resumable `runCycle`, `ConsolidationScheduler`, `task`/`plan`/`insight` kinds, episodic nodes. (Reflection/abstraction already landed in M2b-2; M2b-3 is the proactivity/awareness piece.)
> **Date:** 2026-05-31. **Platform:** macOS app + local mlx-lm Gemma 4 26B, GRDB graph memory. **Branch:** `main`.
> **Guiding constraint (user):** quality over token cost (`[[user-prioritizes-quality-over-tokens]]`).

## 1. Goal

When the user returns, the agent feels like it was *there* — it resumes what it was thinking about and gently follows up on loose ends. Two capabilities, both about the agent being **aware on wake**:

**A. Conscious resume of an interrupted reflection.** When the user interrupts a sleep cycle (a message "wakes" the agent mid-dream), the cycle (a) **resumes promptly** — on the next short pause (~15s), not after another full 180s idle — and (b) the agent is **conscious it was reflecting**: it knows what it was thinking about and can reference it naturally ("estaba pensando en…").

**B. Proactive follow-up of pending things.** On the first turn of a session (or after a long gap), the agent proactively brings up unresolved items — pending **tasks/intentions** the user stated ("¿llamaste al dentista?", "¿cómo va lo del alemán?") and **conversational threads left hanging** ("la otra vez ibas a contarme X").

**Success:** interrupt the agent mid-consolidation → it resumes within ~15s and can say what it was reflecting on; come back later → it gently raises a pending task or dropped topic, naturally (not robotically), and stops raising it once resolved.

## 2. Decisions (locked in brainstorm 2026-05-31)

| Decision | Choice |
|---|---|
| Resume timing | **Prompt** — an interrupted cycle (persisted `sleep_cycle` exists) resumes on the short pause timer (~15s), not the long idle. |
| Resume awareness | The agent is **conscious** of the interrupted reflection: a short `focus` (what the cycle is about) is injected into the next turn so the agent can mention it. |
| Follow-up scope | **Both** actionable (pending `task`/`plan` nodes) AND conversational (unresolved threads detected from episodes). |
| Follow-up detection | A new sleep phase **`detect`** (LLM over the batch episodes) → `follow_up` nodes for unresolved intents/topics. Pending `task` nodes already exist (M2b-2). |
| Surfacing | On the **first turn of a session / after a long gap**, inject pending items into that turn's context so the agent raises them naturally; mark them resolved once addressed. |
| Awareness mechanism | **Context injection** into the turn's system prompt (not an emotional/persistent state). |
| Out of scope | Timed reminders/system notifications (that's S6/tools); cross-device. |

## 3. Architecture / components

### 3.1 Persist the reflection `focus` — `SleepCycleState` + `sleep_cycle` (migration `v3-sleep-focus`)
- Add `focus: String` to `SleepCycleState` and a `focus TEXT` column to `sleep_cycle` (additive GRDB migration `v3-sleep-focus`; existing rows default `""`).
- The engine sets `focus` when a cycle STARTS = a short human phrase of what it's consolidating, e.g. the first few batch entity/episode labels ("sushi, fútbol, Juan, el dentista"). Persisted with the cycle, so it survives the interruption.
- `MemoryStore.saveSleepCycle/loadSleepCycle` round-trip `focus`.

### 3.2 New `detect` phase + `follow_up` kind — `MemoryConsolidationEngine`
- Add `case followUp = "follow_up"` to the `NodeKind` vocabulary.
- New phase method `detectFollowUps(episodeTexts:)` (LLM): given the batch episode texts, ask the 26B for `{followUps:[{text, sources:[labels]}]}` — unresolved intents, open questions, or topics the user started but didn't finish. For each: create a `Node(kind: NodeKind.followUp.rawValue, body: text, layer: .daily, origin: .extracted, confidence: .probable, salience: 3)` with `NodeAttributes`-style `{status:"pending"}` in `extra`; link `relatedTo` edges to resolvable source entities. Dedup against existing pending `follow_up` nodes by `dedupKey(text)` (mirror the insight dedup). Anti-fabrication: only genuine open threads; few-shot + user-context in the prompt (lesson from M2b-2: prompts need user context + an example).
- Insert `.detect` into the cycle order: **`nrem → detect → rem → reflect → curate → shy`** (detect right after consolidate, while episode context is fresh and entities exist to link). `runCycle` handles it like any phase (resumable). `runLight` does NOT run detect (awake-light = associate+reflect only).

### 3.3 Prompt resume — `ConsolidationScheduler`
- The pause timer's handler: if a sleep cycle is **pending** (`store.loadSleepCycle()` returns non-nil — i.e. an interrupted cycle exists), resume it via `runCycle` instead of `runLight`. Otherwise behave as today (pause→light, idle→cycle). So an interrupted dream picks back up ~15s after the interrupting turn ends, rather than waiting the full idle.
- Inject a `hasPendingCycle: () -> Bool` (reads the store) so this stays testable with the spy/fakes.
- `noteUserActivity()` still cancels the running cycle at turn start (user priority); the persisted phase + focus remain for the prompt resume.

### 3.4 Conscious + follow-up injection — `HarnessModel` + `Agent`
- **Agent** gains an optional `wakeContext: String` (init param, default ""). `systemPrompt(memoryBlock:)` appends it (after the base + memory block) when non-empty. Keeps the Agent caller-agnostic.
- **HarnessModel.runAgentTurn** builds `wakeContext` per turn:
  - **Conscious resume:** if `store.loadSleepCycle()?.focus` is non-empty (a cycle is pending/was just interrupted), add: *"(You were just reflecting on: <focus>. You may mention this naturally if relevant.)"*
  - **Follow-up surfacing:** if this is the FIRST turn of the session OR the gap since the last turn exceeds a threshold (track `lastTurnEndedAt`; gap > ~the idle threshold, or first turn), retrieve `store.pendingFollowUps()` (pending `task`/`plan` + `follow_up` nodes, capped at a few) and add: *"Things the user left pending you can gently follow up on if it fits: <list>. Don't force them."*
  - Pass `wakeContext` when constructing the per-turn `Agent`.
- **Resolution:** keep it simple for v1 — surfacing is best-effort context; mark a `follow_up`/`task` resolved when the user indicates it's done via the existing `forget`/`save_memory(... status done)` path, OR a light heuristic (out of scope to auto-detect resolution reliably; v1 surfaces, and the sleep `forget`/decay + the user's own statements eventually clear them). Document this.
- `MemoryStore.pendingFollowUps(limit:)` helper: non-deleted `task`/`plan` nodes with `status:"pending"` (or no status) + `follow_up` nodes with `status:"pending"`, ordered by recency/salience.

### 3.5 UI (light)
- The "🌙" banner already shows consolidation phases; `detect` appears as a phase. No new required UI. (Optional: the memory graph already colors kinds; give `follow_up` a color — minor.)

## 4. Data flow
**Resume:** `sleep cycle running → user sends a turn → noteUserActivity() cancels it (phase+focus persisted) → turn runs (wakeContext includes "you were reflecting on <focus>") → ~15s pause after the turn → scheduler sees a pending cycle → resumes runCycle from the persisted phase`.
**Follow-up:** `sleep cycle's detect phase → follow_up nodes (pending) + task nodes already pending → next session's first turn (or after a gap) → HarnessModel injects pending items into wakeContext → agent raises them naturally`.

## 5. Error handling
- Malformed `detect` JSON → no follow-ups that cycle (phase no-ops, cycle advances).
- No pending cycle → pause timer runs light reflection as before. No focus → no conscious-resume injection.
- No pending follow-ups / not first-turn-or-gap → no follow-up injection (normal turn).
- Migration `v3-sleep-focus` additive; existing `sleep_cycle` rows get `focus=""`.
- Dedup prevents follow-up accumulation across cycles.

## 6. Testing
- **`detectFollowUps`** (fake runtime canned JSON, in-memory store): creates `follow_up` nodes (pending) + source edges; dedups repeats; malformed JSON → no-op.
- **`SleepCycleState.focus`** round-trips through `saveSleepCycle/loadSleepCycle` (migration ok on a fresh + on a v2 DB).
- **runCycle** sets `focus` at start; `.detect` runs in order; resume still works with the 6-phase order.
- **Scheduler prompt-resume:** with `hasPendingCycle = true`, the pause timer fires `runCycle` (not `runLight`); with `false`, fires `runLight`. (spy runner + injected intervals.)
- **`pendingFollowUps`**: returns pending task/plan/follow_up, excludes done/deleted.
- **HarnessModel wakeContext (unit-ish):** given a pending cycle focus → wakeContext contains it; first-turn/after-gap with pending items → wakeContext lists them; normal mid-session turn with no pending → empty wakeContext. (Test the pure `buildWakeContext` helper directly to avoid driving the full turn.)
- **Agent**: a non-empty `wakeContext` appears in the system prompt; empty → unchanged (existing AgentMemoryTests stay green).
- **Manual (macOS, real 26B):** state a task + a dropped topic → run a cycle → `follow_up`/`task` nodes exist; relaunch → first turn, the agent gently raises them. Interrupt a running cycle with a message → the agent can mention what it was reflecting on, and the cycle resumes ~15s later. Record.

## 7. Out of scope (later)
- Reliable auto-detection that a follow-up was resolved (v1: best-effort; cleared by user statements / decay).
- Timed reminders / OS notifications (S6 tools).
- Emotional/persistent mood state (awareness is per-turn context injection only).

## 8. File structure
**New:** tests `GemmaTests/FollowUpDetectionTests.swift` (or fold into `MemoryConsolidationEngineTests`), `GemmaTests/WakeContextTests.swift`, `GemmaTests/SchedulerResumeTests.swift` (or fold into `ConsolidationSchedulerTests`).
**Modified:** `Memory/MemoryModels.swift` (+`followUp` kind), `Memory/MemoryStore.swift` (`v3-sleep-focus` migration + `SleepCycleState.focus` + `pendingFollowUps`), `Memory/MemoryConsolidationEngine.swift` (`detectFollowUps` phase, `.detect` in `SleepPhase`+order, set `focus` at cycle start), `Memory/ConsolidationScheduler.swift` (prompt-resume on pause when pending; `hasPendingCycle` seam), `Agent/Agent.swift` (`wakeContext` injected into system prompt), `Harness/HarnessModel.swift` (`buildWakeContext` + `lastTurnEndedAt` + pass to Agent), optionally `Harness/MemoryGraphView.swift` (`follow_up` color).

## 9. Resultado M2b-3 (VERIFICADO contra el 26B real, 2026-05-31)

Plan `…m2b-3-resume-followup.md` ejecutado (subagent-driven, doble review + fixes por unidad). Commits `cb5ea1e`…`8410267` en `main`.

- **Parte A — retomar la reflexión, pronto + consciente:** `SleepCycleState.focus` persistido (migración `v3-sleep-focus`); el `ConsolidationScheduler` reanuda un ciclo pendiente en la **pausa corta (~15s)** (`hasPendingCycle`), no en el idle largo; `Agent` inyecta `wakeContext` en el system prompt; `HarnessModel.buildWakeContext` arma "(estabas reflexionando sobre <focus>)" — **gated al turno que interrumpe un ciclo activo** (fix de review: sin nag).
- **Parte B — follow-up proactivo:** nueva fase **`detect`** (orden `nrem→detect→rem→reflect→curate→shy`) → nodos `follow_up{status:pending}`; kind `follow_up`; `MemoryStore.pendingFollowUps`; en el **primer turno / tras gap >180s** (`isWake`) se inyectan los pendientes (tasks/plans/follow_ups) en el contexto para que el agente los retome naturalmente.
- **E2E real (26B):** (1) prompt de `detect` con una conversación de cabos sueltos → `{"call the dentist","hear about the trip to Japan"}` correcto. (2) Ciclo completo de 6 fases (`SleepConsolidationE2ETests`): **+7 entidades, +2 follow_ups** ("call the dentist","learn German" pending), +5 edges; `distinct kinds` incluye `follow_up`. (insights 0 esa corrida — reflect es estocástico; en M2b-2 dio 1.)
- **Pendiente (humano):** check visual GUI — interrumpir un ciclo y ver que el agente menciona qué reflexionaba + reanuda ~15s; relanzar y ver follow-up proactivo; sin dar la lata a mitad de sesión.

**M2b (la memoria "Sleep Consolidation") está COMPLETA:** captura episódica + save_memory estructurado + dedup semántico (M2b-1) → ciclo de sueño multi-fase con kinds extensibles, asociación, reflexión, curación, olvido (M2b-2) → retomar consciente + follow-up proactivo (M2b-3).

## 10. Hallazgo: thinking-ON rompe la consolidación (decidido thinking-OFF, 2026-05-31)

Se probó (petición del usuario) usar **thinking-ON** en las generaciones de consolidación, midiendo contra el 26B real. Resultado: **thinking-ON degrada TODAS las fases de salida-JSON.** El modelo sobre-razona (p.ej. 6900 chars / ~2048 tokens de razonamiento para una extracción simple), consume el presupuesto y **trunca el `content` a vacío** → 0 entidades (o 0 edges / 0 insights según la corrida), ~3.5–5× más lento (140–223s vs ~40s), e inventa kinds no estándar (`name`/`interest`/`workplace`). Subir el budget a 4096/8192 no lo hace fiable (el razonamiento es variable y a veces excede). El híbrido (thinking-on solo en associate/reflect) sólo movió la rotura a esas dos fases (0 edges/0 insights). 

**Decisión: toda la consolidación corre thinking-OFF** (config verificada-buena: 7 entidades + 5 edges + 1 insight, ~40s, kinds estándar limpios). El chain-of-thought visible no ayuda a producir JSON estructurado en este modelo — lo rompe. Los turnos interactivos ya eran thinking-off. Se eliminó el override `enableThinking` por-request (quedó sin uso). `ServerRuntime.enableThinking` (default false) se conserva por si alguna vez se quiere razonamiento en alguna ruta. (Commits del análisis/revert: `e8a361b`…`c5d5f59`.)
