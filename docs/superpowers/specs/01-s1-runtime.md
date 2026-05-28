# S1 — Runtime del modelo on-device

> **Spec de trabajo.** Define qué se hace en S1, cómo se mide y qué entrega. La ejecución del bench y la decisión final se documentan después en `01-s1-runtime-report.md`.
>
> **Padre:** `00-roadmap.md`. **Fase:** 0 (Fundación). **Posición en la fase:** primero del slice vertical.

---

## 1. Objetivo

Elegir, basado en datos medidos en iPhone 16 físico:
1. **Runtime de inferencia:** LiteRT-LM o llama.cpp.
2. **Variante de modelo:** oficial (`litert-community/gemma-4-E4B-it-litert-lm`) o uncensored (`llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic` GGUF).
3. **Uso de decoding especulativo (MTP drafter):** sí / no.
4. **Modo de carga del modelo:** memory-mapped (mmap) o carga completa.

Y entregar un **harness SwiftUI mínimo** que cargue el ganador y exponga una capa `ModelRuntime` reusable por specs siguientes (S2 voz, S4 agente).

## 2. Alcance

**Dentro:**
- Bench de inferencia en iPhone 16 base ↑ (dispositivo físico, no simulador).
- Modalidades: **texto + imagen** (multimodal completo se posterga; audio/video van en S9/S10).
- Comparación de 3 combos runtime+modelo+drafter (§5).
- Sub-evaluación **mmap vs carga completa** sobre el combo ganador.
- Medición energética: simple (% batería + temperatura) para iterar; **Xcode Instruments Energy Log** para validar al ganador.
- Reporte tabulado + decisión justificada.
- App SwiftUI mínima con protocolo `ModelRuntime` y dos implementaciones.

**Fuera:**
- Tool-calling (S4).
- Pipeline de voz, wake word, TTS, STT (S2).
- Máquina de estados de conversación (S3).
- Memoria persistente / RAG (S5).
- Audio, video como modalidades del bench (S10, futuro).
- Criterios duros de pasa/no pasa absolutos — S1 reporta y compara; los thresholds aparecen en specs siguientes según los números reales.
- Soporte para iPhone < 16 base.
- Cualquier dependencia de cloud.

## 3. Decisiones heredadas (del roadmap, no se discuten en S1)

| Tema | Decisión |
|---|---|
| Target | iPhone 16 base ↑ (8 GB RAM) |
| Familia de modelo | Gemma 4 E4B (multimodal texto/imagen/audio/video nativo) |
| Idioma | Bilingüe ES/EN |
| Cloud | Ninguno en S1 |
| Slice de fase 0 | S1 → S4 → S2 → S3, S5 al final |

## 4. Decisiones tomadas en el brainstorming de S1

| Decisión | Valor |
|---|---|
| Alcance multimodal del bench | **Texto + imagen** |
| Entregable | **Bench report + harness Swift mínimo** |
| Criterios pasa/no-pasa | **No hay umbrales duros**; S1 reporta y elige |
| Draft model | **MTP drafter oficial de Google para E4B** (Multi-Token Prediction, Apache 2.0, publicado 5 mayo 2026; usado por Google AI Edge Gallery; hasta 3× speedup) |
| Estrategia de bench | **3 combos clave** (§5) |
| Medición energía | **Simple para iterar + Instruments para final** |
| Modo de carga | **Evaluar mmap vs no-mmap** en el ganador (§7) |

## 5. Plan de bench — 3 combos clave

| # | Runtime | Modelo (target) | Drafter |
|---|---|---|---|
| **a** | LiteRT-LM | `litert-community/gemma-4-E4B-it-litert-lm` (oficial) | MTP drafter oficial de Google para E4B |
| **b** | llama.cpp | `llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic` (GGUF, uncensored) | MTP drafter oficial *(validar carga en llama.cpp; medir acceptance rate caído por el fine-tune)* |
| **c** | llama.cpp | mismo uncensored GGUF | **Sin drafter** (baseline para aislar el efecto del MTP) |

**Combo "stretch" (solo si a/b/c se ejecutan rápido y queda tiempo):**

| # | Runtime | Modelo | Drafter |
|---|---|---|---|
| d | llama.cpp | `HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive` (GGUF) | MTP drafter oficial |

**Por qué estos 3:**
- (a) es el camino de menor resistencia, máximo speedup MTP, modelo oficial → "ideal teórico".
- (b) responde "¿cuánto pierdo del MTP al meter un uncensored?".
- (c) responde "¿vale la pena el drafter o me quedo con uncensored puro?".

## 6. Métricas por combo

| Métrica | Detalle |
|---|---|
| **Tokens/s (steady state)** | Texto-solo (prompt corto y largo) y texto+imagen. Promedio sobre N=5 corridas tras descarte de warmup. |
| **TTFT** | Tiempo desde envío de prompt hasta el primer token mostrado. Crítico para barge-in (S2). Prompts cortos (1-50 tokens) y largos (500-1000 tokens). |
| **RAM peak** | Pico de Resident Set Size durante carga + 5 min de inferencia mixta. |
| **Tamaño en disco** | Bytes del archivo de modelo en Documents. |
| **Calidad (manual)** | Set fijo de **~20 prompts bilingües** (factuales ES/EN, conversacionales ES/EN, una pregunta sobre imagen). Evaluación humana rápida (1-5). NO es eval académico — es comparativo entre combos. |
| **Acceptance rate del drafter** (combos a y b) | % de tokens propuestos por el drafter aceptados por el target. |
| **Energía — iteración** | % batería antes/después de **10 min de inferencia sostenida** + temperatura máxima del dispositivo. |
| **Energía — final (ganador)** | Xcode Instruments **Energy Log**: impacto energético (mW), uso CPU/GPU/Neural Engine. |
| **Modelo (cargado en frío vs caliente)** | TTFT con cold launch vs warm launch (mide impacto de mmap). |

### Set de prompts (definir en el harness, fijo durante todo S1)

A redactarse al inicio de S1 e inmutable a lo largo del bench. Aproximadamente:
- 8 prompts factuales (4 ES, 4 EN): conocimiento general corto.
- 6 prompts conversacionales (3 ES, 3 EN): turno único de 1-2 frases.
- 4 prompts largos (2 ES, 2 EN): 500-1000 tokens de contexto + pregunta al final.
- 2 prompts de imagen: una foto bilingüe ("¿qué es esto?" / "what's in the image?").

## 7. Sub-evaluación: mmap vs carga completa

Solo sobre el combo **ganador** de §5. Mide:

| Variable | mmap on | mmap off (carga completa) |
|---|---|---|
| RAM al terminar de "cargar" | esperado ~bajo | esperado ~tamaño completo |
| RAM steady state (5 min uso) | medir | medir |
| TTFT cold launch | esperado más alto | esperado bajo |
| TTFT warm launch | esperado bajo | esperado bajo |
| Comportamiento bajo presión (multitarea con otra app pesada en foreground antes de volver a Gemma) | observar evictions y reloads | observar OOM kill |

**Notas técnicas:**
- llama.cpp: `--mmap` (default) / `--no-mmap`. `--mlock` se ignora típicamente en iOS sin entitlements especiales.
- LiteRT-LM: configuración via `EngineSettings` (verificar nombre exacto en la versión vigente al ejecutar S1).

## 8. Entregable — código

Ubicación: el proyecto Xcode existente `Gemma/` se extiende con:

```
Gemma/Gemma/
├── GemmaApp.swift                 (existente)
├── ContentView.swift              (se reemplaza por la pantalla del harness)
├── Runtime/
│   ├── ModelRuntime.swift         (protocolo: load, generate, stream, metrics)
│   ├── LiteRTLMRuntime.swift      (implementación a)
│   └── LlamaCppRuntime.swift      (implementación b/c)
├── Bench/
│   ├── BenchRunner.swift          (orquesta corridas, agrega métricas)
│   ├── PromptSet.swift            (set fijo de prompts §6)
│   └── BenchReport.swift          (serializa resultados a JSON)
└── Harness/
    ├── HarnessView.swift          (UI: prompt box, streaming, RAM, tok/s)
    └── ImagePickerView.swift      (adjuntar imagen)
```

**Protocolo `ModelRuntime` (forma mínima — detalles los fija el bench):**
- `load(modelPath:, drafterPath:?, options:) async throws`
- `generate(prompt:, image:?, onToken: (String) -> Void) async throws -> GenerationResult`
- `unload()`
- `currentMetrics() -> RuntimeMetrics` (tok/s, RAM, etc.)

El modelo se carga desde **Documents** (no embebido en el bundle del app) para no inflar el binario y poder swap entre variantes sin reinstalar.

## 9. Entregable — reporte

Archivo: `docs/superpowers/specs/01-s1-runtime-report.md`. Contenido obligatorio:

1. Hardware exacto del bench (modelo iPhone, iOS, fecha).
2. Tabla comparativa con todas las métricas de §6 por combo.
3. Sub-evaluación mmap vs no-mmap.
4. Notas sobre comportamiento térmico y energético.
5. Tokenizer y compatibilidad del drafter con cada target (especialmente en combo b).
6. **Decisión final** justificada en prosa: runtime, modelo, drafter sí/no, mmap sí/no.
7. Riesgos descubiertos que afecten specs siguientes (S2/S4/S9).
8. Apéndice: outputs de muestra de cada combo sobre el set de prompts (para revisión cualitativa).

## 10. Riesgos / preguntas abiertas dentro del spec

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | Soporte del MTP drafter en llama.cpp móvil no está confirmado por la lista de runtimes publicada por Google. | Verificar repo de llama.cpp / abrir issue al iniciar S1. Si no carga, combo (b) corre sin drafter y combo (c) sigue siendo válido. |
| R2 | Multimodal de imagen en llama.cpp iOS para Gemma 4 E4B puede requerir build con flags o un fork específico. | Validar en setup del proyecto Swift, antes de medir. Si no hay path razonable, marcar (b)/(c) como "solo texto" en imagen y reportar limitación. |
| R3 | Tokenizer del drafter ≠ tokenizer del fine-tune uncensored → drafter inutilizable. | Verificar hashes/configs del tokenizer en setup. Si mismatch, combo (b) cae a sin-drafter (= combo c). |
| R4 | Cuantización óptima para uncensored (Q4_K_M vs Q5_K_M vs Q6_K) afecta RAM y calidad. | Pre-screening rápido con 1-2 prompts ANTES del bench formal; elegir 1 cuantización ganadora para el bench oficial. |
| R5 | Modelo cargado desde Documents requiere flujo de descarga (no cabe en bundle). | Para S1: descarga manual del usuario o helper script. Flujo automático es out-of-scope. |
| R6 | iOS puede matar la app si el modelo no cabe en RAM (combo sin mmap). | Esperado; documentar como hallazgo, no como falla. |
| R7 | El MTP drafter oficial podría no estar publicado aún para todas las variantes E4B al iniciar S1. | Verificar HF/Kaggle al iniciar; si falta, combo (a) corre sin drafter como fallback. |

## 11. Definición de "hecho"

S1 termina cuando:

- [ ] El proyecto Xcode compila y corre en iPhone 16 físico.
- [ ] Existe el protocolo `ModelRuntime` con implementaciones LiteRT-LM y llama.cpp.
- [ ] Los 3 combos (a, b, c) ejecutaron el set fijo de prompts completo.
- [ ] La sub-evaluación mmap vs no-mmap se ejecutó sobre el combo ganador.
- [ ] El reporte (`01-s1-runtime-report.md`) está escrito con todas las secciones de §9.
- [ ] La decisión final (runtime + modelo + drafter + mmap) está documentada y justificada.
- [ ] El harness Swift carga el ganador automáticamente al lanzar la app y hace streaming de tokens end-to-end.

## 12. Out of scope explícito (para evitar scope creep)

- Wake word, TTS, STT, VAD → S2.
- Tool calling, agente, scratchpad → S4.
- Memoria, embeddings, Qdrant, grafo → S5.
- Audio y video como modalidades → S10.
- Optimización fina más allá de comparar combos: cuantización exhaustiva, KV cache tuning, flash attention, etc. → futuro spec de optimización si los números no alcanzan.
- Cualquier integración cloud → S15.
- UI bonita: el harness es funcional, no de producción.
- Pipeline de descarga automática del modelo (manual en S1; se automatiza después).

## 13. Próximos specs que dependen del resultado de S1

| Spec | Cómo lo usa |
|---|---|
| S2 (voz) | TTFT del ganador define si barge-in es viable; el protocolo `ModelRuntime` se reutiliza. |
| S4 (agente) | Tokens/s steady state define ritmo de tool-calling; el protocolo es la fundación de la orquestación. |
| S5 (memoria) | RAM disponible tras cargar el modelo define cuánto espacio queda para retrievers/embeddings on-device. |
| S9 (visión) | El path multimodal de imagen elegido en S1 se extiende aquí. |
| S10 (audio) | Hereda el runtime; extiende a audio. |
