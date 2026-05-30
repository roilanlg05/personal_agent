# macOS + MLX — M0 limpieza + M1 slice vertical — Diseño

> **Padre/contexto:** pivote iOS→macOS+MLX (memoria `[[macos-mlx-pivot]]`). Reemplaza el runtime on-device (LiteRT-LM) por un **servidor local `mlx-lm`** corriendo **Gemma 4 26B MoE A4B 4-bit** (spike verificado: 15GB RAM, ~17.6 tok/s, tool-calling OK en M4 24GB). La app pasa a ser **SwiftUI/AppKit (UI + tool-loop cliente) ↔ HTTP ↔ mlx-lm**.
> **Fecha:** 2026-05-30. **Repo:** `/Users/hashdown/Projects/personal_agent`, proyecto `Gemma/Gemma.xcodeproj`, branch `main`.

---

## 1. Objetivo y principio rector

Re-plataformar Gemma a macOS de la **forma más inteligente**: **borrar todo lo de LiteRT-LM** (runtime on-device, ya no se usa) pero **conservar la arquitectura del agente** (orquestación, tool-calling, registro de tools, memoria, harness) como base, des-acoplándola de LiteRT.

**Distinción central:** el **acoplamiento a LiteRT** se elimina; la **lógica del agente** se queda. Hoy esa lógica está atada al `Tool`/`@ToolParam` de LiteRT — así que des-acoplar = introducir una **abstracción `AgentTool` propia** que reemplace al `Tool` de LiteRT. Las tools conservan su `run()`; solo cambian de protocolo. (Bonus: una abstracción propia es lo que necesitamos para mapear tools → schema JSON del API estilo OpenAI de mlx-lm.)

Se entrega en dos pasos: **M0** (limpieza + des-acople, deja el proyecto compilando como app macOS sin LiteRT) y **M1** (slice vertical: la app habla con Gemma vía el server, ejecuta una tool, y recuerda entre turnos).

## 2. Decisiones (brainstorm 2026-05-30)

| Decisión | Elección |
|---|---|
| Plataforma | **macOS nativa** (convertir el target actual; no multiplataforma) |
| Runtime del modelo | **Servidor local `mlx-lm`** (API estilo OpenAI), modelo **Gemma 4 26B MoE A4B 4-bit** |
| Quién levanta el server | **M1: el usuario** lo corre en terminal. La app lo lanzará/gestionará en M2+ (diseño deja el hueco) |
| Tool-loop | **Lado cliente** (la app ejecuta tools locales y reenvía resultados) |
| LiteRT-LM | **BORRAR** (runtime + vendor + infra on-device). No _parked: limpieza real en M0 |
| Abstracción de tools | **`AgentTool` propio** reemplaza el `Tool`/`@ToolParam` de LiteRT |
| Formato tool-call | **Verificar primero** con `curl` al server; rama A (server normaliza a `tool_calls` JSON) o rama B (parser nativo de Gemma) según evidencia |
| Captura de memoria | **La actual** en M1 (rediseño v2 → M2). La capa `Memory/` se reusa sin cambios |
| Éxito M1 | Chat con Gemma + `get_current_time` ejecutado + **recall** de un dato entre turnos |

## 3. M0 — Limpieza + des-acople

### 3.1 Borrar (solo LiteRT / on-device)
- `Gemma/Gemma/Runtime/LiteRTLMRuntime.swift`, `Runtime/MultimodalBackends.swift`.
- `vendor/LiteRT-LM/` + su `XCLocalSwiftPackageReference` y product dependency en `project.pbxproj`; quitar `OTHER_LDFLAGS=-all_load` (era para LiteRT).
- `Gemma/Gemma/Models/*` (catálogo/descarga/installed/RAM-gate — sin modelo local no aplican), `Bench/*`, `Runtime/PerfBenchmarker.swift`.
- Vistas on-device: `Harness/BenchmarkView.swift`, `BenchmarkModel.swift`, `CatalogView.swift`, `DownloadProgress.swift`, `ImagePickerView.swift`.
- Tests muertos: `LiteRTLMRuntimeTests`, `MultimodalBackendsTests`, `Bench*Tests`, `ModelCatalog/Descriptor/Downloader Tests`, `InstalledModelsTests`, `DeviceCapabilityTests`, `PerfBenchmarker`/`MemoryReporter` tests si quedan sin sujeto.
- `RuntimeFactory.swift` se simplifica (sin kinds de LiteRT).

### 3.2 Conservar + des-acoplar (base del agente)
- **`AgentTool` nuevo** (`Agent/AgentTool.swift`): protocolo propio — `static name`, `static description`, declaración de parámetros → **JSON Schema**, `run(args) async -> String`. Reemplaza `Tool`/`@ToolParam` de LiteRT. (Params: un modelo simple `[AgentToolParam]` o un dict tipado; sin la macro de LiteRT.)
- **Tools** (`CurrentTimeTool`, `RememberTool`, `ForgetTool`): conservan su lógica `run()` y el uso de `MemoryToolbox`/relay; pasan a conformar `AgentTool`. Quitan `import LiteRTLM`.
- **`ToolRegistry`**: `[AgentTool]` en vez de `[Tool]`. Lógica igual.
- **`ToolCallingRuntime` + `ToolActivityRelay`**: firma usa `[AgentTool]`. Sin `import LiteRTLM`.
- **`ModelRuntime`** (protocolo + `GenerationEvent`/`GenerationOptions`/`GenerationResult`/`RuntimeError`): se conserva; quitar `import UIKit`/`UIImage` (M1 es texto; imagen vuelve en M2 con `NSImage` tras un protocolo). `DummyRuntime` se conserva (tests).
- **`Agent/Agent.swift`**: lógica intacta (retrieve→inject→stream→write, RC3/RC5/RC6); quita `import LiteRTLM`, usa `AgentTool`.
- **Toda `Memory/`**: sin cambios.
- **`Harness/HarnessModel.swift`**: conservar lo del agente/memoria; quitar runtime-switching de LiteRT; apuntar a `ServerRuntime`.

### 3.3 Target macOS
Convertir el target `Gemma` a macOS (SDK `macosx`, `IPHONEOS_DEPLOYMENT_TARGET`→`MACOSX_DEPLOYMENT_TARGET`), quitar entitlement `increased-memory-limit` (iOS), añadir **App Sandbox + cliente de red** (para `localhost`). El grupo sincronizado de archivos del proyecto facilita que borrar archivos = salen del target.

**Fin de M0:** el proyecto **compila como app macOS** con `DummyRuntime`, toda la lógica de agente + memoria intacta, **cero referencias a LiteRT**. Tests de agente/memoria verdes.

## 4. M1 — Slice vertical (chat + tool + recall)

### 4.1 `ServerRuntime` (`Runtime/ServerRuntime.swift`)
Conforma `ModelRuntime` + `ToolCallingRuntime`. Cliente HTTP a `http://localhost:<port>/v1/chat/completions` de mlx-lm:
- Construye el body OpenAI (messages + `tools` desde `[AgentTool]`→JSON schema), `stream:true`.
- Lee SSE → emite `GenerationEvent.token`; al detectar tool-call → `.toolCallStarted/Finished`; al cerrar → `.completed`.
- **Paso 1 (verificación, antes de codificar el parser):** `curl` al server con un tool simple y observar la respuesta. **Rama A:** devuelve `tool_calls` JSON OpenAI → mapear directo. **Rama B:** devuelve formato nativo Gemma (`<|tool_call>call:NAME{args}<tool_call|>` + canal `thought`) → `Runtime/GemmaToolCallParser.swift` que extrae el call y **elimina el bloque `thought`** del texto visible. La rama elegida se fija con la evidencia del curl.

### 4.2 Tool-loop cliente
`Agent` ya hace el loop conceptual; con `ServerRuntime` el ciclo es: pedir → si hay tool-call, ejecutar `AgentTool.run` local → reenviar `role:tool` result → repetir hasta respuesta final. (mlx-lm no ejecuta tools; las ejecuta la app — única vía para tools nativas de macOS en M3.)

### 4.3 UI
`Harness/AgentChatView.swift` (SwiftUI macOS): TextField + respuesta en streaming + log de actividad de tools (reusa el patrón de `AgentView`). `HarnessModel` arma `Agent` + `ToolRegistry`(CurrentTime+Remember+Forget) + `MemoryServices`, runtime = `ServerRuntime(baseURL:)`.

### 4.4 Memoria
Capa `Memory/` actual sin cambios; `Agent` inyecta recall (núcleo identity + relevante) y escribe con la captura actual. M1 valida recall en Mac con el 26B.

## 5. Flujo de datos (M1)
`usuario escribe → Agent.retrieve (memoria) → inject systemPrompt → ServerRuntime POST /v1/chat/completions (stream, tools) → SSE tokens → si tool-call: AgentTool.run local → reenvía result → respuesta final → .completed → captura de memoria (actual)`.

## 6. Errores
- Server caído / connection refused → `ServerRuntime` emite `.failed` con mensaje claro ("inicia mlx-lm en localhost:<port>"); la UI lo muestra (en M2 la app lo lanza).
- SSE mal formado / timeout → `.failed`, no crash.
- Tool-call no parseable → loggear, devolver el texto crudo como respuesta (degradación).
- Embedder/memoria como hoy (degradación a FTS+grafo).

## 7. Pruebas
- **Unit (Mac):** `ServerRuntime` con **URLProtocol mock** (SSE fijo) → emite tokens/.completed; `GemmaToolCallParser` con fixtures de ambos formatos (si rama B); `AgentTool`/registry; `Agent` con runtime mock + tool → relays correctos. Memoria ya cubierta.
- **Manual (Mac, server real con 26B):** abrir app → "what time is it?" → ejecuta `get_current_time`, responde la hora; decir "me gusta X", preguntar después → recall. Registrar en `01-s1-runtime-report.md` (o nuevo reporte macOS).

## 8. Fuera de M1 (futuras milestones)
- **M2:** la app **lanza/gestiona** el server mlx-lm (Process API, readiness, shutdown); **rediseño de captura v2** (`docs/superpowers/specs/2026-05-30-s5a-v2-capture-redesign-design.md`); portar resto de vistas + imagen vía `NSImage` tras protocolo.
- **M3:** tools reales de macOS (calendario/recordatorios EventKit, etc.); voz; etc.
- Roadmap (`00-roadmap.md`) se reescribe para macOS por separado (las decisiones iOS — iPhone 16/E4B/LiteRT/server casero i3 — quedan obsoletas).

## 9. TODOs heredados (feedback del usuario, integrar en milestones)
- **M0:** al borrar, **no tocar** lógica de Agent/tool-calling/ToolRegistry/Memory/harness — solo lo de LiteRT/on-device. Verificar tras cada borrado que los tests de agente/memoria siguen verdes.
- **Transversal:** "de la forma más inteligente" → preferir des-acoplar (abstracción propia) sobre parchar; dejar el código base limpio y reutilizable.
- **Doc:** actualizar `00-roadmap.md` y `[[gemma-project-state]]` al cerrar M0/M1 (la identidad del proyecto ya no es iOS).
