# S1 — Reporte del runtime (resultados medidos)

> **Padre:** `01-s1-runtime.md` (spec de trabajo). Este documento registra los números medidos en hardware y la decisión justificada.
> **Fecha:** 2026-05-28. **Dispositivo:** iPhone 16 (iPhone17,3, 8 GB, ~7.5 GB usables), físico. **Runtime:** LiteRT-LM (SPM ≥ 0.12). **Modelo:** Gemma 4 **E4B** int4 (`gemma-4-E4B-it.litertlm`), GPU/Metal.

---

## 1. Resumen ejecutivo

- **El runtime LiteRT-LM corre Gemma 4 E4B en GPU/Metal en el iPhone 16**, con generación de texto estable (medido también vía la app: ~10.5 tok/s decode, TTFT ~0.65 s, RSS ~0.8 GB en uso real de chat).
- **Decisión MTP (speculative decoding): NO usarlo por defecto.** En el benchmark medido, activar MTP **degradó** el decode (×0.58) y empeoró el TTFT. Es el resultado opuesto al ~2.2× que reporta Google; ver §3–§4 para la causa probable y el caveat.
- Las demás comparaciones que el spec S1 contemplaba (llama.cpp vs LiteRT-LM, modelo oficial vs uncensored GGUF, mmap vs carga completa, medición energética) **no se ejecutaron** — esos componentes no existen aún y quedan para **Plan 4**.

---

## 2. Comparación MTP off vs on

Benchmark vía la API oficial `LiteRTLM.benchmark()` (engine dedicado por corrida, `cacheDir = ":nocache"` → build en frío). Backend GPU, `prefillTokens = 256`, `decodeTokens = 256`, **promedio de 5 corridas** por configuración (10 corridas en total). MTP se conmuta con `ExperimentalFlags.enableSpeculativeDecoding` antes de crear cada engine.

| Métrica | MTP off | MTP on |
|---|---:|---:|
| Prefill tok/s | **51.6** | 28.3 |
| Decode tok/s | **12.2** | 7.1 |
| TTFT (s) | **5.17** | 9.21 |
| First init (s) | 13.25 | **11.68** |
| **Decode speedup (on/off)** | | **×0.58** |
| Prefill speedup (on/off) | | ×0.55 |

(El `First init` aquí incluye compilación de shaders en frío por `:nocache`; en uso real de la app, con cache, el init es de segundos. No es la métrica de decisión.)

---

## 3. Análisis

- **MTP sí se activó.** Las columnas off y on son claramente distintas (no idénticas), lo que descarta el riesgo de que el flag global no conmutara entre corridas (riesgo R1 del plan). Cada `benchmark()` crea un engine fresco que re-lee `enableSpeculativeDecoding`.
- **Con MTP on, decode y prefill bajan (~0.55–0.58×) y el TTFT casi se duplica.** En este escenario MTP añade el costo del drafter (pasada extra de predicción + verificación) sin recuperarlo en aceptación.
- **Causa más probable: el benchmark usa tokens sintéticos, no contenido real.** El speedup de MTP depende de la **tasa de aceptación** de los tokens propuestos por el drafter, que a su vez depende de qué tan predecible es el texto. Con la entrada sintética de `benchmark()` la aceptación es baja → el drafter trabaja de más y el neto es más lento. El 2.2× que Google cita es sobre decode de contenido real en GPU móvil.
- **Conclusión honesta:** este benchmark **no** mide el caso donde MTP ayuda. Mide overhead de MTP con aceptación pobre. Sirve para decidir el **default**, no para refutar el beneficio de MTP en generación real.

---

## 4. Decisión

- **MTP = OFF por defecto** en `GenerationSettings`/`ModelLoadOptions` (ya es el default actual). En este dispositivo, con este benchmark, MTP no aporta y sí cuesta.
- **Re-evaluar MTP con decode de contenido real** (no sintético) y midiendo **tasa de aceptación del drafter** antes de habilitarlo como recomendación general. Si en contenido real el decode sube claramente (p. ej. ≥ ~1.2×), reconsiderar el default. La Settings UI ya expone el toggle MTP, así que el usuario puede activarlo y comparar en chat real.

---

## 5. Caveats

- Solo **GPU/Metal**, modelo **E4B**, **iPhone 16 físico** (simulador excluido — ahí LiteRT-LM corre en CPU y además tiene un crash de deinit propio del simulador iOS 26.2).
- `:nocache` ⇒ cada corrida recompila shaders (init en frío); por eso `First init` es alto y no comparable al init de la app en uso normal.
- Entrada **sintética** de prefill/decode (no prompts reales) — clave para interpretar el resultado de MTP (§3).
- Requiere la entitlement `com.apple.developer.kernel.increased-memory-limit` para cargar el E4B en GPU; `extended-virtual-addressing` no está disponible en cuentas de desarrollador personales.

---

## 6. Pendiente (Plan 4 / futuro)

- Runtime **llama.cpp** + modelo **uncensored GGUF**; comparación de runtimes y variantes de modelo.
- **mmap vs carga completa** sobre el combo ganador.
- **Medición energética** (Instruments Energy Log).
- Matrices CPU-vs-GPU y E2B-vs-E4B; eval de **decode real** con tasa de aceptación para cerrar la pregunta MTP.
