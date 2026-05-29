# S4 — Núcleo del agente + tool-calling (primer slice) — Diseño

> **Padre:** roadmap `00-roadmap.md` §3 (S4). Cubre el framework de tool-calling (#6 tool chaining, #10 streaming de actividad), el registro extensible de tools (CC2), probado con **1 tool de juguete**. Construye sobre el runtime **LiteRT-LM** estable (S1/S1.1).
> **Fecha:** 2026-05-29. **Device:** iPhone 16, Gemma 4 E4B / LiteRT-LM GPU.

---

## 1. Problema y objetivo

Hoy la app solo hace generación de texto/imagen (`ModelRuntime.generate`). Para que "Gemma" sea un agente necesita **llamar tools** (calendario, maps, web, smart home…) y **encadenarlos**. **LiteRT-LM ya trae tool-calling nativo**: `Tool`/`@ToolParam`/`ToolManager` + el loop de `Conversation` (hasta 25 tool-calls recurrentes). 

**Objetivo (primer slice):** un **núcleo de agente** que exponga un **registro extensible de tools**, corra un turno con tool-calling nativo de LiteRT-LM, y **streamee la actividad** (tokens + "llamando X / listo") a la UI — validado con **un tool de juguete** que confirme que el E4B llama tools de forma fiable end-to-end.

**No-objetivos:** tools iOS reales (calendario/maps/weather/web/smart-home) = **S6**; scratchpad (#20), frases instantáneas/latency (#23/#3 → S12), inyección de memoria (#18 → S5). No se rehace el tool-calling (se usa el nativo).

> Decisión heredada: **tool-calling NATIVO de LiteRT-LM** (no loop propio). Acopla el agente a LiteRT-LM — aceptable (runtime ya elegido); si se migra a otro runtime se re-hace esta capa.

## 2. Arquitectura

- **`Agent/ToolRegistry.swift`** — registro extensible: mantiene los **`Tool` de LiteRT-LM** que escribimos y los entrega como `[Tool]` a la conversación. Sin protocolo propio aparte por ahora (YAGNI); nace para CC2 ("ir agregando capacidades"); S6 registrará los reales. Si más adelante se necesita un seam runtime-agnóstico, se introduce un `AgentTool` encima — no ahora.
- **Tools — conforman el `Tool` de LiteRT-LM** directamente (nombre, descripción, params vía `@ToolParam`, `execute` async). Cada tool se construye con un **emisor de actividad** inyectado (stored property/closure) y su `execute()` reporta `started(name,args)` / `finished(name,result|error)`. Primer tool: **`CurrentTimeTool`** (sin params; devuelve la hora local) — único fin: validar el function-calling del E4B.
- **`Agent/Agent.swift`** — orquesta un turno: arma el system prompt (con instrucciones de tools), toma los tools del registro, llama la generación **tool-aware** del runtime, y relaya un stream de **`AgentEvent`**: `.token(String)`, `.toolCallStarted(name, args)`, `.toolCallFinished(name, result)`, `.completed(GenerationResult)`, `.failed(String)`. Es el "seam" donde luego viven scratchpad/memoria/latency (no ahora).
- **Runtime tool-aware:** `ModelRuntime.generate` gana parámetro `tools: [Tool]` (default `[]`); `GenerationEvent` gana `.toolCallStarted(name:args:)` y `.toolCallFinished(name:result:)`. `LiteRTLMRuntime` lo implementa creando la `Conversation` con `ConversationConfig(tools:)` y usando `sendMessageStream` (que ya corre el loop). Los eventos de tool salen porque **nuestros** `execute()` los emiten al continuation del stream. `DummyRuntime` ignora `tools` (stub) para no romper su path.
- **`Harness/AgentView.swift`** (o sección en el harness) — muestra el `AgentEvent` stream: tokens + chips "🔧 CurrentTime… ✓".

## 3. Flujo de datos, errores

**Turno:** `prompt → Agent (system prompt + tools del registro) → runtime.generate(prompt, tools, options) → Conversation(tools).sendMessageStream → [loop: tokens + ejecuta nuestros Tools → emiten actividad] → AsyncThrowingStream<GenerationEvent> unificado → Agent → AgentEvent → UI`.

**Errores:** error en `execute()` → `.toolCallFinished(error)` y el resultado-error se re-alimenta al modelo (puede recuperarse/reportar); `recurringToolCallLimit (25)` excedido → `Conversation` lanza → runtime `generationFailed` → `Agent.failed`; **el E4B no llama el tool** (riesgo del modelo chico) → el slice lo mide; mitigación = system prompt de tools claro + medir tasa de acierto.

## 4. Pruebas

- **Unit (Mac, simulador):** `ToolRegistry` (register/list, produce `[Tool]`); schema/params de `CurrentTimeTool`; lógica pura de `CurrentTimeTool.execute` (devuelve hora formateada); `Agent` con un **runtime stub** que emite una secuencia fija → asevera que relaya `.token`/`.toolCallStarted`/`.toolCallFinished`/`.completed` en orden y mapea a `AgentEvent`; `DummyRuntime.generate(tools:)` ignora tools sin romper.
- **Device-only (skip-gated, modelo instalado):** E2E con el E4B — `Agent` con `CurrentTimeTool` registrado, prompt "¿qué hora es?" → asevera que hubo un `.toolCallStarted("CurrentTime"…)` y que el texto final incluye una hora. **Valida la fiabilidad del function-calling del E4B** (el riesgo central de S4).
- Tras tocar código: `graphify update .`.

## 5. Riesgos

- **Fiabilidad de function-calling con E4B** (riesgo #1): el modelo chico puede no emitir `tool_calls` bien formados o no llamar el tool. El slice lo mide; si es bajo, iterar el system prompt de tools (formato/ejemplos) antes de construir tools reales (S6). Si resultara inviable, reconsiderar (prompt-engineering reforzado / few-shot).
- **Acoplamiento a LiteRT-LM** (aceptado): la capa de tool-calling usa la `Conversation`/`Tool` de LiteRT-LM.
- **Streaming de actividad fino**: el loop es interno a `Conversation`; la actividad de tools sale por nuestros `execute()` (suficiente para "llamando X…"); no hay visibilidad del razonamiento interno más allá de tokens + hooks de tools.
- **Concurrencia/@MainActor**: `LiteRTLMRuntime` es `@MainActor` (afinidad GPU); el emisor de actividad debe respetar esa isolation.

## 6. Entregables

1. Runtime tool-aware: `ModelRuntime.generate(..., tools:)` + casos `.toolCallStarted/.toolCallFinished` en `GenerationEvent`; impl en `LiteRTLMRuntime` (Conversation con tools); `DummyRuntime` stub.
2. `Agent/ToolRegistry.swift` (registro extensible) + bridge a `[Tool]`.
3. `CurrentTimeTool` (tool de juguete con emisor de actividad).
4. `Agent/Agent.swift` (orquesta turno + `AgentEvent` stream).
5. `Harness/AgentView` mostrando la actividad.
6. Tests unit (Mac) + device-only E2E (E4B llama el tool) + `graphify update`.
