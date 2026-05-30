# S5a v2 — Rediseño de captura de memoria — Diseño

> **Padre:** spec S5a `2026-05-29-s5a-memoria-ondevice-design.md`; roadmap `00-roadmap.md` §3.2.
> **Origen:** verificación en iPhone 16 (2026-05-30) reveló que la captura por **extracción JSON libre post-turno** con el E4B produce memoria ruidosa por diseño: fragmentación/duplicados, sin manejo de contradicción, ruido de hechos del agente, y sobre-inyección sin relevancia. 6 parches (RC1–RC6) mejoraron pero no resolvieron la causa raíz → se replantea la captura.
> **Fecha:** 2026-05-30. **Device:** iPhone 16, Gemma 4 E4B / LiteRT-LM GPU. **Rama:** `fix/s5a-memory-quality`.

---

## 1. Problema (evidencia de device, corregida con feedback del usuario 2026-05-30)

El inspector de memoria tras unas conversaciones mostró:
- **Fragmentación/duplicados** que el dedup por string no junta: nombre ×3, Messi ×4 (`Messi` / `fútbol` / `Roilan likes Messi` / `…best player`), Black ×3, Amazon ×4, Juan fragmentado. **Este es el problema central.**
- **Sobre-inyección / falta de relevancia:** al preguntar *"what do I like?"* el modelo responde **dónde trabaja** el usuario. Causa: el fix RC6 (núcleo de identidad **siempre** inyectado) mete TODO (nombre + trabajo + gustos + …) al prompt, y el E4B vuelca todo sin filtrar por la pregunta. RC6 resolvió "no recuerda nada" pero se pasó al extremo opuesto.
- **Sin contradicción:** *"No, no trabajas en Amazon"* → el modelo dice "actualizaré mis registros" pero **no borra** nada.
- **Ruido del agente:** guarda hechos del sistema (`developed_by Google DeepMind`, `current_time`) como si fueran del usuario; bodies en inglés y español mezclados.
- **Re-guardado ante preguntas:** preguntar *"¿dónde trabajo?"* dispara `remember` de nuevo → duplica un dato ya guardado. (NO es fabricación: "Amazon" y "no me gusta el fútbol" eran afirmaciones reales del usuario; el guardado de hechos reales funciona. El problema es que también guarda al *preguntar*.)

**Causa raíz (diagnóstico arquitectónico):** "extraer JSON libre cada turno con un modelo de 3B" produce fragmentación + ruido que el dedup por string no controla; y la inyección de memoria no filtra por relevancia. Cada parche tapa un caso y aparecen otros. Hay que cambiar el motor de captura **y** afinar la relevancia de la inyección.

## 2. Objetivo

Reemplazar la captura por un mecanismo confiable: **una sola tool estructurada que el modelo llama**, con **escritura diferida en background** (responder primero, guardar después), **anti-fabricación dura**, **dedup semántico** y **manejo de contradicción**. Mantener el resto de S5a (almacenamiento, capas, retrieval con núcleo de identidad, olvido).

**Decisiones del brainstorm (2026-05-30):**
| Decisión | Elección |
|---|---|
| Motor de extracción | **Tool-calling estructurado** (`save_memory`), reusa el function-calling que el E4B ya hace fiable en device |
| Rutas de escritura | **Una sola, en vivo** (la tool). Se **elimina** el `MemoryConsolidator` (pasada JSON post-turno) |
| Timing del guardado | **Diferido en background**: la tool acusa al instante, Gemma responde conversacionalmente, y el guardado real (embedding+dedup+persistir) corre tras la respuesta |
| Dedup | **Semántico por embedding** (umbral de similitud), con `MemoryText` como pre-filtro barato |
| Contradicción | **`forget_memory`** llamada por el modelo al corregir/negar |
| Inyección (relevancia) | **Núcleo mínimo + relevante a la query**: siempre inyectar solo un núcleo chico (nombre + identidad permanente), y además los nodos que matcheen la pregunta. Recalibra RC6 (que metía todo). |

UX objetivo: *"me gusta el sushi"* → Gemma: **"¡qué bueno, me encanta el sushi!"** (respuesta primero) → en background guarda `preference: sushi`.

## 3. Arquitectura

### 3.1 `save_memory` tool (reemplaza al consolidator)
`Tool` de LiteRT-LM con params validados por schema:
- `kind: String` — enum `person | place | preference | fact` (sin `topic`: causaba mala clasificación; se mapea a preference/fact).
- `entity: String` — la entidad canónica corta (`sushi`, `Juan`, `Messi`), no una frase.
- `detail: String?` — contexto libre (`"le gusta"`, `"amigo, trabaja con el usuario"`).
- `permanent: Bool?` — identidad permanente.

`run()`: **no escribe en la DB directamente.** Valida, construye un `PendingMemory` y lo **encola** en `MemoryToolbox.shared.writeQueue`; devuelve al instante `"ok"` (acuse para que el modelo siga y responda). Emite actividad por el relay como las demás tools.

### 3.2 Escritura diferida (`MemoryWriter`)
Tras `.completed` del turno (en `Agent.run`, donde hoy se disparaba la consolidación), un task de fondo drena `writeQueue`:
1. `MemoryText.cleanLabel(entity)` + descartar junk.
2. **Embeber la entidad** y buscar el nodo más cercano por similitud (`store.nearest`); si supera umbral (p.ej. distancia < `mergeThreshold`) **o** match por `dedupKey` → `upsertMerging` (refuerza); si no, inserta nuevo + `setEmbedding`.
3. Enlazar al nodo `day` actual (timeline) — opcional v2; mantener si barato.
Corre serializado con el turno (RC3) — no compite con la sesión del engine.

### 3.3 Anti-fabricación (prompt + reglas)
La descripción de `save_memory` y el system prompt fijan:
- Guardar **solo** lo que el usuario **afirmó sobre sí mismo**; nunca inferir/inventar.
- **Nunca** llamar `save_memory` en respuesta a una **pregunta** del usuario ("¿dónde trabajo?" → no guarda).
- No guardar hechos del agente/sistema (quién lo creó, la hora). `get_current_time` no persiste.
- Few-shot: ejemplos de qué SÍ guardar ("me gusta X" → save preference X) y qué NO (preguntas, datos del agente, suposiciones).

### 3.4 Contradicción / corrección
`forget_memory(query)` (el `ForgetTool` actual, renombrado para consistencia) expuesto al modelo; el prompt instruye: ante negación/corrección ("no, no trabajo en X", "ya no me gusta Y"), llamar `forget_memory`.

### 3.5 Relevancia de inyección (recalibra RC6)
El problema "what do I like → responde el trabajo" es sobre-inyección. Fix:
- **Núcleo mínimo siempre:** solo nombre + nodos de capa `identity` (no el top-salience completo). Un puñado, no toda la memoria.
- **Relevante a la query:** el resto del bloque = solo nodos que matchean la pregunta (vector + FTS + grafo). "What do I like" → matchea `preference:*` → trae gustos; no arrastra `fact:workplace`.
- `MemoryStore.coreMemories()` se reduce a **identity-only** (quitar el `topSalient` que metía todo). El system prompt añade: "responde solo lo que el usuario preguntó; no enumeres toda la memoria."

### 3.6 Qué se conserva / qué se elimina
**Conservar:** `MemoryStore` + esquema + capas, `Decay`/dedup/sweep, `MemoryRetriever` (con **núcleo de identidad recalibrado a identity-only**, §3.6), embedder + índice, `MemoryText` (RC1), serialización de generación (RC3), responder-siempre-tras-tool (RC5), toggle + inspector.
**Eliminar:** `MemoryConsolidator.swift` + `MemoryConsolidatorTests.swift` (reemplazados por `save_memory` + `MemoryWriter`). El `MemoryServices.consolidator` se sustituye por el writer.

## 4. Componentes / archivos

- **Nuevo** `Memory/SaveMemoryTool.swift` — la tool estructurada (encola).
- **Nuevo** `Memory/MemoryWriter.swift` — drena la cola en background: clean → embed → dedup semántico → upsert. (Reusa `MemoryStore`/`Embedder`/`Decay`/`MemoryText`.)
- **Modificar** `Memory/MemoryToolbox.swift` — añadir `writeQueue: [PendingMemory]` (+ tipo `PendingMemory`).
- **Modificar** `Memory/MemoryStore+Dedup.swift` — `upsertMerging` admite match por id semántico ya resuelto (o helper `findSemanticDuplicate(embedding:threshold:)`).
- **Modificar** `Agent/Agent.swift` — registrar la tool; tras `.completed`, drenar la cola vía `MemoryWriter` (sustituye al consolidator); mantener serialización RC3.
- **Modificar** `Harness/HarnessModel.swift` — construir `save_memory`/`forget_memory` en el registro; `MemoryServices` pasa a `{retriever, writer}`.
- **Eliminar** `Memory/MemoryConsolidator.swift`, `GemmaTests/MemoryConsolidatorTests.swift`.
- **Renombrar/ajustar** `RememberTool`→`SaveMemoryTool` (o mantener `remember` como alias). `ForgetTool`→`forget_memory` (descr. para contradicción).

## 5. Flujo de datos

`turno → retrieve (vector+FTS+grafo+core RC6) → inject → modelo responde, y si hay un hecho del usuario llama save_memory(entity,...) → tool encola + acusa "ok" → modelo cierra con respuesta conversacional (RC5) → .completed → MemoryWriter drena cola en background (clean→embed→dedup semántico→upsert) serializado (RC3)`.

**Errores:** entity junk/vacía → descartar. Embedder ausente → dedup cae a `dedupKey` (degradación). Falla de DB → loggear, no romper el turno. Cola con duplicados en un mismo turno → el dedup los colapsa.

## 6. Pruebas

- **`SaveMemoryTool`:** schema válido; encola un `PendingMemory`; no escribe en DB directamente (la cola crece, la DB no).
- **`MemoryWriter`:** drena cola → crea nodo limpio; **dedup semántico** con `FakeEmbedder` (3 frasings de "Messi" mapeados a vectores cercanos → 1 nodo reforzado); junk descartado.
- **No-fabricación (estructural):** un turno cuyo prompt es una pregunta y el stub-runtime **no** llama la tool → 0 nodos (verifica que la ruta solo escribe cuando la tool se llama; el juicio del modelo se valida en device).
- **`forget_memory`:** borra el match.
- **Orden (diferido):** la respuesta del turno se emite antes de que el writer termine (la cola se drena en `.completed`).
- **Regresión:** retriever (core RC6), store, agent (RC5/RC3), MemoryText siguen verdes.
- **Device:** decir gustos/persona/lugar y confirmar en inspector: sin duplicados, sin fabricación ante preguntas, contradicción borra, respuesta conversacional + guardado en background. Registrar en `01-s1-runtime-report.md` §9.

## 7. Fuera de alcance (a S11 / futuro)

Importancia/scoring fino (#22), compresión de días viejos (#9), episodios (#15), confidence UX (#12), normalización de idioma profunda, merge por LLM. Embeddings premium/servidor → S5b. Sync → S5c.
