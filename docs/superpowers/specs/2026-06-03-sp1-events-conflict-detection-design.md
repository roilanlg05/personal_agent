# SP1 — Eventos fechados + detección de conflictos

- **Fecha:** 2026-06-03
- **Estado:** Diseño aprobado (pendiente revisión final del usuario)
- **Repos afectados:** `gemma-memory` (engine/schema/endpoints) + `personal_agent` (tools/loop del agente)
- **Sub-proyecto:** SP1 de una descomposición mayor (ver _Roadmap_ al final)

## 1. Contexto y problema

Diagnóstico de la interacción real del usuario con el agente Gemma (transcript de 81 turnos vs nodos de memoria) reveló que el agente trata la memoria como notas sueltas, no como un modelo estructurado de la agenda. SP1 ataca los fallos de agenda:

- **Fallo 2 — eventos sin fecha estructurada / fragmentados.** La hora vivía en prosa ("at 3pm"); no había hora de fin ni rango. El "mechanic appointment" quedó en 3 nodos, ninguno con fecha.
- **Fallo 4 — sin detección de conflictos (queja principal).** El agente agendó una reunión en Miami el 9-jun durante un viaje a Cuba del 8-jun. El usuario: _"this cannot happen again… you are here to help me organize my schedule not to get me in troubles."_
- **Fallo 5 — el viaje quedó como `fact`, no como evento con rango** → invisible a cualquier consulta de agenda, por lo que el choque del fallo 4 era indetectable.

Causa transversal: la consolidación estuvo rota durante esas charlas (modelo inalcanzable desde el i3; corregido aparte en `fix/mlx-bind-host-lan`). Pero además faltan piezas de diseño que SP1 provee.

## 2. Objetivos / No-objetivos

**Objetivos**
- Eventos como entidad de primera clase con tiempo estructurado (`start`/`end`).
- Detección de conflictos **híbrida**: cálculo determinista de solapamiento de tiempo (servidor) + capa de sentido común del modelo (ubicación/viaje) encima.
- Flujo conversacional de agendado: acusar recibo → chequear → si cabe crear / si choca explicar y preguntar.
- Clarificación de datos faltantes (hora de fin, rangos difusos) en vez de asumir.
- Enumeración de agenda por ventana de tiempo (determinista).
- Soft-cancel (conserva el evento como `cancelled`) y operaciones sobre ventanas.
- `consolidate()` emite eventos estructurados (captura asíncrona).
- Migración de los nodos actuales (viaje, mecánico, citas) al nuevo modelo.

**No-objetivos (van al Roadmap)**
- **Wake schedule rico** (hora recurrente + overrides por día + comandos) → **SP5**. SP1 solo usa una _hora de despertar simple_ (un valor persistido) para resolver "resto de la noche".
- **Actuación de alarma** (que suene / voz "Hey Gemma te despierta") → M3d.
- **Envío de avisos/correos** al cancelar → futuro (M3c). SP1 solo deja la data lista (soft-cancel).
- **Recurrencia de eventos** (ej. "standup cada día") y **excepciones** → futuro.
- **Sync a calendario / EventKit** → M3c. SP1 mantiene `event` limpio (start/end/location/title) para que el mapeo futuro sea directo.
- Identidad self (SP2), enumeración mejorada vía recall (SP3 se apoya en el hub de eventos de SP1), dedup de insights (SP4).

## 3. Modelo de datos

**Nuevo `NodeKind.event`** — separado de `task`:
- `task` = to-dos accionables sin hora fija (lavar ropa, llamar a mamá, ir al gym).
- `event` = con tiempo: reuniones, viajes, citas. Estos sincronizarán al calendario en M3c.

Campos del `event` (estructurados en el `extra` JSON del nodo; sin migración de esquema GRDB):

| Campo | Tipo | Notas |
|---|---|---|
| `kind` | `"event"` | nuevo NodeKind |
| `label` | string | título ("dentist appointment", "Varadero trip") |
| `start` | epoch (segundos UTC) | **requerido** |
| `end` | epoch (segundos UTC) | **requerido**; si falta, el agente lo clarifica antes de crear |
| `allDay` | bool | opcional (viaje sin hora puntual) |
| `location` | string? | alimenta la capa de sentido común del modelo |
| `status` | `"scheduled"` \| `"cancelled"` \| `"done"` | soft-cancel = `cancelled`, se conserva |
| `canonicalKey` | string | `hash(yyyy-mm-dd + hora-inicio-redondeada-min + tipo)`; colapsa "10am"/"10:00" y evita duplicados |
| `origin` | `"user"` \| `"extracted"` | creado por el usuario vs inferido por `consolidate()` |
| `body` | string | prosa legible |

**Tiempo / zona horaria:** se almacena epoch (UTC). La _resolución_ de expresiones ("3pm mañana") la hace el agente en hora local usando `CurrentTimeTool`, y pasa epoch al servidor. El servidor nunca interpreta lenguaje natural de tiempo.

**Rango multi-día:** un viaje es un `event` con `start`/`end` abarcando días (Varadero: 8-jun 00:00 → 13-jun 00:00, `allDay=true`).

**Dedup por `canonicalKey`:** en `create`, si existe un evento `scheduled` con la misma clave → se actualiza/funde en vez de duplicar.

**Hora de despertar (simple, interino):** un valor persistido (default `06:00`, settings del servicio o un nodo de config), cambiable con "despiértame a las X a partir de ahora". Solo se usa para resolver "resto de la noche" = hasta la próxima hora de despertar. El comportamiento rico es SP5.

## 4. API del servicio (gemma-memory)

Cuatro endpoints bajo `/v1/schedule` (Bearer auth, como el resto):

| Endpoint | Entrada | Salida | Notas |
|---|---|---|---|
| `POST /v1/schedule/check` | `{start, end}` | `{conflicts:[event…]}` | **read-only**; calcula solapamientos contra eventos `scheduled` |
| `POST /v1/schedule/create` | `{title, start, end, allDay?, location?, origin, force?}` | `{created:bool, id?, conflicts:[event…]}` | `force=false` + choques → **NO escribe**, devuelve conflictos. `force=true` → escribe igual. Dedup por `canonicalKey` |
| `GET /v1/schedule/window` | `?from&to&includeCancelled?` | `{events:[event…]}` (orden por `start`) | enumeración de agenda |
| `POST /v1/schedule/cancel` | `{ids:[…]}` **o** `{from, to, filter?}` | `{cancelled:int}` | soft-cancel → `status=cancelled` (conserva) |

**Regla de solapamiento determinista** (en `MemoryStore`): dos eventos `[s1,e1)` y `[s2,e2)` chocan sii `s1 < e2 ∧ s2 < e1`, solo entre `status=scheduled`. `allDay` abarca el/los día(s) completo(s) en hora local. El cálculo nunca depende del modelo → testeable y reproducible.

**Degradación:** si el servicio está caído, los tools del agente devuelven error suave (igual que `recall` hoy) y el agente lo dice en vez de crashear.

## 5. Lado del agente (personal_agent)

**Tools nuevos** (verbos discretos — un tool por acción, el modelo elige uno por paso):
- `check_schedule(start, end)` → conflictos (read-only)
- `create_event(title, start, end, allDay?, location?, force?)` → creado / conflictos
- `query_schedule(from, to)` → eventos en la ventana
- `cancel_events(ids? | from, to)` → soft-cancel, devuelve cuántos

Implementados sobre `MemoryClient` (HTTP), registrados en el `ToolRegistry` junto a los existentes (`CurrentTimeTool`, `SaveMemoryTool`, etc.).

**Flujo conversacional** (system-prompt + tools):
1. Pides agendar → el agente **acusa recibo natural** ("dale, déjame revisar tu agenda").
2. **Clarifica antes de crear** si falta info: solo inicio ("3pm") → pregunta hora de fin; rango difuso ("resto de la semana") → pregunta desde cuándo.
3. **Resuelve relativos** con `CurrentTimeTool` (ahora) + hora-de-despertar simple → "resto de la noche" = hasta esa hora.
4. Llama `check_schedule`.
5. **Si hay choque → capa híbrida:** el modelo recibe los conflictos deterministas y les pone sentido común ("esos días estás en Varadero, en Cuba") → explica y **pregunta** (reagendar / cancelar el otro / agendar igual con `force`).
6. **Si no hay choque →** `create_event` → confirma.
7. "Cancela las citas pendientes de esta semana" → `query_schedule` → `cancel_events` (soft).

**Reglas del system-prompt:** siempre `check_schedule` antes de `create_event`; clarificar fin/rango ambiguo y nunca asumir; cancelar = soft-cancel, no borrar; tono conversacional para no perder detalles.

**Garantía clave:** el chequeo determinista asegura que **nunca se pierda un solapamiento de tiempo**; el modelo solo añade razonamiento encima, no es el guardián.

## 6. `consolidate()` — captura asíncrona de eventos

La fase `consolidate()` del engine se actualiza para que, cuando extraiga algo con tiempo, emita un `event` estructurado (con `start`/`end`/`canonicalKey`) en vez de un `task`/`fact` con la fecha en prosa. Reusa la misma representación y la dedup por `canonicalKey`, de modo que un evento creado en vivo por el tool y el mismo mencionado de pasada no se dupliquen.

## 7. Migración de datos existentes

Script/rutina idempotente (one-off) contra la DB del i3:
- `fact | Varadero trip` → `event` con `start=2026-06-08`, `end=2026-06-13`, `allDay=true`, `location="Varadero, Cuba"`.
- `task | appointment` (3pm 03-jun) y `task | dentist appointment` (10am 04-jun) → `event` con `start`/`end` (asumir 1h si no hay fin; marcar para confirmar con el usuario).
- `task|mechanic appointment` + `fact|mechanic appointment` + `follow_up` → fundir en un `event` (pedir fecha/hora al usuario, hoy falta).
- Recalcular `canonicalKey` y deduplicar.

## 8. Casos borde y manejo de errores

- **Falta hora de fin:** el agente clarifica; no se asume salvo expresión explícita ("resto de la noche/semana", que se resuelve por reglas).
- **Rango difuso ("resto de la semana"):** clarificar el inicio (ahora vs mañana).
- **`allDay`:** el solapamiento usa el/los día(s) completo(s) en hora local.
- **`force`:** crear pese a choque solo si el usuario lo pide explícito.
- **Soft-cancel:** `cancelled` se conserva y se excluye de `check`/overlap por default; visible en `window?includeCancelled=true`.
- **Colisión de `canonicalKey`:** update/merge, no duplicar.
- **Servicio caído:** error suave + mensaje del agente.
- **Zona horaria:** epoch UTC en almacenamiento; resolución/visualización en hora local del agente.

## 9. Estrategia de pruebas (TDD)

- **Unit (MemoryCore):** regla de solapamiento (casos: disjuntos, tocándose en el borde `e1==s2` = NO choca, anidados, idénticos, `allDay` vs timed, cancelled excluido). `canonicalKey` (colapsa "10am"/"10:00"/"10:00 a.m."). Dedup en `create`.
- **Endpoint (MemoryService):** `check`/`create` (force on/off)/`window`/`cancel` (por ids y por ventana). Auth. Degradación.
- **`consolidate()`:** emite `event` estructurado con `start`/`end` desde un transcript con fecha relativa resuelta.
- **Agente (personal_agent):** los 4 tools sobre `MemoryClient` (con URLProtocol mock). Flujo: clarifica hora de fin faltante; chequea antes de crear; en choque no crea sin `force`.
- **Migración:** idempotente; correr 2x no duplica.

## 10. Roadmap (después de SP1)

- **SP5 — Wake schedule:** hora recurrente + overrides por día (saltar / hora distinta) + comandos conversacionales con clarificación. Encaja con M3d (voz/alarma) para la actuación real.
- **SP3 — Enumeración fiable de agenda** (se apoya en `query_schedule`/hub de eventos de SP1).
- **SP2 — Identidad self** (usuario ≠ `person`).
- **SP4 — Dedup/compress de insights.**
- **M3c:** sync a calendario (EventKit), envío de avisos/correos al cancelar.
- **M3d:** actuación de alarma (que suene / voz).
- **Futuro:** recurrencia de eventos + excepciones.

## 11. Decisiones registradas

- Detección de conflictos: **híbrida** (determinista + capa de sentido común del modelo).
- En conflicto: **conversacional** — acusar recibo, chequear, y si choca explicar y preguntar (no rechazar de entrada, no agendar a ciegas).
- `event` es un **NodeKind separado** de `task`.
- Wake schedule rico **diferido a SP5**; SP1 usa hora-de-despertar simple.
- Alarma y avisos/correos **diferidos** (M3d / M3c).
