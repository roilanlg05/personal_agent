# S5a — Memoria on-device v1 — Diseño

> **Padre:** roadmap `00-roadmap.md` §3 (S5). **S5 se descompone en S5a / S5b / S5c**; este spec cubre **S5a** (todo on-device, sin servidor). Construye sobre el agente + tool-calling de **S4** (verificado en device) y el runtime **LiteRT-LM** E4B (S1/S1.1).
> **Fecha:** 2026-05-29. **Device:** iPhone 16, Gemma 4 E4B / LiteRT-LM GPU.

---

## 0. Descomposición de S5

S5 (Memoria v1) del roadmap es demasiado grande para un solo spec. Se parte en tres sub-proyectos, cada uno con su propio spec → plan → ejecución:

- **S5a — Memoria on-device v1 (ESTE spec):** L1 live + L2 daily + L4 identity, captura híbrida, grafo base de personas/lugares/relaciones, recuperación híbrida (vector+grafo+recencia) e inyección de contexto (#18). Todo en el device; shippable y verificable solo en el iPhone 16. Define el modelo de datos y el seam de integración que reutilizan S5b/S5c/S11.
- **S5b — Backend de memoria en el servidor (nodo, futuro):** embeddings premium bilingües, Qdrant, graphify en el PC de casa (i3/16GB/512GB Linux). Vectores/identidad de largo plazo.
- **S5c — Sync + retrieval híbrido contra servidor (nodo, futuro):** protocolo device↔servidor (las columnas de sync ya nacen en S5a) y retrieval híbrido vector+grafo apoyado en el servidor.

Decisiones diferidas del roadmap §5 que toca S5a: **esquema del grafo (base)** se resuelve aquí; **modelo de embeddings bilingüe** y **protocolo device↔server** se difieren a S5b/S5c (S5a usa embeddings de Apple on-device y deja las columnas de sync listas).

---

## 1. Problema y objetivo

Hoy el agente (S4) corre turnos con tool-calling pero **no recuerda nada** entre turnos ni entre sesiones. La visión (`docs/initial_idea.txt` 316–553) es memoria **tipo humana**: capas temporales, olvido gradual, recall asociativo (vector + grafo), continuidad.

**Objetivo (S5a):** dar al agente memoria persistente on-device que (1) **capture** hechos del usuario (explícitos e implícitos), (2) los **almacene** en un grafo+vector+keyword unificado con capas y olvido tipo humano, y (3) los **recupere e inyecte** de forma relevante en cada turno (#18), todo en el device y verificable en el iPhone 16.

**Decisión de ambición (usuario):** la memoria debe ser **lo más parecida a la humana posible, sin importar el costo de trabajo**. Por eso v1 incluye **curva de olvido + reforzamiento** y **recall asociativo por spreading-activation**, no solo TTL duro.

**No-objetivos (a otros specs):** episodios/clustering, daily summary (#25), compresión de días viejos (#9), importance scoring profundo (#22), soft-confidence UX (#12), multi-step linking (#15), emotional timelines, meta-grafo narrativo → **S11**. Embeddings premium, Qdrant, graphify-servidor → **S5b**. Sync device↔servidor → **S5c**. Consolidación en background real (app cerrada) → **S0** (en v1 corre async al cerrar el turno con la app activa).

---

## 2. Decisiones tomadas (brainstorm 2026-05-29)

| Decisión | Elección | Razón |
|---|---|---|
| Estrategia de recuperación | **Híbrido on-device**: grafo + recencia + embeddings de Apple `NLContextualEmbedding` | Recall vector+grafo de la idea inicial, sin servidor ni MLX; el embedder premium del servidor (S5b) entra detrás del mismo protocolo |
| Motor de DB | **SQLite (GRDB) + `sqlite-vec` + FTS5** | Un solo motor embebido: KNN vectorial + keyword + grafo (tablas nodo/arista + CTE recursivo); migraciones first-class; columnas sync-friendly; control de performance |
| Captura | **Híbrida**: tool `remember`/`forget` + pasada de consolidación post-turno | Tool = preciso para lo explícito; pasada = auto-memoria implícita (#1) sin penalizar latencia del turno |
| Capa de identidad (L4) | **L4 con promoción heurística**, orientada a lo más humano posible | El grafo de personas/lugares vive en L4; promoción por repetición/explicitud; scoring fino → S11 |

---

## 3. Arquitectura

### 3.1 Modelo de datos (esquema unificado, a prueba de futuro)

Una sola DB SQLite (GRDB), archivo en Application Support. Tablas núcleo:

- **`node`** — `id` TEXT (UUID) PK · `kind` TEXT (`person|place|fact|preference|topic|day|episode|conversation`) · `label` TEXT (canónico) · `body` TEXT · `layer` TEXT (`live|daily|identity`; `episodic` reservado para S11) · `created_at` · `updated_at` · `last_seen_at` · `salience` REAL · `decay_rate` REAL · `confidence` TEXT (`sure|probable|maybe`) · `mention_count` INT · `ttl_expires_at` REAL? · `source_ref` TEXT? (conversation/message) · `origin` TEXT (`explicit|extracted`) · `server_id` TEXT? · `dirty` INT · `deleted` INT (tombstone) · `extra` TEXT (json).
- **`edge`** — `id` TEXT PK · `src_id` · `dst_id` · `relation` TEXT (`knows|works_with|family|likes|dislikes|located_at|visited|happened_on|mentioned_in|part_of_episode|related_to`) · `weight` REAL · `confidence` TEXT · `created_at` · `updated_at` · `dirty` · `deleted` · `extra`.
- **`node_fts`** — FTS5 externo sobre (`label`, `body`) → keyword.
- **`node_vec`** — virtual table `sqlite-vec` (`node_id`, `embedding float[D]`); `D` = dim de `NLContextualEmbedding` (script latino, mean-pooled).
- **Índices**: `kind`, `layer`, `ttl_expires_at`, `updated_at`, `last_seen_at`; sobre `edge`: `src_id`, `dst_id`, `relation`.

**Por qué es a prueba de futuro:** los nodos `day` (`label=YYYY-MM-DD`) hacen emerger el "graph por día" sin tablas extra; los episodios de S11 son nodos `kind=episode` conectados con aristas `part_of_episode` (meta-grafo). Las columnas de sync (`server_id/dirty/deleted/updated_at`) existen desde el día 1 para S5c. El esquema cubre L1→L4 + episodios **sin migración destructiva** → no se rehace la DB en S11/S5c.

### 3.2 Capas + olvido tipo humano

- **L1 Live** — working memory del turno/conversación actual: en memoria + nodos de TTL corto. Decae rápido.
- **L2 Daily** — hechos/eventos recientes; `salience` decae con el tiempo (Ebbinghaus) salvo refuerzo.
- **L4 Identity** — rasgos/personas/lugares estables; `ttl_expires_at` null, salience alta, `decay_rate` lento.

**Salience + refuerzo (`Memory/Decay.swift`, math pura):** `salience_efectiva = salience_base * exp(-decay_rate * Δt)`. Re-mención → refuerzo (`salience += bump`, `mention_count++`, `last_seen_at = now`). Promoción **L2→L4** al cruzar umbral (p.ej. `mention_count ≥ N` o `origin=explicit&permanent`). Olvido: salience efectiva < piso **y** (`ttl` vencido o capa no-identity) → `deleted=1` (soft) en barrido de compactación. Más humano que TTL duro: se desvanece gradual, se fortalece con uso.

### 3.3 Captura (híbrida)

- **Tools (registradas en el `ToolRegistry` de S4):**
  - `remember(content, kind?, permanent?)` → upsert nodo `origin=explicit`, `confidence=sure`, capa `identity` si `permanent`.
  - `forget(query)` → busca y marca `deleted=1` los nodos que matchean.
- **Pasada de consolidación post-turno (`MemoryConsolidator`):** al cerrar el turno, **el mismo E4B** corre un prompt de extracción estructurada sobre el intercambio (user + respuesta) → JSON de memorias `{kind,label,body,relations[],confidence,ttl_hint}`. Pistas TTL (`"manejando"→2h`). Por cada item: **upsert con dedup** (ver 3.4), set `confidence` (`extracted ⇒ probable/maybe`), embed, enlace al nodo `day` actual y al nodo `conversation`. Corre **async tras la respuesta** (no bloquea el stream del turno).

### 3.4 Dedup / merge (consolidación)

Antes de insertar un candidato: match contra nodos existentes por (a) `label` exacto + `kind`, (b) FTS, (c) similitud vectorial sobre umbral. Si hay match → **refuerza** el nodo existente (3.2) en vez de duplicar; fusiona `body`/aristas. Evita fragmentación (memoria humana consolida, no acumula duplicados).

### 3.5 Recuperación + inyección (#18, `MemoryRetriever`)

Al inicio de cada turno, antes de generar:
1. Construye query del prompt del usuario (+ último turno).
2. Candidatos por 4 vías: **vector** ANN (`node_vec`), **FTS** keyword, **recencia** (`last_seen_at`), **spreading activation en grafo** (expande 1–2 hops desde nodos match siguiendo `edge`: "Juan" → aristas → lugares/eventos/relaciones).
3. Merge + ranking: `score = w1·similitud + w2·salience_efectiva + w3·recencia + w4·proximidad_grafo`.
4. Top-K con presupuesto de tokens → render a un bloque compacto ("Lo que sabes del usuario / memorias relevantes") inyectado al **system prompt** del Agente.

Recall asociativo híbrido (vector+grafo+recencia) — el ejemplo "el restaurante que mencioné cuando estaba con Juan" se resuelve combinando vector (restaurante) + grafo (Juan→día→lugar).

### 3.6 Integración en el Agente

`Agent` (S4) gana `MemoryStore` + `MemoryRetriever` + `MemoryConsolidator`. En `run()`:
1. `retrieve` memorias → inyecta bloque en `systemPrompt`.
2. Stream del turno (existente, con tools del registro incl. `remember`/`forget`).
3. En `.completed` → dispara `consolidator.consolidate(turn)` async.

Respeta `@MainActor` del runtime; el trabajo de DB/embeddings corre fuera del MainActor (GRDB en su cola; embeddings en task) y se sincroniza al actualizar UI.

---

## 4. Componentes / archivos nuevos

- `Memory/MemoryModels.swift` — `Node`, `Edge`, enums (`NodeKind`, `MemoryLayer`, `Relation`, `Confidence`, `Origin`).
- `Memory/MemoryStore.swift` — GRDB: esquema + migraciones + CRUD + upsert/dedup + barrido de olvido; integra `sqlite-vec` y FTS5.
- `Memory/Embedder.swift` — protocolo `Embedder` + impl `NLContextualEmbedder` (Apple, mean-pooling, manejo de assets); fake para tests; sirve de seam para el embedder del servidor (S5b).
- `Memory/Decay.swift` — math pura de salience/decay/promoción/umbral de olvido.
- `Memory/MemoryRetriever.swift` — recuperación híbrida + ranking + render del bloque de inyección.
- `Memory/MemoryConsolidator.swift` — prompt de extracción + parseo JSON + upsert.
- `Memory/RememberTool.swift`, `Memory/ForgetTool.swift` — `Tool` de LiteRT-LM (vía relay de actividad de S4).
- `Agent/Agent.swift` — extendido (retrieve→inject→stream→consolidate).
- `Settings/` + `Harness/` — toggle de memoria + **inspector de memoria** (lista de nodos/aristas, salience, capa) para depurar/verificar.
- Integración de `sqlite-vec` en el build (ver §6 riesgos).

---

## 5. Flujo de datos y errores

**Turno:** `prompt → Agent.retrieve (vector+FTS+recencia+grafo, rank, top-K) → inject systemPrompt → runtime.generate(tools) → stream → .completed → consolidate async (E4B extrae JSON → upsert/dedup/embed/link day+conversation)`.

**Errores:** embedder sin asset / falla → degradar a retrieval no-vectorial (FTS+grafo+recencia) y loggear (la interfaz no cambia). Extracción devuelve JSON inválido → descartar esa pasada (no corromper la DB), loggear. Falla de DB → el turno sigue sin memoria (degradación segura). Dedup ambiguo → preferir refuerzo sobre duplicado. `forget` sin match → no-op informado.

---

## 6. Riesgos

- **Integración de `sqlite-vec` en iOS** (riesgo #1): es una extensión C; hay que compilarla/enlazarla con el SQLite que usa GRDB (SQLite custom o carga de extensión). Recordar la fricción SPM de LiteRT ([[litertlm-spm-workaround]]); validar temprano con un spike de build. Mitigación si bloquea: vector como blob + coseno en Swift para v1 (N pequeño), manteniendo la misma interfaz `Embedder`/`MemoryStore`.
- **Calidad de extracción del E4B** (riesgo #2): el modelo chico puede extraer ruido o JSON mal formado. Mitigación: prompt de extracción estricto (formato JSON + ejemplos), validación + descarte, `confidence` bajo por defecto, y el inspector para auditar.
- **`NLContextualEmbedding`**: requiere asset por script (descarga vía `requestAssets`) y mean-pooling de vectores de token; multilingüe latino cubre español+inglés. Detrás de protocolo → swap a server (S5b) sin tocar retrieval.
- **Latencia de consolidación**: una 2ª pasada del E4B por turno consume GPU; corre async post-respuesta; en v1 solo con app activa (background real = S0). Posible batch/diferido si pesa.
- **Ranking sin tuning**: los pesos `w1..w4` son heurísticos; el inspector + el E2E permiten ajustarlos; importance scoring fino llega en S11.

---

## 7. Pruebas / verificación

- **Unit (Mac, simulador):** migración del esquema; CRUD nodo/arista; upsert/dedup/merge; `Decay` (math pura: decay, refuerzo, promoción, umbral de olvido); ranking del retriever con fixtures in-memory; `MemoryConsolidator` con **runtime stub** que devuelve JSON canónico → asevera upsert correcto; `RememberTool`/`ForgetTool` lógica; `Embedder` fake. `NLContextualEmbedder` real y cualquier path `sqlite-vec` device/gated.
- **Device E2E (iPhone 16):** sesión 1 — "me llamo X, me gusta el sushi, mi amigo Juan trabaja conmigo". Turno nuevo — "¿qué me gusta comer?" → respuesta usa memoria; "¿quién es Juan?" → recall por grafo (relación works_with). **Relanzar app** → la memoria persiste. Verificar en el inspector que se crearon nodos `person:Juan`, `preference:sushi`, aristas, y `day` del día.
- Correr tests con `-parallel-testing-enabled NO` (ver [[gemma-simulator-destination]]); éxito = "Test Suite … passed". Tras tocar código: `graphify update .`.

---

## 8. Entregables

1. Capa `Memory/` completa (models, store con GRDB+sqlite-vec+FTS, embedder, decay, retriever, consolidator, tools).
2. Integración de `sqlite-vec` en el build (o fallback blob+coseno documentado).
3. `Agent` con retrieve→inject→consolidate; `remember`/`forget` en el registro.
4. Toggle en Settings + inspector de memoria en el harness.
5. Tests unit (Mac) + E2E device-gated + `graphify update`.
6. Columnas de sync presentes (no usadas hasta S5c).
