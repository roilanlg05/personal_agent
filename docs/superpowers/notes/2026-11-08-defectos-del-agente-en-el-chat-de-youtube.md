# Revisión del chat del 2026-11-08: qué hizo mal el agente con el vídeo de YouTube

El usuario pidió: «Revisa el Chat de la última conversación que tuvimos yo y
[el agente] para que vean los errores que comete. Por ejemplo me cierra el video
o se cierra solo cuando el turno del agente termina […] y a veces repite las
cosas, ¿no es un flujo o un agent Loop correcto?»

El chat es el `threadId 74713F0F-1893-43A3-8CB4-FBC15F8B70AD`, de las 11:18 a las
11:33, leído del servicio de memoria del i3 (`GET /v1/transcript/recent`).

## Primero: una parte del desastre la causé yo

**Yo contaminé su sesión en vivo, y hay que decirlo antes que nada porque cambia
la lectura del chat.** Mientras él usaba el navegador, yo estaba midiendo fps
contra **la misma sesión** del CLI (`--session gemma`): abrí
`youtube.com/watch?v=dQw4w9WgXcQ` («Never Gonna Give You Up») y pulsé `k`.

Por eso, a las 11:19, su agente informa de que «la página terminó mostrando
"Never Gonna Give You Up" de Rick Astley». Ese vídeo no salió de ninguna acción
suya ni del agente: lo abrí yo.

**Consecuencia directa: retiro el hallazgo «`open` devuelve `rc=0` sin
navegar»** que escribí en
`2026-11-08-medicion-fluidez-panel.md`. Lo que medí no fue un fallo de `open`:
fue mi `open` y el de su agente peleándose por un único navegador. Mi `get url`
veía AuronPlay porque su agente acababa de navegar allí.

Es la tercera vez que me equivoco en esta zona del sistema (primero un
diagnóstico falso sobre el fotograma de apertura, después retirar el fenómeno
entero como si fuera un malentendido, y ahora esto). La diferencia es que esta
vez **el síntoma lo produje yo**.

**Lo que sí queda en pie, y sube de categoría:** el navegador es **una sola
sesión compartida sin ningún control de concurrencia**. Dos clientes que la
conduzcan a la vez se corrompen la página mutuamente. Está demostrado
empíricamente — por accidente, pero demostrado. La queja original del usuario
(«le pedí el canal de AuronPlay y me abrió TikTok en el mismo lugar donde estaba
antes») encaja en esta clase. El subsistema A ataca el caso humano-contra-agente;
**no cubre agente-contra-agente**, y debería.

## El chat, entero

| hora | quién | qué |
|---|---|---|
| 11:18:16 | usuario | «entres a YouTube, me busques el canal de AuronPlay y me reproduzcas el último video […] **no cierres el navegador hasta que no termine el video o yo te aviso**» |
| 11:18:16 | agente | «Entendido, dame un momento: el canal ya está abierto […] voy a abrir el más reciente.» + basura de sintaxis. **Turno terminado sin ejecutar nada.** |
| 11:19:12 | usuario | «Qué hiciste? No me reproducís nada» |
| 11:19:12 | agente | Reconoce el fallo. Informa de Rick Astley (era mío) y de haber pulsado `k`. «El navegador sigue abierto, como pediste.» |
| 11:33:12 | usuario | «ya arreglé la herramienta, puedes reproducir […] recuerda que tienes que darle Play al video y Skip al anuncio» |
| 11:33:12 | agente | «Ok, dame un momento: voy a revisar cómo quedó la página para saltar el anuncio y darle play.» **Turno terminado sin ejecutar nada.** |

El patrón que el usuario llama «repite las cosas» es este: **el agente anuncia la
acción y termina el turno sin hacerla.** Dos de los tres turnos acaban en
«dame un momento, voy a…» y ahí se mueren. El usuario tiene que volver a pedirlo,
y el agente vuelve a anunciarlo.

## Defectos, separando lo medido de lo supuesto

### D1 — Sintaxis de llamada a herramienta filtrada a la pantalla del usuario (MEDIDO)

El primer mensaje del agente, crudo:

```
'Entendido, dame un momento: el canal ya está abierto en la pestaña de videos,
así que voy a abrir el más reciente.\n\n\n name="browser_click">\n
name="selector">@e816'
```

Eso es una llamada a herramienta en la forma
`<function name="browser_click"><parameter name="selector">@e816</parameter></function>`,
a la que algún filtro de streaming le comió los `<function` y `<parameter` y
dejó el resto como prosa visible.

**`GemmaToolCallParser` no conoce ese formato.** Conoce tres
(`Gemma/Gemma/Runtime/GemmaToolCallParser.swift:11-14`):
`call:nombre{args}`, `<execute_tool>`/`<tool_call>`, y
`{"name":…,"arguments":…}`. Un `grep` de `<function` y `<parameter` sobre todo
`Gemma/Gemma` **no devuelve nada**: nadie en el proyecto reconoce esa forma.

### D2 — Un turno sin llamada reconocida termina inmediatamente (MEDIDO)

`Gemma/Gemma/Agent/Agent.swift:257`:

```swift
let isFinal = pendingToolCalls.isEmpty || runtimeFinishedAnyTool
if isFinal { … break loop }
```

Si el parser no reconoció nada, `pendingToolCalls` está vacío, `isFinal` es
cierto y **el bucle rompe en la primera vuelta**. El presupuesto de
`maxBrowserIterations` no llega a usarse nunca: se concede *después* de ejecutar
una herramienta de navegador, y aquí no se ejecuta ninguna. D1 + D2 explican
exactamente los dos turnos que mueren tras anunciar.

Nota de paso: `runtimeFinishedAnyTool` depende de un evento
`.toolCallFinished` que **nadie emite** (solo existe la declaración del `case` en
`ModelRuntime.swift:148` y un consumidor en `HarnessModel.swift:708`). Esa mitad
de la condición está muerta. No es el fallo, pero es código que miente sobre lo
que protege.

### D3 — `browser_close` se ordena sin condición, y gana sobre el usuario (MEDIDO)

Dos sitios:

- `Agent.swift:158` — «Call `browser_close` when done.»
- `Agent.swift:206`, la nota de resultado de herramienta — «When the task IS
  finished, call `browser_close` and then answer the user…»

Y el comentario del propio código, en `Agent.swift:190-192`, dice de esa nota:

> «Es lo ÚLTIMO que el modelo lee antes de decidir qué hacer a continuación, así
> que gana sobre cualquier instrucción del prompt del sistema.»

Gana sobre el prompt del sistema **y sobre el usuario**, porque se añade después
de todo. El usuario escribió, textual: «no cierres el navegador hasta que no
termine el video o yo te aviso», y el sistema le ordena cerrar en cuanto la tarea
esté lista. Esto es la queja número uno del usuario: **se cierra el vídeo al
terminar el turno.**

El error de diseño de fondo: `browser_close` se trata como limpieza, cuando para
una tarea cuyo **entregable es un estado que el usuario quiere seguir mirando**
(un vídeo reproduciéndose, una página que quiere leer, un carrito que quiere
revisar), cerrar **destruye el entregable**. «Terminar la tarea» y «cerrar el
navegador» no son lo mismo y el prompt los ha fusionado.

### D4 — El agente no sabe arrancar la reproducción (MEDIDO, ya anotado)

Autoplay está bloqueado en ese navegador: una página de vídeo cargada y quieta
emite 2 fotogramas en 10 segundos. Arranca con `press k`. El usuario ya lo dedujo
solo y se lo tuvo que explicar al agente a mano: «recuerda que tienes que darle
Play al video y Skip al anuncio que va a salir antes del video». Nada en el
prompt ni en las herramientas se lo dice. Ver
`2026-11-08-medicion-fluidez-panel.md`.

### Lo que NO está medido, y por tanto no se arregla a ciegas

**Por qué el modelo emitió la llamada como texto en vez de como bloque
`tool_use`.** El camino de Anthropic en `ServerRuntime.swift` sí trata
`content_block_start` con `type == "tool_use"` y `input_json_delta`
(líneas 174-186), así que *debería* llegar estructurada. Hipótesis sin comprobar:
que en esa petición no se enviara el parámetro `tools`; que el modelo decidiera
texto por su cuenta. **No escribo un arreglo para esto sin la causa.** Lo que sí
se puede arreglar sin saberla es defensivo y correcto en cualquier caso: que el
parser reconozca el formato, y que **ninguna sintaxis de herramienta llegue
jamás a la pantalla del usuario** — eso último es un fallo por sí mismo,
independientemente de por qué el modelo la emitió.

## Orden de arreglo propuesto

1. **D3**, el cierre. Es el que más le molesta, es una edición de prompt y no
   tiene incógnitas. Y hay un requisito de diseño que sacar de aquí: una
   instrucción explícita del usuario sobre el navegador («no lo cierres») tiene
   que sobrevivir a la nota de resultado de herramienta.
2. **D1**, el formato + el filtro de pantalla. Dos cambios: añadir la forma al
   parser con sus pruebas, y una red de seguridad que impida que cualquier cosa
   con pinta de sintaxis de herramienta se muestre al usuario.
3. **D2**, la condición muerta y el presupuesto de vueltas. Con D1 arreglado el
   síntoma se va, pero `isFinal` sigue dependiendo de un evento que nadie emite
   y eso hay que limpiarlo o justificarlo.
4. **D4**, enseñarle a darle Play.
5. **La concurrencia del navegador** (ver arriba): ampliar el subsistema A para
   que dos agentes no se pisen, no solo el humano y el agente.
