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
