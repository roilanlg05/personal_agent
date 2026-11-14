# Tarea 3 — El historial del turno es la prosa del modelo, no su JSON

Rama `diag/panel-se-muere`, base `dd9059c`. Informe de la tarea 3 del plan
`2026-11-08-bucle-de-navegacion` (contraste con browser-use).

- Paso 0 (deuda de la base de pruebas): commit `4751d74`.
- Tarea 3: commit al final de este informe.

---

## Paso 0: la línea base baja de 7 a 5

Antes: 7 fallos. Después: 5. Los dos que caen son los de `ToolJSONEscapingTests`,
y en los dos casos **la razón la tenía la herramienta, no la prueba**.

### `test_search_contacts_output_is_valid_json`

La prueba exigía `status: "ok"`. Ningún camino de `SearchContactsTool` ha emitido
nunca `ok`: el de éxito emite `found`, que es además lo que la propia descripción
de la herramienta documenta al modelo (`SearchContactsTool.swift:20`: «Lee
'status': 'found' = hay resultados en 'contacts'») y lo que ya clava
`SearchContactsToolTests.test_encuentra_contactos_y_lo_dice_como_found`. Es una
prueba vieja, escrita contra un contrato anterior.

Arreglo: la aserción apunta a `found`, y se le añaden el `count` y el `nickname`
(que lleva sus propias comillas) para que la prueba siga midiendo escapado y no
solo un literal de estado.

### `test_search_contacts_error_output_is_valid_json`

La prueba exigía una clave `error` sobre un error con código 403. Ese camino dejó
de emitirla cuando el tool separó «no pude mirar la libreta» de «miré y no hay»:

- con 403 devuelve `permission_required` + un `message` que explica qué hacer, y
  **sin** `error` (el texto del sistema no aporta nada ahí);
- con cualquier otro fallo devuelve `failed` + `error` con la descripción entera.

Arreglo: la prueba recorre **los dos** caminos y afirma de cada uno las claves que
emite hoy, incluida la ausencia de `error` en el de permiso.

### Lo que NO se perdió

La clase se llama «escaping» porque lo que protege es que un texto con comillas,
barra invertida, salto de línea y tabulador sobreviva el viaje de ida y vuelta por
el JSON. Ese caso se conserva **donde se puede ejercitar de verdad**: el motivo
difícil (`Permiso "denegado"\npara contactos\tya`) viaja por el camino de `failed`,
que es el único que propaga la descripción del error, y se exige que vuelva
idéntico tanto en `error` como dentro del `message`. En el camino de 403, que no
propaga el motivo, el texto difícil se mete en la **consulta** (`searched_query`)
para que el escapado siga teniendo algo que hacer. Si se hubiera dejado el 403
como único caso, la aserción de escapado habría quedado vacía: ese camino no
contiene el texto del error en ninguna clave.

### Mutaciones del paso 0 (suite entera)

| Mutación | Pruebas rojas |
| --- | --- |
| `"status": "found"` → `"ok"` en `SearchContactsTool` | `ToolJSONEscapingTests.test_search_contacts_output_is_valid_json` + `SearchContactsToolTests` ×3 (`test_encuentra_contactos_y_lo_dice_como_found`, `test_recorta_la_lista_para_no_volcar_la_libreta_entera`, `test_resuelve_el_alias_antes_de_buscar`) |
| borrada la línea `"error": nsError.localizedDescription` del camino `failed` | `ToolJSONEscapingTests.test_search_contacts_error_output_is_valid_json` (y solo ella) |

A partir de aquí la línea base es **5** y la tarea 3 se mide contra 5.

---

## Qué se arregla de verdad

No es el recorte, y no es ahorro de tokens. Es que **releer sus propias llamadas a
herramienta le enseña al modelo a repetirlas**. La nota de resultado decía:

```
[You called the tool `browser_click` with arguments {"selector":"@e5"}; it returned: …
```

y el prompt vivo era acumulativo (`resultsNote += …`), así que el JSON que el
modelo acababa de emitir volvía a su propio prompt en la ronda siguiente, y de ahí
a la siguiente. En este proyecto eso no es una teoría: el modelo llegó a escribir
la sintaxis de llamada **como texto visible en la respuesta al usuario**, y
arreglar ese defecto costó una rama entera (`ToolSyntaxStreamGate`).

browser-use reconstruye **un solo mensaje por paso** y el modelo nunca ve su propio
JSON anterior: ve su propia prosa. Eso es lo que se trae.

---

## Las tres decisiones

### 1. Qué es «la prosa del modelo»

**Decisión:** la prosa es el `text` del `.completed` de la ronda, recortado de
espacios, envuelto en `[You then wrote: …]` (`Agent.modelProseNote`). Se conserva
**entera y sin filtrar por contenido**.

**Por qué ese texto y no otro:** para el camino de servidor, el `text` del
`.completed` es el texto **limpio** — `ToolSyntaxStreamGate` ya retuvo lo que
parecía un inicio de llamada y `GemmaToolCallParser` ya separó las llamadas
codificadas como texto. La frontera entre prosa y sintaxis la decide quien ya
sabía decidirla, y aquí no se vuelve a adivinar nada. Lo que se quita del prompt
es `tc.args`, que es el único trozo de sintaxis de llamada que llegaba a él.

**El borde del encargo, resuelto a favor de la prosa:** si el modelo narra «ahora
voy a llamar a browser_click @e5», eso **es** prosa y se conserva, aunque enseñe lo
mismo que el JSON que se quitó. Es su plan y es lo que le da continuidad entre
rondas; quitarlo sería adivinarle la intención. La prueba
`test_la_prosa_del_modelo_viaja_al_prompt_aunque_narre_la_llamada` está construida
sobre ese borde a propósito: el `@e5` aparece en la prosa **y** en los argumentos,
así que lo único que distingue «se quitó la sintaxis» de «se quitó el contenido»
es que el `@e5` de la prosa siga ahí mientras el `{"selector":"@e5"}` no está.

**Lo que NO entra:** el acuse conversacional de la ronda 0 («Dame un momento…»).
Lo emite el bucle directamente al usuario y nunca fue texto del modelo, así que no
pasa por `modelProseNote`. (Es uno de los frenos que el encargo marcó como
intocables, y sigue intacto.)

**Lo que se pierde al quitar los argumentos, dicho en claro:** el VALOR que el
modelo tecleó en un campo. `browser_fill` devuelve «Campo '@e9' rellenado.» sin el
valor. Se acepta porque se recupera por dos vías mejores: la propia prosa de esa
ronda (que ahora viaja) y el `browser_snapshot` siguiente, que enseña el campo ya
relleno. Todo lo demás que los argumentos decían ya lo dicen los resultados: el
`url` de un `open`, el `@e3` de un `click`, el `@e9` de un `fill`.

### 2. El tope, y qué se recorta al pasarlo

**Decisión:** `Agent.maxHistoryBytes = 3 * (BrowserSnapshotTool.snapshotLimit + 1_000)`
= **27.000 bytes**, en bytes y no en rondas, con granularidad de ronda entera: se
quitan rondas completas empezando por la más vieja, y la más reciente no se quita
nunca (ni aunque ella sola se pase del tope).

**Qué se midió antes de elegirlo:**

| Cosa | Tamaño medido | De dónde |
| --- | --- | --- |
| Resultado de un `browser_snapshot` o un `browser_get` | ≤ **8.000** caracteres | `BrowserSnapshotTool.snapshotLimit`, `BrowserGetTool.contentLimit` (las herramientas ya recortan ahí) |
| Resultado de un `read_webpage` | ≤ 12.000 caracteres | `ReadWebpageTool.contentLimit` |
| Texto fijo de la nota de una herramienta de navegador | **820** bytes | medido sobre `toolResultNote` (incluye `BrowserRules.closeRule`, 413 caracteres) |
| **Una ronda que mira la página** | **≈ 8,8 KB** | 820 + 8.000 |
| Una ronda que actúa (click, fill, press) | ≈ 900 bytes | 820 + un `message` corto |
| Bloque de la guía oficial | ≈ **17,8 KB** | `BrowserRules.text` 1.895 + inventario ≈ 750 + preámbulo 626 + `BrowserCoreSkill.text` 14.459 |
| Historial de un turno de conducción, HOY | **≈ 71 KB** con 8 rondas, y `maxBrowserIterations` permite 10 | sin tope de ninguna clase |

**De dónde sale el número:** el 8.000 es **medido** (es el tope que la herramienta
ya aplica). El **3 es una cota a ojo**, y conviene que se sepa: son las tres
páginas gordas más recientes. La elección tiene un motivo —las `@eN` de un snapshot
anterior a la última navegación ya no valen, que es exactamente lo que dice el
corte de cola (`Agent.cortaLaCola`), así que el valor de una página vieja decae
rápido— pero no hay una medida detrás del 3 en sí. El comentario en el código lo
dice con esas palabras, para que quien quiera moverlo sepa que puede.

**Por qué en bytes y no en rondas, que es lo que el encargo sugería:** porque un
tope por rondas aquí sale inútil o dañino, y las dos opciones se descartan con los
números de arriba. El bucle real de conducción (`open → snapshot → fill → snapshot
→ click → snapshot → get → close`) son ocho rondas, y `maxBrowserIterations` = 10.
Un tope de rondas por encima de 8 no muerde nunca; uno por debajo de 8 le borra al
modelo el principio de su propia conducción. El tamaño, en cambio, es lo que de
verdad varía entre una ronda y otra: un factor **10×** entre un click (900 bytes) y
un snapshot (8,8 KB). Con el tope en bytes, un turno de ocho clics (7,2 KB) no
recorta nada —27.000 / 900 = 30 rondas, el triple del techo de rondas— y un turno
que vuelca tres páginas enteras sí. Muerde donde pesa.

**Nunca la más reciente:** el modelo tiene que poder leer el resultado de lo que
acaba de hacer. Y tampoco se recorta una ronda **por el medio**: eso es lo que
`toolResultNote` prohíbe con nombre y apellidos desde antes de esta tarea —cortar
un error por la mitad pierde justo el trozo que explica qué pasó—, así que la
unidad del recorte es la ronda entera.

**Lo que el tope NO toca:** la base del prompt (el recall más lo que pidió el
usuario) vive fuera del historial, en `basePrompt`, y es inmutable.

### 3. El bloque de la guía

**Decisión:** la guía se queda **exactamente donde la puso la tarea de la guía**
—pegada detrás de la nota de la primera herramienta de navegador del turno— y
**no cuenta contra el tope del historial**. Si la ronda que la trajo se cae por
vieja, la guía se **rescata** y sigue en el prompt como cabecera, delante de las
rondas que sobreviven (`recortaElHistorial` la devuelve como `guiaRescatada`).

**Por qué no se movió a cabecera desde el principio**, que era la opción obvia:
porque `BrowserCoreSkillTests.test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez`
(`BrowserCoreSkillTests.swift:322`) afirma `XCTAssertLessThan(indiceNota, indiceGuia,
"la guía va DETRÁS de la nota de la herramienta que la trae")`, con su razón escrita
al lado: la nota de resultado es lo último que el modelo lee antes de decidir el
paso siguiente sobre una página ya abierta. Mover la guía delante habría puesto esa
prueba roja, y eso es deshacer el trabajo de otra tarea sin querer. La detectó el
primer `grep`, no la suite.

**Por qué no miente sobre el tamaño del prompt:** porque `maxHistoryBytes` no
pretende medir el prompt, y el comentario lo dice. Hay **dos frenos distintos y
ninguno habla por el otro**: `maxHistoryBytes` acota el historial, y
`Agent.browserGuideFits` decide si la guía cabe en la ventana real del runtime
(sumándola ella misma al presupuesto). La llamada a `browserGuideFits` se conserva
con la misma semántica: se le pasa el prompt vivo tal como quedaría en ese momento,
con la ronda en curso dentro y sin contar la guía dos veces.

**Por qué el recorte no se la puede comer:** media guía es peor que ninguna —ese es
el razonamiento entero de `browserGuideFits`, que **no recorta** la guía cuando no
cabe sino que deja de inyectarla, porque `LlamaContext` desliza la ventana en
silencio y por ese agujero se puede caer el prompt del sistema—. Y además se
inyecta una sola vez por turno: si el recorte se la llevara, un turno de
conducción larga la perdería a mitad sin que nada lo dijera.

---

## La forma nueva del prompt vivo

```
basePrompt                     ← recall + lo que pidió el usuario. Inmutable, nunca se recorta.
[guía rescatada]               ← solo si su ronda ya se cayó por vieja.
ronda k    …  ronda n          ← historial acotado: cae lo más viejo, nunca lo más reciente.
```

y cada ronda es:

```
[You then wrote: <prosa del modelo>]        ← nuevo; antes no llegaba nada de esto
[You called the tool `X`; it returned: …]   ← una por acción ejecutada; sin los argumentos
[aviso de corte de cola]                    ← si lo hubo (sale de BrowserRules, su única fuente)
[guía oficial]                              ← solo en la ronda que la trajo
```

Piezas nuevas en `Agent`: `modelProseNote`, `RondaDelTurno`, `maxHistoryBytes`,
`recortaElHistorial`, `promptVivo`. `toolResultNote` pierde el parámetro `args`.

---

## Mutaciones (suite entera, línea base 5)

| Mutación | Pruebas rojas, además de las 5 de la base |
| --- | --- |
| M1 — los argumentos vuelven al prompt: `toolResultNote(toolName:result:)` recibe `"with arguments " + tc.args + "; " + result` | `AgentTests.test_la_llamada_de_la_ronda_anterior_no_vuelve_al_prompt_y_su_resultado_si`, `AgentTests.test_la_prosa_del_modelo_viaja_al_prompt_aunque_narre_la_llamada`, `AgentTests.test_un_turno_limpio_sin_navegador_no_paga_un_solo_token_nuevo`, `AgentTests.test_una_ronda_de_una_sola_accion_no_cambia` |
| M2 — la ronda ya no empieza por la prosa: `RondaDelTurno(texto: "")` | `AgentTests.test_la_prosa_del_modelo_viaja_al_prompt_aunque_narre_la_llamada` |
| M3 — recorte desactivado: `while false, …` en `recortaElHistorial` | `AgentTests.test_recortaElHistorial_tira_lo_mas_viejo_y_jamas_lo_mas_reciente`, `AgentTests.test_el_recorte_rescata_la_guia_de_la_ronda_que_se_cae`, `AgentTests.test_con_muchas_rondas_el_historial_no_crece_sin_limite` |
| M4 — se recorta lo más RECIENTE: `removeFirst()` → `removeLast()` | las mismas tres de M3 |
| M5 — la guía no se rescata: borrada la línea `if let guia = fuera.guia { guiaRescatada = guia }` | `AgentTests.test_el_recorte_rescata_la_guia_de_la_ronda_que_se_cae`, `AgentTests.test_con_muchas_rondas_el_historial_no_crece_sin_limite` |
| M6 — la guía se renderiza DELANTE de la nota que la paga: `render` invertido | `AgentTests.test_el_recorte_rescata_la_guia_de_la_ronda_que_se_cae`, **`BrowserCoreSkillTests.test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez`** |

M6 está a propósito: es la que demuestra que la colocación de la guía que fijó la
otra tarea sigue protegida y que esta tarea no la movió.

### Sobre la trampa del «no contiene X»

La aserción central es una ausencia, y una ausencia verdea sola: con el prompt
vacío, con la X mal escrita, o si la ronda N+1 nunca se construyó. Las tres se
cierran:

- la ausencia se afirma contra la **misma constante** que conduce al runtime
  (`XCTAssertFalse(segundo.contains(args))` con el `args` que se le pasó), así que
  no puede verdear por una falta de ortografía;
- se afirma en la misma prueba lo que **sí** tiene que haber: el resultado entero,
  el nombre de la herramienta, la frase `it returned:`, la prosa y el prompt del
  usuario;
- y se afirma `runtime.prompts.count == 2`, o sea que la ronda N+1 existió.

La fase ROJA se comprobó de verdad, no por compilación: las pruebas que no usaban
API nueva se corrieron contra el código de producción viejo y fallaron por los
motivos correctos, leídos del `.xcresult`: «la llamada de la ronda anterior volvió
al prompt», «ni un trozo de los argumentos», «la prosa del modelo tiene que
volver» y «la sintaxis de la llamada no», con el prompt del fallo enseñando la
guía y el JSON dentro. Las que sí usaban API nueva se dejaron fuera
con un `#if false` mientras se tomaba la medida del rojo.

---

## Fallos antes y después

- Base de la rama al empezar: **7**.
- Tras el paso 0: **5**.
- Tras la tarea 3: **5** (las mismas cinco:
  `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
  `ContactAliasStoreTests` ×2,
  `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
  `ReminderCRUDToolTests.test_update_mueve_la_hora`).
- 1.188 pruebas en verde.

---

## Lo que apareció fuera de la tarea

1. **El tripwire del literal byte a byte se disparó, y funcionó como se diseñó.**
   `AgentTests.test_non_browser_tool_note_is_byte_for_byte_the_one_that_was_there`
   pinea la nota de las herramientas que NO son de navegador entera, «para que
   cualquier cambio en la rama que NO sea de navegador rompa este test». Quitar los
   argumentos es un cambio de ese tipo: afecta a las ~71 herramientas, no solo a
   las 8 del navegador. Se actualizó el literal **a conciencia** (y se le añadió una
   aserción de que ya no contiene `with arguments`), no para que verdeara. Se quitan
   los argumentos a todas las herramientas y no solo a las de navegador porque el
   daño que se evita no es del navegador: la nota de una herramienta cualquiera
   también llega al prompt de la ronda siguiente, y el modelo que spamea
   herramientas es justo el que esa nota existe para frenar.

2. **La colocación de la guía está pineada por la tarea de la guía** y eso fijó la
   decisión 3 (`BrowserCoreSkillTests.swift:322`). No es un problema; es el diseño
   funcionando, y conviene que la tarea siguiente lo sepa antes de tocar el orden
   del prompt vivo.

3. **El recorte importa más de lo que el plan suponía, y en el camino on-device no
   es suficiente.** El plan decía «con 5-8 rondas el prompt no aprieta». Con los
   8.000 caracteres que un snapshot puede traer, ocho rondas son ~71 KB ≈ 23.500
   tokens (a los 3 B/token con los que estima `Agent.estimatedTokens`), y la ventana
   del camino on-device es de 8.192 tokens, de los que 7.680 son presupuesto de
   prompt. O sea que **el historial solo ya desbordaba la ventana**, y `LlamaContext`
   no falla cuando el prompt no cabe: desliza la ventana en silencio y se puede
   comer el prompt del sistema, donde viven la prohibición de teclear contraseñas y
   el candado de cierre. El tope de 27 KB (≈ 9.000 tokens) reduce el desbordamiento
   pero **no lo elimina** para ese camino. Lo honesto sería que `maxHistoryBytes`
   saliera de `runtime.contextTokenBudget` cuando el runtime lo declara (como ya hace
   `browserGuideFits`), con el valor fijo de 27 KB como techo para los runtimes que
   no declaran ventana. Queda **fuera de esta tarea y propuesto**: el camino que corre
   hoy es `ServerRuntime`, que no declara ventana, así que no es urgente — pero está
   escrito aquí para que no se descubra depurando.

4. **`ScriptedRuntime` ahora emite tokens.** Para poder medir la prosa hubo que
   darle al doble la capacidad de escribir texto además de pedir herramientas
   (parámetro `prosa:`, por omisión vacío, que conserva byte a byte el
   comportamiento anterior). Al hacerlo, el doble también emite el `.token` que un
   runtime de verdad emitiría, que antes no emitía. Ninguna prueba existente
   depende de eso (la suite entera lo confirma), pero es un cambio en un doble
   compartido y queda dicho.
