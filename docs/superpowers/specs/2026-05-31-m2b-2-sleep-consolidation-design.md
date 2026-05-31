# M2b-2 — Consolidation system: awake reflection + sleep cycle + structured/extensible memory — Design

> **Parent vision:** `docs/superpowers/specs/2026-05-31-sleep-consolidation-vision.md`. **Phase 2** of the Sleep Consolidation memory, built on M2b-1 (episodic chat capture, `SaveMemoryTool`, semantic dedup `upsertMergingSemantic`, EMA salience, identity-only core).
> **Date:** 2026-05-31. **Platform:** macOS app + local mlx-lm Gemma 4 26B, GRDB graph memory. **Branch:** `main`.
> **Guiding constraint (user):** quality over token cost (`[[user-prioritizes-quality-over-tokens]]`) — multiple LLM generations per cycle are fine.

## 1. Goal

Make memory **self-organizing and brain-like**. Three intertwined capabilities:
1. **Structured, extensible memory** — memory isn't a flat scatter of facts; it has node *kinds* (people, places, preferences, personality `trait`s, `task`s pending/done, `plan`s short/long, `insight`s, …), and **the model can mint new kinds** when useful. Sleep **curates** the kind vocabulary (merges synonyms, drops junk) so it stays clean.
2. **Awake reflection (light)** — the model doesn't only consolidate during "sleep"; it reflects *while awake* on what was just discussed, both **on its own initiative** (a `reflect` tool) and **automatically after a short pause**. Light and instantly yielding.
3. **Sleep consolidation (full)** — when idle, a biologically-grounded multi-phase cycle replays the episodic stream: consolidate → associate → reflect → curate → forget. Resumable across interruptions.

**Success:** a real conversation yields structured nodes (tasks/plans/traits, not just loose facts), associative edges, grounded insights; the kind vocabulary stays coherent; the model occasionally reflects mid-session; and the heavy work happens during idle without ever making the user wait.

## 2. Decisions (locked in brainstorm 2026-05-31)

| Decision | Choice |
|---|---|
| Consolidation tiers | **Awake (light)** + **Sleep (full)** — same phase operations, different trigger/scope. |
| Awake triggers | **BOTH:** an agentic `reflect` tool the model can call, AND an automatic short-pause (~15–20s) trigger. |
| Sleep structure | **Multi-phase resumable cycle**, biologically grounded. |
| Sleep phases (order) | **1 NREM Consolidate → 2 REM Associate → 3 Reflect Abstract → 4 Curate (kinds) → 5 SHY Forget.** |
| Resumability | Cycle persists current phase + episode batch; interrupted → resume from the next phase. |
| Node kinds | **Free-form `String`** with a curated well-known vocabulary (`NodeKind` constants). The model may **mint new kinds**, stored verbatim. |
| Kind curation | **Open + curated in sleep:** the Curate phase merges synonymous kinds (e.g. `meta`→`plan`) into the canonical vocabulary and drops junk. |
| New structured kinds | `trait` (personality), `task` (+`status` pending/done in `extra`), `plan` (+`horizon` short/long), `insight` (grounded, from Reflect). |
| Trigger (sleep) | Idle ~180s, **visible per-phase progress**, **+ manual "Consolidate now"** button. |
| Concurrency | Yields to the user at **phase boundaries**: a user turn cancels the running cycle/awake-reflection (aborting the in-flight generation); each phase persists before advancing. mlx-lm serializes → worst case the user waits for one in-flight generation to abort. |
| Anti-fabrication | Reflect insights grounded in **≥2 existing memories** (cite sources); awake reflection only over **recent** content. |
| Reuse | `MemoryStore`/`upsertMergingSemantic`/`sweep`/`Embedder`/`MemoryText`; `ModelRuntime.generate(prompt:options:)`; M2b-1 episodic nodes. |

## 3. Architecture

```
HarnessModel
├─ ConsolidationScheduler (@MainActor @Observable)
│    ├─ awake: short-pause timer (~15s after a reply) ─► runLight(scope:.recent)
│    ├─ sleep: idle timer (~180s) ─────────────────────► runCycle()  (resumable)
│    └─ noteUserActivity(): cancels any running consolidation + resets timers
│         └─ MemoryConsolidationEngine
│              ├─ Phase NREM  Consolidate (LLM: episodes → entities/structured nodes → upsertMergingSemantic)
│              ├─ Phase REM   Associate   (LLM: nodes → edges)
│              ├─ Phase Reflect Abstract  (LLM: memories → grounded insight nodes + source edges)
│              ├─ Phase Curate           (LLM: distinct kinds → canonical map → reassign/merge kinds, drop junk)
│              └─ Phase SHY   Forget      (deterministic: sweep + prune weak edges)
├─ reflect AgentTool (agentic awake trigger) ──► scheduler.requestLightReflection()
└─ AgentChatView ── "🌙 <phase>… +entities/+edges/+insights" + "Consolidar ahora" button
```
**Awake (light)** runs only the cheap, recent-scope operations: **Associate + Reflect** over the *last turn(s)* + creating structured `task`/`plan`/`trait` nodes from the recent content. It does NOT replay the whole batch, curate, or forget. **Sleep (full)** runs all 5 phases over the whole unconsolidated batch.

### 3.1 Structured + extensible kinds (foundation)
- **`Node.kind` becomes `String`** (the DB column is already text). Keep `enum NodeKind: String` as the **curated vocabulary of constants** (`person, place, preference, fact, topic, trait, task, plan, insight, episode, conversation, day`) used in Swift, but persist/read the raw string so **unknown model-minted kinds are preserved** (no more `NodeKind(rawValue:) ?? .fact` coercion that silently dropped them).
  - Refactor sites (M2b-1 code): `Node.kind`, `SaveMemoryTool`, `MemoryStore.findDuplicate(kind:)`/`findSemanticDuplicate(kind:)`, `MemoryRetriever`, `EpisodeRecorder`, the inspector/graph color map, tests. Mechanical: compare/store kind as String; `NodeKind.task.rawValue` etc. where constants are wanted.
- **Kind-specific attributes in `extra` JSON** (no schema migration): `task` → `{status:"pending"|"done"}`, `plan` → `{horizon:"short"|"long"}`. A tiny `NodeAttributes` Codable helper reads/writes these in `extra` (alongside the episode `Meta` from M2b-1 — namespace the JSON so both coexist, e.g. one merged dict).
- **Curate phase** keeps the vocabulary clean (see 3.3 Phase 4).

### 3.2 `Memory/MemoryConsolidationEngine.swift` (new) — the shared phase operations
Init injects `store`, `embedder`, `runtime: ModelRuntime`, `now` provider, `progress` callback. Pure-ish; persists cycle state via the store. All LLM phases parse JSON defensively (reuse `extractJSON`); malformed → phase no-ops but the cycle still advances. Methods (each a unit):
- `consolidate(episodes:) async` — NREM. Prompt the 26B with episode texts + current entity labels → JSON `{entities:[{entity,kind,detail,permanent,attributes?}]}`. Clean/junk-filter, `upsertMergingSemantic`. `kind` is taken verbatim (may be a new kind). Structured attrs (status/horizon) → `extra`.
- `associate(nodes:) async` — REM. Prompt with candidate entities → `{edges:[{from,relation,to}]}`; resolve endpoints (label→semantic fallback), create non-duplicate `Edge`s (relation from the `Relation` enum).
- `reflect(memories:) async` — Reflect. Prompt for `{insights:[{text,sourceEntities:[labels],confidence}]}`; drop insights citing `<2` resolvable sources; create `insight` nodes + `relatedTo` edges to sources.
- `curateKinds() async` — Curate. Collect the DISTINCT kind strings in the store; prompt the 26B `{map:{"<rawKind>":"<canonicalKind>"}}` to fold synonyms into the canonical vocabulary (and flag junk → e.g. map to `fact` or drop); apply by updating nodes' `kind`. Cheap (operates on the small kind vocabulary, not all nodes).
- `forget() async` — SHY. Deterministic: `store.sweep()` + prune edges whose endpoints are deleted or weight decayed below a floor.

### 3.3 Sleep cycle — resumable (`runCycle`)
State persisted in a new single-row `sleep_cycle` table (GRDB migration `v2-sleep`): `phase: String` (`nrem|rem|reflect|curate|shy`), `episodeIds: String` (JSON of the batch), `startedAt: Double`. `runCycle(isCancelled:)`:
1. Load active cycle, or start one: batch = current unconsolidated episode ids (`Meta.status != "consolidated"`); empty → no-op. Persist `{phase:nrem, batch}`.
2. For each remaining phase in order: `if isCancelled() { return }`; run the phase over the batch; **persist the advanced phase**; emit progress.
3. After SHY: mark batch episodes `consolidated`, `clearSleepCycle()`, emit summary.
Cancel mid-generation → interrupted phase didn't persist its advance → re-runs next cycle (idempotent). Curate runs every cycle but is cheap.

### 3.4 Awake reflection — light (`runLight`)
- **Scope:** the last turn's episode + the entities it touched (recent), NOT the whole batch.
- **Ops:** `associate(recentNodes)` + `reflect(recentMemories)` + structured-node creation from the recent turn (e.g. detect a task/plan in "tengo que llamar a Juan" → `task` pending). NO replay-all, NO curate, NO forget.
- **Triggers (both):**
  - *Agentic:* a `reflect` `AgentTool` (name `reflect`, no/short args) the model can call when it wants to note/connect something; its `run` enqueues a light reflection (returns immediately "ok").
  - *Automatic:* the scheduler's short-pause timer (~15s after a reply with no new activity) fires `runLight`.
- Cancellable + yields instantly on `noteUserActivity()`.

### 3.5 `Memory/ConsolidationScheduler.swift` (new, `@MainActor @Observable`)
- `state` (`.idle`, `.reflecting`(awake), `.sleeping(phase:progress:)`, `.completed(summary:)`, `.failed`).
- Two cancellable timers: short-pause (awake, ~15s) and idle (sleep, ~180s), both reset by `noteUserActivity()`. Both gated on `serverManager.state == .ready` and `memoryEnabled`.
- `noteUserActivity()` (called at `runAgentTurn` start) cancels any running consolidation Task (aborting the in-flight generation) + resets timers.
- `requestLightReflection()` (from the `reflect` tool) and `consolidateNow()` (manual button).
- Injectable clock/delays for tests.

### 3.6 Wiring + UI
- `HarnessModel` owns the scheduler (same runtime/store/embedder); `runAgentTurn` calls `noteUserActivity()` at start and resets timers at end; registers the `reflect` tool when memory is on.
- `AgentChatView`: "🌙 Consolidando — <phase> (+N conexiones, +M insights)" while sleeping; lighter "💭 reflexionando…" while awake-reflecting; "Consolidar ahora" button. `MemoryGraphView` legend gains colors for `insight`/`task`/`plan`/`trait` (and a generic color for unknown model-minted kinds).

## 4. Data flow
**Awake:** `turn ends → (a) model called reflect tool OR (b) ~15s pause → runLight over recent → associate + reflect + create task/plan/trait nodes → yields instantly if user returns`.
**Sleep:** `idle ~180s (server ready) → runCycle → [resume phase or snapshot unconsolidated batch] → NREM consolidate → REM associate → Reflect insights → Curate kinds → SHY forget → mark batch consolidated + clear cycle → summary`. User turn anytime → `noteUserActivity()` cancels → persisted phase stays → next idle resumes.

## 5. Error handling
- Malformed LLM JSON (any phase) → no-op that phase, advance; log.
- Cancel mid-generation → interrupted phase re-runs next time (idempotent: dedup / edge-exists / insight ≥2-source / kind-map are all re-appliable).
- Model mints a junk/duplicate kind → preserved short-term, folded/dropped by the next Curate phase.
- Server not ready / memory off → scheduler idle.
- DB error → log, abort cycle cleanly (resume later), never crash a turn.
- Empty batch / no recent content → no-op (no LLM calls).

## 6. Testing
- **`MemoryConsolidationEngine`** (fake `ModelRuntime` canned JSON per phase, in-memory store + `FakeEmbedder`):
  - consolidate → entities incl. a `task` (status in extra) + a model-minted **new kind** stored verbatim (not coerced to fact).
  - associate → edges created/deduped.
  - reflect → insight nodes + source edges; `<2`-source insight dropped.
  - **curate** → a synonym kind ("meta") folded to canonical ("plan"); nodes reassigned; junk dropped.
  - forget → weak node soft-deleted, identity exempt, dangling edges pruned.
  - **resumability:** cancel after NREM → resume skips NREM; full cycle marks episodes consolidated + clears state.
  - **idempotence:** full cycle twice → no duplicate nodes/edges/insights.
- **`ConsolidationScheduler`** (injected clock + fake engine): short-pause fires `runLight`; idle fires `runCycle`; `noteUserActivity()` cancels + resets both; `requestLightReflection()`/`consolidateNow()` run immediately; gated off when server not ready / memory off.
- **Structured kinds / extensibility:** `Node.kind` round-trips arbitrary strings through the store; `NodeAttributes` (status/horizon) round-trips via `extra` alongside episode `Meta`.
- **`reflect` tool:** calling it enqueues a light reflection (doesn't block; returns ok); no store → safe.
- **Regression:** all M2b-1 suites stay green after the `kind: String` refactor.
- **Manual (macOS, real 26B):** multi-turn convo with a task ("recuérdame llamar a Juan") + a plan + preferences → "Consolidar ahora" → watch phases; graph shows `task`/`plan`/`insight` nodes + associative edges; mint a quirky kind and confirm Curate folds it; interrupt mid-cycle → resumes. Record results.

## 7. Out of scope (M2b-3 / later)
- **Resuming interrupted *conversations*** (open-thread detection + proactive follow-up on wake) — **M2b-3**.
- Surfacing tasks/plans proactively to the user (reminders/notifications) — later (ties to S6 tools).
- Multiple sleep cycles per idle / deep-vs-light sleep tuning; cross-device sync; server embeddings (S5b/c).

## 8. Implementation sequencing (the plan builds in this order)
1. **Taxonomy foundation:** `kind: String` refactor + new kind constants + `NodeAttributes` (status/horizon in `extra`) + keep M2b-1 suites green.
2. **`MemoryConsolidationEngine`** phase ops (consolidate/associate/reflect/curate/forget) — TDD with fake runtime.
3. **Sleep cycle** (`runCycle` + `sleep_cycle` migration + resumability).
4. **`ConsolidationScheduler`** (awake + sleep timers, cancel-on-activity) + `reflect` tool.
5. **Wiring + UI** (HarnessModel, AgentChatView banner + button, graph legend) + manual E2E.

## 9. File structure
**New:** `Memory/MemoryConsolidationEngine.swift` (+ `SleepPhase`/`SleepCycleState`), `Memory/ConsolidationScheduler.swift`, `Memory/ReflectTool.swift`, `Memory/NodeAttributes.swift`; tests `GemmaTests/MemoryConsolidationEngineTests.swift`, `ConsolidationSchedulerTests.swift`, `NodeKindStringTests.swift`, `NodeAttributesTests.swift`, `ReflectToolTests.swift`.
**Modified:** `Memory/MemoryModels.swift` (`kind: String`; `NodeKind` constants + task/plan/trait), `Memory/MemoryStore.swift` (`v2-sleep` migration, kind as String in queries, `loadSleepCycle`/`saveSleepCycle`/`clearSleepCycle`, edge-prune, unconsolidated/markConsolidated episode helpers), `Memory/MemoryStore+Dedup.swift` (kind String), `Memory/SaveMemoryTool.swift` (kind String), `Memory/EpisodeRecorder.swift` (extra JSON coexist with NodeAttributes), `Memory/MemoryRetriever.swift` (kind String), `Harness/HarnessModel.swift` (own scheduler, noteUserActivity, register reflect tool), `Harness/AgentChatView.swift` (banner + button), `Harness/MemoryGraphView.swift` (kind colors incl. unknown), `Agent/Agent.swift` (system prompt: mention reflect + structured kinds).

## 10. Resultado M2b-2 (VERIFICADO contra el 26B real, 2026-05-31)

Plan `…m2b-2-sleep-consolidation.md` ejecutado completo (subagent-driven, doble review spec+calidad por unidad; varios fixes en review). Commits `5424072`…`cc14fbc` en `main`.

- **Taxonomía extensible:** `Node.kind` ahora String libre + vocabulario `NodeKind` (+`trait`/`task`/`plan`/`insight`); el modelo puede acuñar kinds nuevos (verbatim). `NodeAttributes` (status/horizon en `extra`).
- **`MemoryConsolidationEngine`** (5 fases) + `runCycle` resumible (estado `sleep_cycle` persistido; retoma por fase) + `runLight` (reflexión despierta). `ConsolidationScheduler` (timers ocio ~180s / pausa ~15s, cede al usuario al instante, botón manual) + `reflect` tool agentic.
- **Fixes en review:** dedup de insights (no acumula en re-run); la reflexión agentic corre post-turno (no se cancela al cerrar el turno); colores distintos para task/plan/trait/insight en el grafo.
- **E2E real (`SleepConsolidationE2ETests`, gated):** sembrada una conversación (nombre, gustos, amigo, una tarea, un plan) → `runCycle` contra el 26B produjo:
  - **NREM:** 7 nodos estructurados — `person` Roilan, `preference` sushi/fútbol, `place` panadería, **`task` "llamar al dentista" {status:pending}**, **`plan` "aprender alemán" {horizon:short}**.
  - **REM:** 5 edges asociativos (Roilan→likes→sushi/fútbol, →locatedAt→panadería, →relatedTo→tarea/plan).
  - **Reflect:** 1 insight fundado "has interests in sports and food" (2 fuentes) + sus edges.
  - **Curate:** sin kinds no-estándar que folddear; episodios marcados consolidados; ciclo cerrado.
- **Hallazgo del E2E (corregido):** la 1ª corrida dio 0 edges/0 insights — los prompts de associate/reflect eran demasiado conservadores sin contexto. Fix: dar contexto "todo es sobre un usuario" + ejemplo (`cc14fbc`); re-corrida → 5 edges + 1 insight. (Lección: los prompts de consolidación necesitan contexto de usuario + few-shot.)
- **Pendiente (humano):** check visual GUI (`⌘R`): banner "🌙 consolidando" por fase, botón "Consolidar", grafo con task/plan/insight coloreados + edges; probar reflexión agentic + resume mid-ciclo.
- **Siguiente:** M2b-3 = retomar conversaciones interrumpidas (detección de hilos abiertos + follow-up proactivo al despertar).
