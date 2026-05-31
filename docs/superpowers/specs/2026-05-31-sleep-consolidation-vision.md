# Sleep Consolidation — Memory Vision & Spec-Writing Guide

> **What this is:** the north-star + guide for writing the per-phase specs of Gemma's "Sleep Consolidation" memory system. Written 2026-05-31 with fresh research (cited below). Each phase still gets its own brainstorm→spec→plan→subagent-driven build; this doc captures the whole vision, the research grounding, the locked decisions, and what each phase should spec — so the future specs are consistent.
> **Parent:** S5a `2026-05-29-s5a-memoria-ondevice-design.md`, capture-v2 `2026-05-30-s5a-v2-capture-redesign-design.md` (superseded/absorbed here), macOS pivot `[[macos-mlx-pivot]]`. Platform: macOS app + local `mlx-lm` Gemma 4 26B, GRDB graph memory.

## 1. Vision

A **human-like, nested-learning-inspired** memory. Two complementary processes:
- **Awake (in-turn):** immediate capture — the model calls `save_memory` for facts the user states; relevance-scoped recall injects only what's pertinent.
- **Asleep (idle):** a slow **consolidation pass** that *replays the recent conversation*, forms **associative connections** (graph edges), abstracts higher-level insights, **promotes** reinforced memories across timescales, **forgets** the weak, and flags **interrupted/open threads** to resume on wake.

This mirrors the brain's Complementary Learning Systems (fast hippocampal episodic store → slow neocortical semantic store via sleep replay) and the Nested Learning view that intelligence is memory updated at *multiple timescales*.

## 2. Research grounding (cited)

**Nested Learning** (Behrouz, Razaviyayn, Zhong, Mirrokni — Google, NeurIPS 2025; arXiv:2512.24695; [blog](https://research.google/blog/introducing-nested-learning-a-new-ml-paradigm-for-continual-learning/)). A model+optimizer = nested optimization problems, each a *associative memory* compressing its context flow at its own **update frequency** ("Continuum Memory System": spectrum fast→slow). The literal mechanisms (deep optimizers, self-modifying "Hope" weights) are *training-time*. **Transferable patterns:** tiered multi-timescale stores; associative key-value retrieval with a **surprise** write-gate; **periodic consolidation that compresses recent experience into slower stores**; robust (L2-style) merge over naive overwrite.

**Optimizer-as-memory / Adam** (Kingma & Ba arXiv:1412.6980; Titans, Behrouz et al. arXiv:2501.00663). Adam's moments are EMAs of gradient history: `m←β₁m+(1−β₁)g`, `v←β₂v+(1−β₂)g²`; **timescale ≈ 1/(1−β)**. Titans makes "optimizer = associative memory" literal: gradient magnitude = **surprise** (store it), momentum+weight-decay = retention/forgetting gates. **Our analogy (no gradients):** `salience ← β·salience + (1−β)·signal` per node; **β per layer = timescale** (live β≈0.5 ≈ horizon 2; daily β≈0.9 ≈ 10; identity β≈0.99 ≈ 100); promote when salience crosses a threshold; decay = forgetting.

**Sleep consolidation** (CLS: McClelland et al. 1995; Klinzing/Niethard/Born Nat Neurosci 2019; SHY: Tononi & Cirelli 2006; Generative Agents: Park et al. arXiv:2304.03442; MemGPT/Letta; A-MEM: Xu et al. arXiv:2502.12110). Hippocampus learns episodes fast; **replay** during sleep transfers them to cortex, abstracting episodic→semantic; **synaptic homeostasis** downscales/forgets weak synapses, sparing reinforced ones. Agent analogues: Generative Agents **reflection** (periodic synthesis of higher-level insights), MemGPT tiers + self-edit, A-MEM autonomous **edge-building + note evolution**. **Prioritized sleep-pass ops:** replay+extract → dedup/merge → associative edges → abstraction/reflection → promotion → decay/forget → open-thread detection.

## 3. Concept → our system

| Research concept | Our implementation |
|---|---|
| Hippocampal fast episodic store | `episode`/`conversation` nodes (NEW: persist chat turns) — the "episodic layer" |
| Neocortical slow semantic store | `daily` + `identity` layer nodes (entities/facts) |
| Multi-timescale (CMS / β per level) | per-layer salience EMA β (live/daily/identity) + `Decay` |
| Surprise write-gate | only store novel/affirmed facts; boost on re-mention |
| Replay during sleep | idle consolidation reads recent `episode` nodes via the 26B |
| Associative memory | `Edge` graph + spreading-activation retrieval (already exists) |
| Reflection/abstraction | LLM-synthesized summary nodes linked to sources |
| Episodic→semantic transfer + promotion | daily→identity promotion by reinforced salience |
| Synaptic homeostasis (forget) | `Decay`/`sweep` downscaling weak nodes/edges |
| Open-thread resume | episode status (open/interrupted) → proactive follow-up on wake |

Reuse (do NOT rebuild): `MemoryStore` + Node/Edge schema + layers, `Decay`, `MemoryRetriever` (spreading activation), `Embedder` (`NLContextualEmbedder`), `MemoryText`, `MemoryToolbox`, the `AgentTool` loop, generation serialization (RC3).

## 4. Locked decisions (apply across phases)

- **In-turn capture = one synchronous `save_memory` `AgentTool`** (kind/entity/detail/permanent) — clean→embed→**semantic dedup**→upsert, returns "saved". NOT a deferred queue (writes are ms on macOS). Replaces `RememberTool`.
- **Drop the per-turn `MemoryConsolidator`** (noisy double-capture for the E4B). Passive capture moves to the *sleep pass* instead (replay), where it's slower + smarter.
- **`forget_memory`** tool for contradiction/correction (keep `ForgetTool`, sharpen description).
- **Chat persisted as episode nodes** from M2b-1 (substrate for replay + resume). "Meter el chat en la sopa."
- **EMA salience, per-layer β** (Adam analogy); reinforce on mention, decay otherwise.
- **Relevance-scoped injection:** identity-core (small) + query-relevant only — recalibrates RC6 over-injection.
- **Sleep pass = idle-triggered** (after N min no activity), background, serialized vs the engine turn (RC3), only when the server is warm.
- **macOS / 26B / `AgentTool`** (not LiteRT). The 26B tool-calls reliably (verified M1 E2E), so several iOS patches (RC1 heavy label-cleaning, RC5) are insurance, not load-bearing.

## 5. Phases (each: brainstorm→spec→plan→subagent-driven build)

### M2b-1 — Foundations (substrate + immediate quality)
**Delivers:** the awake path done right + the substrate sleep needs. **Spec should cover:**
- **Episodic capture:** persist each turn (user + assistant) as `conversation`/`episode` nodes in an episodic layer, with timestamps + a thread/session id + a status (open/closed). Decide retention.
- **`SaveMemoryTool`** (synchronous, structured entity/detail, semantic dedup via embedding `nearest` within a threshold else insert). Replace `RememberTool`. Keep `forget_memory`.
- **Remove `MemoryConsolidator`** + its tests; `MemoryServices` drops `consolidator`.
- **EMA salience + per-layer β** (extend/refactor `Decay`): reinforce on re-mention, decay otherwise; expose β per layer.
- **Relevance-scoped injection:** `coreMemories()` → identity-only; retrieval block = identity-core + query-relevant (vector+FTS+graph). System prompt: answer only what was asked.
- Tests: tool enqueue/dedup, episodic persistence, EMA math (pure), retrieval relevance, regression (RC3).

### M2b-2 — The Sleep Consolidation pass (centerpiece)
**Delivers:** the idle "sleep" job. **Spec should cover:**
- **Trigger:** idle detector (N min no user activity) while server warm; manual "consolidate now" for testing; serialize vs turns (RC3); cancel if the user returns.
- **Pass pipeline** over recent `episode` nodes (replay): (1) extract/confirm entities & facts via the 26B, (2) semantic dedup/merge, (3) **associative edge-building** between related nodes, (4) **promotion** daily→identity by reinforced EMA salience, (5) **decay/forget** weak nodes/edges (after extraction). Each step a testable unit; the LLM steps behind a protocol seam (fake in tests).
- Status surfacing (a "🌙 consolidando…" indicator), inspector shows new edges.
- Tests: pipeline stages with a fake runtime + in-memory store; idempotence; no-op when no new episodes.

### M2b-3 — Reflection + resume interrupted threads
**Delivers:** higher-order cognition + proactivity. **Spec should cover:**
- **Reflection/abstraction:** cluster related nodes/episodes; the 26B synthesizes higher-level insight/summary nodes linked to their sources (Generative-Agents reflection); promote to identity if salient.
- **Open-thread detection + resume:** during sleep, flag episodes with unresolved intents/questions/interruptions; on next wake, the agent proactively surfaces/continues them ("la otra vez mencionaste X… ¿seguimos?").
- Tests: reflection produces linked summary nodes; open-thread detection flags the right episodes; wake-time resume injects the follow-up.

## 6. How to write each phase spec
- Follow the project workflow: `superpowers:brainstorming` → spec in `docs/superpowers/specs/YYYY-MM-DD-m2b-N-*.md` → `superpowers:writing-plans` → `superpowers:subagent-driven-development`.
- Ground each spec in §2–§4 here; reuse the components in §3; honor the locked decisions in §4.
- Keep LLM-dependent steps behind injected protocol seams so logic is unit-testable without the real server (pattern proven in M2a `ServerManager`).
- Build/test on macOS (`xcodebuild ... -destination 'platform=macOS'`). New `.swift` files auto-add to the target.

## 7. Out of scope / future
- True model-level nested learning (training deep optimizers / self-modifying weights) — we borrow the *patterns*, we do not train the model.
- Server-side premium embeddings + Qdrant + graphify (S5b); device↔server sync (S5c).
- Fine importance scoring (#22), old-day compression (#9), emotional/narrative memory (S11) beyond what reflection covers.
