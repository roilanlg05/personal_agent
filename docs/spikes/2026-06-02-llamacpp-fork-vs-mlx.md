# Spike: llama.cpp fork (atomic-turboquant) vs MLX — Gemma-4-26B-A4B + MTP

**Date:** 2026-06-02  **Machine:** M4, 24GB unified, Metal cap ~19GB
**Goal:** Fair llama.cpp comparison at Q4 (user's constraint: Q4 or Q6, not lower) for the real problem = **TTFT / cold start**.

## Setup
- Fork: `AtomicBot-ai/atomic-llama-cpp-turboquant` (stock llama.cpp can't load gemma4 GGUF: `expected 1014 tensors, got 658`). Built `llama-server` (cmake 4.3.3).
- Target: `unsloth/gemma-4-26B-A4B-it-GGUF` → `gemma-4-26B-A4B-it-UD-Q4_K_M.gguf` (16 GB).
- Draft (MTP head): `AtomicChat/gemma-4-26B-A4B-it-assistant-GGUF` → `...assistant.Q4_K_M.gguf` (310 MB).
- Run: `llama-server -m TGT --mtp-head DRF --spec-type mtp --draft-block-size 3 --draft-max 8 --draft-min 0 -ngl 99 -ngld 99 -ctk turbo3 -ctv turbo3 -ctkd turbo3 -ctvd turbo3 -fa on -c 4096`
- Load OK, MTP assistant loaded into target. ~38s load.
- **Caveat:** measured under heavy memory pressure (free ~0.06GB, user apps + browser resident). Decode numbers are a floor, not a ceiling.

## Results (server-side timings = ground truth)

| Metric | llama.cpp fork (Q4_K_M + MTP, turbo3 KV) | MLX baseline (mlx_vlm, 4-bit + MTP) |
|---|---|---|
| Prefill speed | **159 t/s** (569-tok prompt → 3.58s) | ~comparable |
| **Cold TTFT** (569-tok app prompt) | **~3.6s** (prefill) | ~5s |
| **Warm TTFT w/ prompt cache** | **~0.15s** (cache hit: only 5 new tokens reprocessed, 143ms) | ~0.26s |
| Decode (MTP) | **~20–27 t/s** | **~29 t/s** |
| MTP draft acceptance | **72–95%** | (MTP) |
| Memory footprint | ~16.5 GB (16 weights + 0.31 draft + ~0.17 KV) | ~15 GB |

## Key finding
**`cache_prompt` collapses cold prefill 3.58s → 0.14s** when the prompt prefix is unchanged.
This is the decisive result for the user's actual problem (cold-start TTFT). The win is **prompt-prefix caching**, NOT the backend — `mlx_lm.server` has the same prompt-cache capability.

## Conclusion / recommendation
- llama.cpp fork does **not** beat MLX on this Mac for this model: decode slightly slower (20–27 vs 29 t/s), memory slightly higher (16.5 vs 15 GB).
- llama.cpp advantages are non-speed: GBNF grammars, KV-quant flavors, larger GGUF/model + MTP-pair ecosystem, finer cache-management API.
- **Switching cost is high** (rewrite ServerRuntime/process mgmt, re-validate MTP) for no speed/memory gain → **stay on MLX.**
- **The TTFT fix is the same on both backends:** stable system-prompt prefix + `mlx_lm.server` prompt-cache + keep-warm → cold ~3.6–5s → ~0.15–0.3s warm. Implement on MLX.
- Keep the fork build as a documented fallback if we ever need GBNF grammars or a GGUF-only model.

## llama.cpp 100%-optimized on Mac (clean re-bench, 2026-06-02)

Full Metal (`-ngl 99 -ngld 99`), MTP, turbo3 KV, flash-attn, jinja, `-c 16384/4096`, cache_prompt. Ground truth = server `eval` t/s.

**Decode is MTP-draft-acceptance-bound (prompt-dependent), not a config issue:**

| Prompt regime | draft acceptance | llama.cpp decode | MLX decode (matched) |
|---|---|---|---|
| short/factual | ~90% | **24–27 t/s** | **~29 t/s** |
| long/creative (220 tok) | 57–76% | **17–19 t/s** | **~21 t/s** |

**Ruled out as causes of the slowdown:**
- turbo3 sparse-V (`TURBO_SPARSE_V=0` → identical ~17–19 t/s long).
- context size (`-c 4096` vs `16384` → no meaningful diff for short seqs).
- draft quant: **Q8_0 draft is WORSE** (11.8–15 t/s, same 60–76% acceptance) — bigger draft costs more compute per round without raising acceptance. **Q4_K_M draft is optimal.**
- memory: top hog is llama-server itself (~10.4GB RSS + GPU buffers); other apps ~1GB total. Pressure is the 16GB model on 24GB, not background apps.

**Verdict:** MLX is ~10–20% faster on matched prompts and wins at every regime (best-case 29 vs 27, typical-creative 21 vs 18). No llama.cpp config recovers the gap — Apple's MLX Metal kernels beat llama.cpp's Metal backend on this M4. The "~27 t/s" seen earlier was a high-acceptance short run, reproducible but not the sustained creative-decode rate.

**Only reason to choose llama.cpp on the Mac:** GGUF-only models (e.g. the `Gemma4-26B-A4B-Uncensored-HauhauCS-Balanced` variant). For those, best path = convert to MLX 4-bit to keep MLX speed + the existing MTP draft.

## RESOLUTION — cold-start fix shipped (2026-06-02)

The real cold-start cost is **Metal-kernel JIT on the first real generation (~31s)**, not prefill and not backend. Evidence (MLX, MTP, fresh server): 1st request 31.1s, 2nd 0.84s. The app's startup warm-up was a 1-token, system-less ping that only compiled a subset of kernels.

**Fix (branch `feat/mlx-ttft-apc`):** `HTTPServerHealth.warm()` now sends a *representative* warm-up — system message + `max_tokens:16` — so the multi-token + MTP decode kernels JIT at startup (behind the app's existing "warming" state). Measured: user's first real message **31s → 0.83s**, full MTP decode (~29 t/s) retained.

**APC was reverted** (incompatible with MTP — Metal GPU timeout; disk tier slower than recompute for small prefixes). The stable-system-prefix change (recall→user-tail) was kept as good hygiene. Net result: cold-start fixed, MLX + MTP retained, no backend switch.

## MLX tuning (2026-06-02): draft-block-size 3→2, prompt-caching matrix

**draft-block-size sweep (clean A/B, best-of-2):** bs=2 wins every regime — factual 26.2 vs 23.1 t/s (+13%), creative 18.7 vs 16.3 (+15%). Smaller block = lower acceptance/round but cheaper rounds → higher throughput at moderate acceptance. Monotonic 2>3>4>5>6 across the full 2–6 sweep. **Default changed to `draftBlockSize: 2`.**

**Prompt caching matrix (mlx_vlm APC):**
| Config | Decode | Cross-turn prompt cache |
|---|---|---|
| MTP, no APC (shipped) | ~26–29 t/s | none |
| APC, no MTP | ~24 t/s | yes (warm TTFT ~0.3s) |
| APC + MTP | ~29 t/s | **inert** (`stores=0`; MTP path bypasses APC) |

APC + MTP does NOT crash in-memory (the earlier crash was the disk-restore path) but APC is **inert** with MTP. So prompt-caching and MTP are mutually exclusive in mlx_vlm. Not worth dropping MTP for it (cold-start already fixed by the representative warm-up; warm TTFT with MTP is ~0.83s).

**batch size:** no single-user lever — `--prefill-step-size` only affects prompts >2048 tokens (ours ~200 = 1 prefill step); internal completion/prefill batch is for concurrent multi-user requests. Decode is autoregressive batch-1; its only "batch" is the MTP draft block (swept above).
