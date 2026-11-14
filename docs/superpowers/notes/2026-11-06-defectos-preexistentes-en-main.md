# Defectos preexistentes en `main`, descubiertos al cerrar `feat/agent-browser`

**Fecha:** 2026-11-06
**Origen:** cierre de la rama `feat/agent-browser` (integración de Agent Browser).
Ninguno de estos defectos lo causa esa rama, y ninguno se arregla en ella: están
fuera de su alcance. Se registran aquí para que no se pierdan al borrar el
workspace de trabajo de la rama, que es scratch git-ignored.

---

## (A) `main` reintrodujo la instrucción `save_memory` en el prompt del turno vivo

**Estado:** test rojo en `main`, y un problema de arquitectura detrás del test.

### El síntoma

```
Test case 'AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction()' failed
```

### La contradicción

`Gemma/Gemma/Agent/Agent.swift:103` ordena al modelo:

> When the user mentions important facts, plans, names of institutions/banks,
> locations/cities, phone numbers, relationships, preferences, or critical
> details […], PROACTIVELY call `save_memory(entity: ..., detail: ..., kind: ...)`
> to save them immediately in that turn! Never let critical details go
> unrecorded.

La cabecera de documentación del mismo fichero, línea 16, afirma lo contrario:

> The live turn does NOT write memory (no save_memory) — capture is deferred to
> consolidation.

El repo sostiene hoy las dos cosas a la vez.

### La historia

`git log -S "save_memory" -- Gemma/Gemma/Agent/Agent.swift`:

| Commit | Qué hizo |
|---|---|
| `0fcb99b` | `feat(sp1-agent)`: metió reglas conversacionales de agenda en el prompt |
| `428e244` | `fix(sp1-agent)`: **quitó** `save_memory` del prompt, calificándolo de regresión de forma explícita |
| `e2f9e86` | `feat(tools)`: contrato de honestidad en las 71 herramientas nativas — **volvió a meterlo**. Está en `main` (2.º commit) |

El test `test_system_prompt_has_no_save_memory_instruction` se escribió
precisamente para vigilar que `428e244` no se revirtiera. `e2f9e86` lo rompió,
y lleva rojo desde entonces.

### Por qué importa más allá del test

La arquitectura de memoria de este proyecto difiere la escritura a la
consolidación a propósito: el pipeline `embed → cluster → tag → reflect →
compress → curate → rem → clarify → shy` es lo que convierte observaciones
crudas en nodos con tags, provenance e identidad emergente. Un turno vivo que
llama a `save_memory` escribe nodos por un lateral, sin pasar por ese pipeline,
y compite con él. Es exactamente el fallo que `428e244` ya corrigió una vez.

### Arreglo propuesto

Decidir cuál de las dos intenciones gana y hacer que prompt, cabecera y test
digan lo mismo:

- **Si gana la cabecera** (escritura diferida a consolidación): borrar la línea
  103 del prompt. El test vuelve a verde solo.
- **Si gana la línea 103** (captura proactiva en el turno): borrar el test,
  actualizar la cabecera de la línea 16, y revisar qué pasa cuando el turno vivo
  y la consolidación escriben el mismo hecho — ¿lo deduplica `upsert`, o quedan
  dos nodos?

Lo que no puede quedarse es el repo afirmando las dos cosas.

---

## (B) `CLIShortcutRunner.runProcess` puede colgarse sin plazo

**Fichero:** `Gemma/Gemma/NativeServices/ShortcutRunner.swift:282-320`
**Estado:** código en producción. Timeout nominal de 60 s que no acota todos los
caminos.

### Los tres fallos

1. **La recogida de salida queda fuera del plazo.** Las líneas 297-298 arrancan
   la lectura en hilos aparte:

   ```swift
   let outData = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
   let errData = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }
   ```

   y las líneas 317-318 las esperan **después** de que el plazo ya se declaró
   cumplido:

   ```swift
   let out = String(data: await outData.value, encoding: .utf8) ?? ""
   ```

   `readDataToEndOfFile` solo vuelve cuando se cierran **todos** los extremos de
   escritura de la tubería. Si `shortcuts run` deja un ayudante o un demonio con
   las tuberías heredadas, el EOF no llega nunca aunque el hijo directo ya haya
   salido: el `await` se cuelga **sin límite**, con los 60 s ya consumidos y
   declarados cumplidos.

2. **Al vencer el plazo se manda SIGTERM y nada más.** Línea 313:

   ```swift
   guard finishedInTime else {
       process.terminate()
       return nil
   }
   ```

   `terminate()` es SIGTERM. Un hijo que lo ignore sigue vivo, y con él los dos
   hilos bloqueados en `readDataToEndOfFile`, que nunca se cancelan. No hay
   escalada a SIGKILL.

3. **El `withTaskGroup` espera la muerte del hijo para decidir.** Línea 300: una
   de las dos ramas es `await Self.waitForExit(process)`. Si el hijo no muere, la
   decisión depende de que gane la rama del `Task.sleep`, y el camino de limpieza
   posterior sigue atado al hijo.

### El arreglo ya está escrito en esta misma rama

`Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift`, método estático `run`
(comentario en las líneas 245-251, cuerpo debajo), resuelve los tres:

- **`readabilityHandler` + `PipeCollector`** en vez de `readDataToEndOfFile`: la
  salida se acumula a medida que llega y no depende del EOF. Tras la salida del
  hijo se espera `drainGrace` por si queda cola, y se devuelve lo recogido.
- **`.timedOut` en el instante del vencimiento**, sin esperar a la muerte del
  hijo.
- **SIGTERM y, si sigue vivo tras `killGrace`, SIGKILL.**

Portar ese patrón a `CLIShortcutRunner.runProcess` es una rama pequeña, con el
diseño ya validado y 15 tests de referencia en `AgentBrowserInvokerTests`.

---

## (C) Los snapshots fechados de graphify contradicen el `.gitignore`

No es un defecto de código; es una trampa de repo que ya costó un `filter-branch`.

`.gitignore:16` dice que hay que **conservar** los snapshots fechados:

```
# Keep the indexed outputs: GRAPH_REPORT.md, graph.json, manifest.json, .graphify_labels.json, dated snapshots.
```

`.gitignore:27-28` ignora uno concreto porque su `graph.json` pesaba 119 MB y el
pre-receive hook de GitHub rechazó el push:

```
# graphify dated snapshots can exceed GitHub 100MB — do not commit the generated graph.json blobs
graphify-out/2026-06-04/
```

Hoy hay cuatro snapshots sin seguir: `2026-06-08`, `2026-11-04`, `2026-11-05`,
`2026-11-06`. El de hoy pesa 14 MB (`graph.json`, 13 MB), por debajo del límite,
pero crece con el repo.

**Decisión pendiente del dueño del repo**, no del controlador de una rama:

- **Opción 1:** ignorar todos los snapshots fechados por patrón
  (`graphify-out/20??-??-??/`) y corregir el comentario de la línea 16. Los
  outputs vivos (`graph.json`, `GRAPH_REPORT.md`, `manifest.json`,
  `.graphify_labels.json`) se siguen conservando, que es lo que el agente
  consulta.
- **Opción 2:** conservarlos y vigilar el tamaño antes de cada push.

**Regla que sigue en pie mientras no se decida:** nunca `git add -A` en este
repo. Siempre rutas explícitas.

### Nota correctiva sobre el grafo

El grafo de conocimiento **sí** se actualizó en la rama. El commit `8645da4`
(«chore(graph): actualizar el grafo de conocimiento tras las herramientas de
navegador») corre `graphify update .` y commitea `graph.json`,
`GRAPH_REPORT.md`, `manifest.json` y `.graphify_labels.json`. Lo que no se
commitea es el snapshot fechado, que es un artefacto distinto.

---

## Deuda menor registrada en el cierre de `feat/agent-browser`

Dos Minors de la re-revisión se parkearon con razón. Quedan aquí por si la
próxima rama toca ese fichero:

1. **`ResolutionMemo` no tiene reloj inyectable.** La caducidad del negativo a
   los 60 s (`AgentBrowserInvoker.swift:131` y `:150`) no se puede probar sin
   dormir 60 s o inyectar un reloj. Inyectarlo y probar la expiración es la
   mejora correcta; se dejó fuera por estar al cierre de una rama ya revisada.
2. **`forget()` solo ayuda a la llamada siguiente.** Tras una desinstalación en
   caliente, la primera llamada devuelve `launchFailed` (opaco) en vez de
   `binaryNotFound` (accionable); la segunda acierta. Se decidió NO arreglarlo:
   reinterpretar todo `launchFailed` como «binario ausente» produciría un
   diagnóstico seguro de sí mismo y falso cuando la causa real sea permisos,
   sandbox o recursos. Un mensaje opaco pero honesto es preferible a uno
   confiado y equivocado.

---

## RETIRADO: «el panel enseña la página del turno anterior» (2026-11-08)

Escribí aquí un diagnóstico entero sobre el fotograma de apertura del demonio, a
partir de un reporte del usuario que **interpreté mal**. Él lo corrigió: cuando el
navegador falló **no se mostró nada**, así que el fotograma de apertura no
explica lo que vio y mi explicación se cae.

Lo único que queda en pie de esa medición, porque se midió de verdad contra el
i3, y vale la pena no volver a medirlo:

- **`browser_close` cierra la página de verdad.** Tras el `close`, `get url` da
  `about:blank` y `get title` da vacío.
- Tras el `close`, un `get url` **sigue contestando**: el CLI asegura el navegador
  en cada invocación (es el eco `launch` que `browser/stream.py` descarta en
  `IGNORED_ACTIONS`). El proceso sobrevive; la página, no.
- **Si nadie llama a `close`, la página se queda donde estaba.** Abrir una sesión
  distinta no la toca.
- `AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000` (media hora) en los dos composes. El
  usuario ya decidió en el brainstorming del navegador visible que sean **10
  minutos**: «si no hay ninguna interacción de la gente con el navegador, o mía
  con el agente para que interactúe con el navegador, entonces se cierra a los 15
  minutos automáticamente, o mejor, a los 10 minutos.» Eso sigue pendiente y es
  trabajo del plan D.

**Lección de proceso:** convertí una frase del usuario en un diagnóstico técnico
sin preguntarle qué vio exactamente en la pantalla. El síntoma que él describía y
el que yo expliqué no eran el mismo.
