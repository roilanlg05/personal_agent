# M3a — Memory Service en Docker (design)

> **Estado:** diseño aprobado en brainstorming 2026-06-02. Implementación pendiente (próximo paso: plan).
>
> **Contexto del proyecto:** el agente Gemma corre hoy en una app **macOS** (Swift/SwiftUI) que orquesta un loop de tool-calling contra `mlx_vlm.server` (modelo Gemma 4 26B-A4B-it 4-bit + drafter MTP) y mantiene la memoria en proceso (GRDB + SQLite + consolidación nocturna). El usuario decidió un nuevo pivot: el iPhone vuelve a ser el cliente final del usuario y el Mac queda como motor de inferencia. Para liberar RAM del Mac y permitir mover la memoria a otra máquina (PC casero i3 + 16GB + Linux), la **capa de memoria se extrae a un servicio independiente, deployable como Docker**, accesible vía HTTP. M3a es **ese refactor y nada más**: extraer la memoria a un servicio Docker, manteniendo el macOS app actual como cliente de prueba. El target iOS, EventKit y la voz quedan para M3b/M3c/M3d.

---

## 1. Objetivo

Extraer todo el subsistema de memoria del proceso de la app macOS a un **servicio HTTP independiente** que corre en Docker, listo para deployarse en cualquier host Linux (incluyendo el i3 doméstico futuro). El servicio gestiona el store GRDB, la consolidación, los summaries, el grafo y el transcripto, y expone una API REST que el agente consume desde cualquier cliente (Mac hoy, iOS en M3b). El embedder de Apple `NLContextualEmbedding` (macOS/iOS only) se reemplaza por un sidecar Python con **BGE-M3** para que el servicio sea portable a Linux.

**Definition of done:** Docker Compose levanta `memory` + `embedder`. El macOS app actual hace toda su captura/recall/consolidación contra el servicio (sin tocar GRDB en proceso). La calidad de recall/dedup/consolidación es ≥ la del estado actual del macOS app (verificada con los E2E reales contra el modelo 26B). El stack puede moverse al i3 cambiando solo la base URL en Settings del cliente, sin tocar contenedores.

---

## 2. Decisiones lockeadas (del brainstorming)

| Tema | Decisión | Implicación |
|---|---|---|
| Ubicación de la memoria | Servicio independiente, deployable a otra máquina | No vive más en proceso del app cliente. |
| Empaquetado | Docker desde el día 1 (sin paso intermedio en-proceso) | `docker-compose.yml` es la unidad de deploy. |
| Lenguaje del servicio | Swift (reutiliza GRDB + lógica actual) | Swift Linux + GRDB Linux son hoy estables. |
| Framework HTTP | Hummingbird 2 | Async/await nativo, ligero, mantenido. |
| Embedder | Sidecar Python con `BAAI/bge-m3` (1024-dim) | Calidad multilingüe alta; ~570MB modelo; ~1GB RAM; CPU-only para empezar. |
| Memoria existente | **Wipe**, start from scratch | Sin código de migración 384→1024 dim. La memoria pre-M3a queda como backup en disco. |
| Transporte cliente↔servicio (en este hito) | HTTP plain dentro de `localhost` (Docker en el Mac) | Tailscale entra cuando muevas el stack al i3 (cambio de URL del lado del cliente, fuera de scope de M3a). |
| Auth | `Authorization: Bearer <token>` con shared secret en `.env` | Defensa en profundidad sobre Tailscale. |
| Cliente para M3a | macOS app actual (Gemma.app) | iOS app llega en M3b. |
| Modelo | Sigue corriendo en el Mac, `mlx_vlm.server` :8080 (sin cambios) | El servicio consume el modelo HTTP para consolidar. |

---

## 3. Topología

```
┌── Mac M4 24GB ──────────────────────────────────────────────┐
│                                                              │
│  mlx_vlm.server  ──── :8080   (inferencia, sin cambios)      │
│                                                              │
│  Docker compose:                                             │
│    memory     :8081 (host)                                   │
│      └─ Swift + Hummingbird + GRDB + AsyncHTTPClient         │
│      └─ habla a embedder (interno) y mlx_vlm (host)          │
│    embedder   (sin puerto al host, solo red interna)         │
│      └─ Python + FastAPI + sentence-transformers + BGE-M3    │
│                                                              │
│  Gemma.app (macOS) ── HTTP → :8080 + :8081                   │
└──────────────────────────────────────────────────────────────┘
```

Migración futura al i3:
- Container `memory` + `embedder` se mueven sin cambios al i3 (Linux x86_64; las imágenes son multi-arch).
- El cliente cambia `MemoryBaseURL` a la IP de Tailscale del i3.
- El servicio sigue llamando a `mlx_vlm.server` en el Mac vía Tailscale (otra URL en `MODEL_URL` env).

---

## 4. Componentes — qué se queda en el cliente y qué se va al servicio

| Pieza actual | Después de M3a | Notas |
|---|---|---|
| `Agent.run` (tool loop, prompt assembly) | **Cliente** | Sin cambios funcionales. Llama a `MemoryClient` HTTP en vez de `MemoryStore`. |
| `ServerRuntime` (HTTP→mlx_vlm) | **Cliente** | Sin cambios. |
| `ToolRegistry`, `AgentTool` | **Cliente** | Sin cambios. |
| `CurrentTimeTool` | **Cliente** | Pura, sin memoria. |
| `SaveMemoryTool`, `ForgetTool`, `ExpandContextTool`, `ReflectTool` | **Cliente**, cuerpos refactorizados | Llaman a `MemoryClient` en vez de `MemoryToolbox.shared.store`. |
| `MemoryStore` (GRDB + SQLite) | **Servicio** | Se mueve tal cual. |
| `TranscriptStore` + `ConversationWindow` | **Servicio** | El transcripto vive con la memoria. |
| `MemoryRetriever` (recall) | **Servicio** | El endpoint `/v1/memory/recall` devuelve el bloque ya armado. |
| `MemoryConsolidationEngine`, `ConsolidationScheduler` | **Servicio** | Corren en el container. Llaman `mlx_vlm.server` HTTP. |
| `Embedder` protocol + `NLContextualEmbedder` | **Servicio** (sidecar reemplaza `NLContextualEmbedder`) | Implementación `RemoteEmbedder` llama `POST /embed` al sidecar. |
| `MemoryView` (inspector SwiftUI) | **Cliente**, datos vía HTTP | Llama `/v1/nodes`, `/v1/transcript/recent`, `/v1/consolidation/state`. |

---

## 5. API HTTP del Memory Service (REST + JSON)

Versionado con prefijo `/v1`. Auth con header `Authorization: Bearer <token>`. Errores `{ "error": { "code", "message" } }` + HTTP status.

### 5.1 Transcripto / ventana

- `POST /v1/transcript/append`
  - Body: `{ "threadId": str, "role": "user"|"assistant", "text": str, "turnIndex": int }`
  - Response: `{}` 200
- `GET /v1/conversation/window?threadId=&maxTurns=&maxChars=`
  - Response: `{ "turns": [{ "role": str, "text": str }] }` (orden ascendente)

### 5.2 Memoria

- `POST /v1/memory/recall`
  - Body: `{ "query": str, "scope": "core"|"core+recall"|"all"?, "limit": int? }` (default `core+recall`, limit 6)
  - Response:
    ```json
    {
      "core": [{ "label": str, "body": str }],
      "recall": [{ "kind": str, "label": str, "body": str, "extra": str? }]
    }
    ```
- `POST /v1/memory/save`
  - Body: `{ "kind": str, "label": str, "body": str?, "extra": str?, "sourceRef": str? }`
  - Response: `{ "id": str, "mergedInto": str? }` (`mergedInto` presente si dedup semántico fusionó con un nodo existente)
- `POST /v1/memory/forget`
  - Body: `{ "id": str? } | { "label": str? }` (uno de los dos)
  - Response: `{ "removed": int }`
- `GET /v1/memory/expand?topic=`
  - Response: `{ "transcript": [{ "role": str, "text": str }], "summaryLabel": str? }`

### 5.3 Consolidación

- `POST /v1/consolidation/turn-end`
  - Body: `{ "threadId": str }`
  - Response: `{}` (arma timer post-turn y dispara reflexión si toca)
- `POST /v1/consolidation/reflect`
  - Body: `{}`  (manual / botón "Consolidar")
  - Response: `{ "cycleId": str }`
- `GET /v1/consolidation/state`
  - Response: `{ "lastCycle": { "id": str, "status": str, "endedAt": iso }?, "nodeCount": int, "transcriptCount": int, "isRunning": bool }`

### 5.4 Inspector (read-only)

- `GET /v1/nodes?limit=&offset=&kind=` → `{ "nodes": [Node], "total": int }`
- `GET /v1/transcript/recent?limit=` → `{ "rows": [TranscriptRow] }`

### 5.5 Salud

- `GET /healthz` → 200 si DB + embedder responden.
- `GET /readyz` → 200 cuando el container terminó migraciones y el embedder está accesible.

---

## 6. Container `memory` (Swift)

- **Image base build**: `swift:5.10-jammy`
- **Image runtime**: `swift:5.10-jammy-slim` (multi-stage)
- **Tamaño objetivo**: ≤ 250MB
- **Package**: nuevo `memory-service/` con SwiftPM. Dependencies:
  - `hummingbird` (HTTP server)
  - `GRDB.swift` (DB; misma versión que usa el app hoy)
  - `swift-async-http-client` (cliente HTTP para embedder + mlx_vlm)
  - `swift-log` (logging estructurado)
- **Reutilización**: se copia/mueve a `memory-service/Sources/MemoryCore/` el contenido de `Gemma/Gemma/Memory/` (Store, Retriever, ConsolidationEngine, Decay, NodeKind, MemoryText, summarize prompts, Embedder protocol). Se quitan dependencias de `AppKit`/`UIKit`/`NaturalLanguage` (NLContextualEmbedder se borra del paquete; la lógica de embedder pasa a `RemoteEmbedder`).
- **Persistencia**: SQLite file en `/data/memory.sqlite` → volumen Docker. En el Mac: `${XDG_DATA_HOME:-$HOME/Library/Application Support}/Gemma/memory-docker/`. En el i3 (futuro): `/var/lib/gemma/`.
- **Config (env vars)**:
  - `MEMORY_DB_PATH` (default `/data/memory.sqlite`)
  - `EMBEDDER_URL` (default `http://embedder:8000`)
  - `MODEL_URL` (URL del `mlx_vlm.server`; default `http://host.docker.internal:8080` para el Mac)
  - `MEMORY_BEARER_TOKEN` (obligatorio; sin default)
  - `IDLE_MS`, `POST_TURN_MS` (timers de consolidación)
- **Logs**: stdout, JSON-line (level/timestamp/event/extra).

---

## 7. Container `embedder` (Python)

- **Image base**: `python:3.11-slim`
- **Stack**: FastAPI + `sentence-transformers` + `torch` (CPU wheel)
- **Modelo**: `BAAI/bge-m3` (1024-dim, multilingüe)
- **API**:
  - `POST /embed` body `{ "texts": ["...", "..."] }` → `{ "vectors": [[float; 1024], ...] }`
  - `GET /healthz` → 200 OK
- **Modelo cache**: `/models/` en volumen persistente (`embedder-models`). Primera vez descarga ~570MB; arranques posteriores son instantáneos.
- **RAM**: ~1GB. CPU-only (Docker Desktop en M4 no expone Metal).
- **No expuesto al host**: solo accesible desde el container `memory` por la red interna del compose.

---

## 8. Cliente macOS — refactor mínimo

Cambios concretos en `Gemma/Gemma/`:

- **Crear** `Memory/MemoryClient.swift`: struct con `URLSession` + `JSONEncoder/Decoder` + métodos `recall(...)`, `save(...)`, `forget(...)`, `expand(...)`, `appendTranscript(...)`, `conversationWindow(...)`, `consolidationTurnEnd(...)`, `reflect()`, `state()`, `nodes(...)`, `transcriptRecent(...)`. Recibe `baseURL` + `bearerToken` por init.
- **Modificar** `Memory/MemoryToolbox.swift`: en vez de `var store: MemoryStore?`, `var embedder: Embedder?`, `var transcriptStore: TranscriptStore?` → un solo `var memory: MemoryClient?`. El resto del cuerpo público de los tools no cambia (`MemoryToolbox.shared.memory`).
- **Modificar** las 4 tools (`SaveMemoryTool`, `ForgetTool`, `ExpandContextTool`, `ReflectTool`) para llamar a `memory.save(...)`, `.forget(...)`, `.expand(...)`, etc. La lógica de matching / dedup / etc se va al servicio (los tools se simplifican significativamente).
- **Modificar** `Harness/HarnessModel.swift`:
  - `ensureMemory()` ahora instancia `MemoryClient(baseURL: ..., token: ...)` desde `@AppStorage("memoryBaseURL")` y `@AppStorage("memoryBearerToken")` (defaults `http://localhost:8081` y empty).
  - `runAgentTurn` reemplaza llamadas a `store.recall(...)` / `transcriptStore.append(...)` / `consolidator.armTurnEnd(...)` por `memory.recall(...)`, `memory.appendTranscript(...)`, `memory.consolidationTurnEnd(...)`.
  - El loop del agente sigue ejecutando tools localmente; solo lo que hablaba con GRDB ahora va por HTTP.
- **Modificar** `Harness/MemoryView.swift`: consume `memory.nodes()`, `memory.transcriptRecent()`, `memory.state()` para pintar las tabs Lista/Grafo/Transcript. Eliminar acceso directo a `MemoryStore.dbQueue`.
- **Borrar** del target app: `MemoryStore.swift`, `TranscriptStore.swift`, `MemoryRetriever.swift`, `MemoryConsolidationEngine.swift`, `ConsolidationScheduler.swift`, `MemoryConsolidator.swift`, `Decay.swift`, `NodeKind.swift`, `NLContextualEmbedder.swift`, `FakeEmbedder.swift`, `MemoryText.swift`, `EpisodeRecorder.swift` (si quedaba), y todos sus tests. Toda esa lógica se va al package `memory-service/`.
- **Settings**: agregar campos `MemoryBaseURL` (default `http://localhost:8081`) y `MemoryBearerToken` (default vacío). Mismo patrón que `keepModelResident` y demás.

---

## 9. Layout del repo después de M3a

```
personal_agent/
├─ Gemma/                        # macOS app (cliente)
│  └─ Gemma/
│     ├─ Agent/                   # AgentTool, Agent.run, ToolRegistry, CurrentTimeTool
│     ├─ Runtime/                 # ServerRuntime, ServerManager, ServerProcess, HTTPServerHealth
│     ├─ Harness/                 # SwiftUI views, HarnessModel, AgentChatView, MemoryView
│     └─ Memory/                  # MemoryClient + 4 tools (cuerpos HTTP)
├─ memory-service/                # NUEVO: Swift package
│  ├─ Package.swift
│  ├─ Sources/MemoryCore/         # Store/Retriever/Engine/Decay/NodeKind/MemoryText...
│  ├─ Sources/MemoryService/      # main.swift + handlers + App.swift (Hummingbird)
│  ├─ Tests/MemoryCoreTests/      # tests portados
│  ├─ Tests/MemoryServiceTests/   # tests de handlers + fake embedder
│  └─ Dockerfile
├─ embedder/                      # NUEVO
│  ├─ app.py                      # FastAPI + sentence-transformers
│  ├─ requirements.txt
│  ├─ test_app.py                 # smoke test
│  └─ Dockerfile
├─ docker-compose.yml             # NUEVO: levanta memory + embedder
├─ .env.example                   # NUEVO: MEMORY_BEARER_TOKEN, etc
├─ spike-mlx/                     # sin cambios
└─ docs/                          # sin cambios estructurales
```

---

## 10. Errores y degradación

- **Memory Service caído**: cualquier `MemoryClient.<call>` tira error → el agente loggea warning, devuelve `recall: []`/`core: []` (vacío), sigue charlando. Save tool retorna "memoria no disponible" como tool-result; el modelo lo verá.
- **Embedder caído pero memoria viva**: `save` retorna 503 (`embedder_unavailable`). `recall` cae a búsqueda léxica FTS-only (sin similitud vectorial). El cliente sigue funcionando, peor calidad de recall.
- **Modelo caído (mlx_vlm.server)**: el endpoint de consolidación retorna 503; el scheduler reintenta más tarde.
- **Timeouts cliente→servicio**: 500ms en GET, 2s en POST estándar, 30s en `/consolidation/reflect` (manual sync).
- **Crash del container**: Docker compose `restart: unless-stopped`. La DB en volumen sobrevive.

---

## 11. Testing

- **MemoryCore (unidad)**: los tests actuales del Memory layer del app se mueven al nuevo package y deben seguir verdes con un `FakeEmbedder` (que aún se conserva, fuera del app, dentro del test target del servicio).
- **MemoryService (integración)**: tests sobre handlers Hummingbird con un fake embedder in-process. Validan API contracts (status codes, JSON shape, errores).
- **Embedder (smoke)**: `pytest` con un test único — embeber "hola"+"hello" devuelve dos vectores 1024-dim no triviales y similitud razonable.
- **End-to-end real (gated `GEMMA_LIVE_DOCKER=1`)**: el test levanta el compose, hace una secuencia (save → recall → expand → forget → consolidate→state), verifica que el flujo completo cierra. Igual que `ServerManagerLiveTests` pero apuntando a Docker.
- **Cliente macOS (unidad)**: `MemoryClientTests` con `URLProtocol` mock para cada endpoint (mismo patrón que `ServerRuntimeTests`).
- **App E2E vs 26B**: el test `ServerE2ETests` adaptado para que la app converse usando el servicio Docker real (gated separado para no acoplar a Docker en CI futuro).

---

## 12. Métricas de éxito (cómo confirmamos que está hecho)

1. `docker compose up -d` levanta los dos containers; `curl :8081/healthz` y `curl :8081/readyz` retornan 200; embedder no expuesto al host.
2. Suite Swift completa del app macOS pasa en verde (con el servicio corriendo en background del runner para los E2E gated).
3. Un turno completo (chat + recall + save + consolidación) pasa contra el modelo 26B real, idéntico en resultado al estado actual: la calidad de recall y dedup es ≥ al benchmark M2d-3.
4. Apagar el container `memory` y enviar un turno → la app sigue funcionando (sin recall ni save), sin crash.
5. Reiniciar el container y leer el inspector → la memoria persiste (volumen funcionando).

---

## 13. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| GRDB en Linux Swift falla de forma sutil (locking SQLite, etc) | Ya hay reportes públicos de uso server-side; usar `DatabaseQueue` (no `Pool`) por ahora — single-writer. |
| Calidad de BGE-M3 vs `NLContextualEmbedding` en ES coloquial | Wipe inicial obliga a partir limpio; los E2E del agente miden recall real contra el 26B (si el recall empeora, queda evidencia y M3a.5 puede ajustar). |
| RAM del embedder (1GB) en el Mac durante M3a | M3a corre en el Mac mientras desarrollas; cuando muevas el stack al i3, el Mac libera ese GB. Aceptable en M4 24GB. |
| Latencia extra HTTP en cada recall (5-50ms loopback Docker) | Aceptable; el bottleneck del turno es la generación del modelo (segundos), no la memoria. |
| Swift compile lento en Docker | Multi-stage build cachea capa de dependencias; `swift build -c release` en builder; runtime es slim. |
| `host.docker.internal` no resuelve en Linux nativo (cuando muevas al i3) | Documentar: en compose del i3 usar `extra_hosts: ["host.docker.internal:host-gateway"]` o variable `MODEL_URL` apuntando explícitamente a la Tailscale IP del Mac. |

---

## 14. Out-of-scope (explícito)

- iOS app (queda para **M3b** — nuevo target, port de Agent/Tools/UI).
- EventKit / Reminders / Maps / Contactos / Weather (**M3c**).
- Pipeline de voz: wake word, STT, TTS, barge-in, state machine (**M3d**).
- Deploy productivo en el i3 (al cerrar M3a basta con cambiar `MEMORY_BASE_URL` del cliente y arrancar el compose en el i3 — no hay trabajo de código adicional).
- Backups automatizados de la SQLite del volumen.
- Soporte multi-usuario / multi-tenant.
- Migración de datos del macOS app (decisión "wipe" lockeada).

---

## 15. Próximos pasos

Al aprobar este spec se pasa al **plan** (`docs/superpowers/plans/2026-06-02-m3a-memory-service-docker.md`), descomponiendo en tareas TDD para `subagent-driven-development`. El plan cubrirá:

1. Scaffold `memory-service/` package + Dockerfile + handler skeleton (build verde, healthz OK).
2. Embedder Python container + smoke test.
3. Docker Compose + auth bearer + persistencia en volumen.
4. Migrar `MemoryCore` (store/retriever/engine/decay) al package y verificar tests originales.
5. Endpoints transcript + window.
6. Endpoints memory (recall/save/forget/expand).
7. Endpoints consolidación + scheduler.
8. Endpoints inspector + healthz/readyz.
9. `MemoryClient` Swift en el app macOS + refactor de las 4 tools + `MemoryToolbox`.
10. Refactor de `HarnessModel.ensureMemory`/`runAgentTurn` + `MemoryView` HTTP-based.
11. Borrado del Memory layer in-process del app + tests asociados.
12. Settings UI (URL + token).
13. E2E gated `GEMMA_LIVE_DOCKER=1` + verificación calidad recall contra 26B.
14. graphify update + cleanup.
