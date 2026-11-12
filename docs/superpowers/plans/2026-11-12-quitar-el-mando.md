# Quitar el mando de raíz — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminar de la app (y del servidor) todo lo que permite al USUARIO controlar el navegador remoto —volante, toques, teclado, ratón, rueda— dejando intacto el STREAM (panel que muestra el navegador), el navegador del agente, Formularios/bóveda y el Chrome real de la Mac.

**Architecture:** Se borra de los consumidores hacia los productores, para que la rama compile y la suite quede verde tras CADA tarea: primero la UI y el coordinador sueltan el mando (y con ellos `BrowserMando.swift`), luego el cliente del relé y el estado del panel pierden el protocolo del volante, luego el fotograma pierde el viewport (que solo existía para mapear toques) y mueren `BrowserInputMapper`/`BrowserInputEvents`. Una prueba nueva de AUSENCIA sobre el fuente crudo impide que vuelva. En el servidor el mando nunca llegó a `main`: se archiva su rama.

**Tech Stack:** Swift 6 / SwiftUI / XCTest (proyecto `Gemma/Gemma.xcodeproj`, grupos sincronizados con el sistema de ficheros: borrar un `.swift` NO requiere tocar el `.pbxproj`); Python/FastAPI + pytest en `gemma-memory/browser/`.

**Spec:** Este plan **retira** `docs/superpowers/specs/2026-11-08-mando-compartido-del-navegador-design.md` (y sus planes `2026-11-08-mando-subsistema-a.md`, `2026-11-08-mando-subsistema-b.md`). La orden del usuario, textual: «elimina el control remoto … elimina ese control manual de raíz, solo necesito streaming del navegador abierto en mi mac hacia la app, sin controlarlo». El control lo tiene en la Mac con el Chrome nativo; en el móvil no lo necesita.

## Global Constraints

- Rama: `feat/mando-subsistema-b` en `/Users/hashdown/Projects/personal_agent/.worktrees/mando-subsistema-b` (== `main` en `0ab8a24` al escribir este plan). Medido todo lo que sigue sobre ese commit.
- Tras CADA tarea: `xcodebuild build` verde en macOS **y** en iOS Simulator (el cliente real del usuario es el iPhone), y la suite macOS con el MISMO conjunto de fallos que la línea base (Tarea 1, paso 1) menos las pruebas borradas a propósito.
- `git add` por ruta, NUNCA `git add -A` (barre `graphify-out/<fecha>/graph.json` de >100 MB y GitHub rechaza el push).
- No se toca: `BrowserPanelView` en lo que pinta (imagen, frase, «en vivo», «último cambio», hueco sin imagen, cuentas), `BrowserPanelCoordinator` en su ciclo de vida (un panel por turno, panel vivo, tope de inactividad), el acuse `ack` por fotograma (sin él el demonio deja de mandar fotogramas), `HTTPAgentBrowserInvoker`, `ChromeRealDeLaMac`, `Forms/*`, `BrowserRules`.
- El token del navegador (`TokenDeConducir`, cuenta de llavero `browserBearerToken`) **SE QUEDA**: ver «Decisión mía 1».
- Despliegue al i3: SOLO descrito (Tarea 5). No se despliega sin OK explícito del usuario.
- Commits con los pies de atribución que fije la sesión que ejecute.

## Review Focus

1. **El stream deja de llegar** porque al quitar el canal de envío se rompió el `ack`: el usuario espera ver la página moviéndose a 25 fps igual que antes. La prueba `test_el_acuse_de_un_frame_sigue_saliendo_por_el_socket` se conserva (Tarea 2) y es la que lo fija.
2. **Un servidor viejo (o el de la rama A, si estuviera desplegado) sigue mandando `{"type":"mando",...}` o `viewport_width`**: la app tiene que ignorarlos sin romper el panel. Tarea 2 añade la aserción `decode(mando) == nil` y Tarea 3 la de que un `frame` con `viewport_width` se decodifica igual.
3. **El panel retirado deja el socket abierto** (antes lo soltaba el coordinador al soltar el mando): el usuario espera que el visor deje de gastar ~10 Mbit/s contra el i3 al cerrar. Lo fija `test_endTurn_cancela_la_tarea_que_consume_el_flujo` (se conserva) y la prueba trasladada en la Tarea 1.
4. **iOS compila pero el panel queda mudo**: el hueco sin imagen tiene que seguir explicándose. Las pruebas de `textoSinImagen`/`muestraLaCuenta` no se tocan; el build de iOS es paso obligatorio de cada tarea.
5. **El mando vuelve por accidente** (alguien restaura un fichero o reintroduce un gesto en el panel): lo caza `ElMandoNoExisteTests` (Tarea 4), con su medición de mutación.

---

## Inventario verificado (sobre `0ab8a24`)

Método: `grep` de `Mando|mando|BrowserInput|TokenDeConducir|pulsacionesEnviadas|onducir` sobre `Gemma/`, y **lectura** de cada acierto. La palabra «mando» aparece en otros sentidos (`comando`, `subcomando`, «te mando un abrazo» en `SmartMessageDrafter`, «llamando»), y «conducir» describe también al AGENTE conduciendo la página (eso se queda).

### App — producción (`Gemma/Gemma/`)

| ruta | qué es | destino | por qué |
|---|---|---|---|
| `Harness/BrowserMando.swift` (1183 l.) | `MandoDelNavegador`, `extension BrowserRelayClient: MandoDelNavegador`, `BrowserMandoEntrada` (muestreo, puntero, teclado, `sePuedeApuntar`, `accionDelBoton`), `BrowserMandoEnvio` (cola, `espera`, `ReanudaUnaSolaVez`), `BrowserMandoSesion` (gesto, foco, `pulsacionesEnviadas`), vistas `BrowserMandoGestos` y `BrowserMandoBarra` | **SE VA** (T1) | todo es entrada del usuario |
| `Harness/BrowserInputEvents.swift` (177 l.) | codificadores `input_mouse`/`input_keyboard`/`input_touch`, `topeDelRele`, `cabeEnElTope` | **SE VA** (T3) | entrada del usuario |
| `Harness/BrowserInputMapper.swift` (302 l.) | `paginaDesde`, `DimensionesDelCable`, `toleranciaDeProporcion` | **SE VA** (T3) | mapa del toque; `DimensionesDelCable` solo lo consumen el fotograma y el estado para eso |
| `Harness/BrowserPanelView.swift` | el panel | **SE EDITA** (T1) | quitar `mando`, `sesion`, `.overlay { BrowserMandoGestos }`, `BrowserMandoBarra`, `sePuedeApuntar` y los estáticos `textoDelBoton`, `textoDelBotonPidiendo`, `elBotonActua`, `rotuloDeQuienConduce`, `avisoDeApuntado`, `textoDeEntradaPerdida`, `capturaLosGestos` |
| `Harness/BrowserPanelCoordinator.swift` | coordinador de paneles | **SE EDITA** (T1, T2) | quitar `VisorDelRele`, `mandos`, `sesiones`, `mando(de:)`, `sesion(de:)`, la espera del gesto en `retire`, la comparación de `quienConduce` en `aplica` |
| `Harness/BrowserPanelState.swift` | estado del panel | **SE EDITA** (T2, T3) | quitar `quienConduce`, el caso `.mando`, el reseteo del volante en `.closed`/`freeze()` (T2); `dimensionesDelCable` (T3) |
| `Harness/AgentChatView.swift` | chat; `ChatLogRow` | **SE EDITA** (T1) | líneas 352-356 (`mando:`/`sesion:` y su comentario) y 583-586 (props), 623 (`BrowserPanelView(state:mando:sesion:)`) |
| `Harness/HarnessModel.swift` | `makeRelayStream` | **SE EDITA** (T1, T4) | devuelve `AsyncStream<BrowserRelayEvent>?` en vez de la tupla; doc 546-556 y 567-569 |
| `NativeServices/BrowserRelayClient.swift` (509 l.) | cliente del visor | **SE EDITA** (T2, T3) | se va `QuienConduce`, `.mando`, `caducidadDeLaPeticion`, `payloadTomarElMando`, `payloadDevolverElMando`, `peticionSigueViva`, `resuelve`, `tomaElMando`, `devuelveElMando`, `manda(entrada:)`, `enviaPorElCanal`, `canal`, `pedidoEl`, `ahora` (T2); `viewport` del `.frame` (T3). **Se queda** `SocketDelVisor` (el `ack` sale por `socket.envia` y las pruebas inyectan el socket), `ackPayload`, reconexión, `socketURL`, `decode` del resto |
| `Settings/TokenDeConducir.swift` | `AlmacenDeSecretos`, `LlaveroDelSistema`, `SecretoDelDispositivo`, `TokenDeConducir` | **SE QUEDA**, se edita solo el doc-comment de `TokenDeConducir` (T4) | es EL token del servicio del navegador: lo leen `makeRelayStream` (stream) y `browserInvoker` (agente). Ver Decisión mía 1 |
| `Settings/SettingsKeys.swift` l.17-21 | doc de `browserBearerToken` | **SE EDITA** (T4) | «conduce un Chrome con la sesión de Google» → el token autoriza al agente y al visor |
| `Settings/SettingsView.swift` l.93-98 | doc del campo del token | **SE EDITA** (T4) | idem; la lógica (219-226) se queda |
| `GemmaApp.swift` l.10, 49 | migración del token | **SE QUEDA** | no habla del mando |
| `Settings/TokenDeMemoria.swift`, `Forms/SecretVault.swift` | citan `TokenDeConducir` | **SE QUEDA** | el tipo sigue existiendo |
| `Forms/FormBroker.swift` l.16-17 | doc: «Mismo patrón que `ReanudaUnaSolaVez` en `BrowserMando.swift`» | **SE EDITA** (T4) | referencia colgante tras T1 |
| `Agent/Agent.swift` 730, 857, 868-869, 1395 | «Conducir una página», `comando click` | **SE QUEDA** | es el AGENTE conduciendo, no el mando |
| `Agent/BrowserRules.swift`, `Agent/BrowserCoreSkill.swift` | «comando» | **SE QUEDA** | falso positivo; las reglas ya no citan el mando (lo fija `AgentTests.test_las_reglas_mandan_los_secretos_por_formulario`) |
| `AtoZ/AtoZLoginView.swift` l.431 | «comando cURL» | **SE QUEDA** | falso positivo |
| `NativeServices/{AgentBrowserInvoker,AgentBrowserToolOutput,NavegadorRealDeLaMac,ReadWebpageTool,ShortcutRunner,ToolJSONOutput,MakePhoneCallTool,SmartMessageDrafter}.swift` | «comando/subcomando/llamando/te mando» | **SE QUEDA** | falsos positivos, leídos uno a uno |

### Consumidores de cada símbolo que se va (grep real, `--include='*.swift'`)

| símbolo | producción | pruebas | se rompe en |
|---|---|---|---|
| `MandoDelNavegador` | AgentChatView, BrowserMando, BrowserPanelCoordinator, BrowserPanelView | BrowserPanelViewTests, MandoDeMentira, TokenDeConducirTests (solo comentario l.271) | T1 |
| `BrowserMandoSesion` / `BrowserMandoEnvio` / `BrowserMandoEntrada` / `BrowserMandoGestos` / `BrowserMandoBarra` | AgentChatView, BrowserMando, BrowserPanelCoordinator, BrowserPanelView | BrowserMandoSesionTests, BrowserPanelViewTests | T1 |
| `pulsacionesEnviadas` | BrowserMando | BrowserMandoSesionTests, BrowserPanelViewTests | T1 |
| `MandoDeMentira` (doble de pruebas) | — | AvisoDeLaAppEnElTranscriptoTests, BrowserMandoSesionTests, BrowserPanelCoordinatorTests, BrowserPanelHarnessWiringTests, BrowserPanelViewTests, BrowserPanelWiringTests | T1 |
| `QuienConduce` / `quienConduce` | BrowserMando, BrowserPanelState, BrowserPanelView, BrowserPanelCoordinator, BrowserRelayClient | BrowserMandoSesionTests, BrowserPanelStateTests, BrowserPanelViewTests, BrowserRelayClientTests | T2 |
| `BrowserRelayEvent.mando` | BrowserRelayClient, BrowserPanelState | BrowserRelayClientTests, BrowserPanelStateTests, **AgentBrowserLiveTests l.114 (switch exhaustivo)** | T2 |
| `tomaElMando` / `devuelveElMando` / `manda(entrada:)` / `enviaPorElCanal` | BrowserMando, BrowserRelayClient | BrowserPanelViewTests, BrowserRelayClientTests, MandoDeMentira | T2 (consumidores ya borrados en T1) |
| `payloadTomarElMando` / `payloadDevolverElMando` / `peticionSigueViva` / `resuelve` / `caducidadDeLaPeticion` / init `ahora:` | BrowserRelayClient | BrowserRelayClientTests (incl. helper `montaElCliente` l.605-611) | T2 |
| `BrowserInputEvents` | BrowserInputMapper, BrowserMando, BrowserRelayClient (`cabeEnElTope`) | BrowserInputEventsTests, BrowserInputMapperTests, BrowserPanelViewTests, BrowserRelayClientTests, TroceadoDeFuente (doc) | T3 |
| `BrowserInputMapper` / `DimensionesDelCable` / `paginaDesde` | BrowserMando, BrowserPanelState, BrowserRelayClient | BrowserInputMapperTests, BrowserMandoSesionTests, BrowserPanelViewTests, TroceadoDeFuente (doc) | T3 |
| `.frame(…, viewport:)` (4 campos) | BrowserRelayClient (l.47, 243, 476), BrowserPanelState (l.136) | `viewport: nil` en BrowserPanelStateTests ×12, BrowserPanelCoordinatorTests ×6, BrowserPanelWiringTests ×3; patrones de 4 campos en BrowserRelayClientTests l.29, 42, 71 y AgentBrowserLiveTests l.108 | T3 |

### App — pruebas (`Gemma/GemmaTests/`)

| fichero | destino | detalle |
|---|---|---|
| `BrowserMandoSesionTests.swift` (27 pruebas) | **SE VA** (T1) | todo mando |
| `MandoDeMentira.swift` | **SE VA** (T1) | doble del mando |
| `BrowserPanelViewTests.swift` (45 pruebas) | **SE VA** (T1), salvo 2 que se trasladan reescritas | 43 son mando (botón, rótulo, captura, toque, puntero, teclado, envío, viewport, lectura de fuente de BrowserMando/BrowserPanelView). Se trasladan a `BrowserPanelCoordinatorTests`: `test_sin_flujo_no_hay_panel_ni_mando` → `test_sin_flujo_no_hay_panel` y `test_makeRelayStream_solo_devuelve_visor_con_la_url_configurada` (igual nombre). `test_el_coordinador_entrega_el_mando_del_panel_que_abrio` y `test_al_retirar_el_panel_el_mando_se_suelta_de_verdad` se borran (miden el mando) |
| `BrowserInputEventsTests.swift` (10), `BrowserInputMapperTests.swift` (19) | **SE VAN** (T3) | |
| `BrowserRelayClientTests.swift` (40) | **SE EDITA** (T2, T3) | se borran 20 (lista en T2); se conservan acuse, decode, socketURL, reconexión, `stop` |
| `BrowserPanelStateTests.swift` (31) | **SE EDITA** (T2, T3) | se borran `test_el_volante_vuelve_al_agente_al_cortarse_la_conexion_y_la_reconexion_no_lo_resucita`, `test_otro_visor_al_volante_no_es_lo_mismo_que_el_agente`, `test_un_panel_congelado_no_le_dice_al_usuario_que_conduce`, `test_un_mando_cuenta_como_que_el_servidor_hablo` (T2); 12 `viewport: nil` (T3) |
| `BrowserPanelCoordinatorTests.swift` (28) | **SE EDITA** (T1, T3) | 9 construcciones `(stream, MandoDeMentira())` → `stream` (l.7, 74, 86, 101, 118, 150, 248, 261, 275); 6 `viewport: nil` |
| `BrowserPanelWiringTests.swift` l.15, 62, 76, 91 | **SE EDITA** (T1, T3) | |
| `BrowserPanelHarnessWiringTests.swift` l.19 | **SE EDITA** (T1) | |
| `AvisoDeLaAppEnElTranscriptoTests.swift` l.22 | **SE EDITA** (T1) | |
| `TokenDeConducirTests.swift` l.262-275 | **SE EDITA** (T1) | `visor` ya es el flujo; el comentario l.271 cita `MandoDelNavegador` |
| `AgentBrowserLiveTests.swift` l.108, 114 | **SE EDITA** (T2, T3) | switch exhaustivo |
| `TroceadoDeFuente.swift` l.9-12, 31, 66-76 | **SE EDITA** (T3, T4) | el censo de pruebas que leen fuente pierde 3 filas y gana `ElMandoNoExisteTests` |
| `AgentTests.swift` l.490-510 | **SE QUEDA** | ya afirma que las reglas no tienen frases del mando |
| `TokenDeMemoriaTests`, `ClaveDeProveedorTests`, `HTTPAgentBrowserInvokerTests`, `TroceadoDeFuenteTests` | **SE QUEDAN** | citan `TokenDeConducir`, que se queda |
| `ElMandoNoExisteTests.swift` | **NUEVO** (T4) | ausencia sobre fuente crudo |

### Servidor (`gemma-memory`)

Repo: `/Users/hashdown/Projects/personal_agent/gemma-memory` (checkout en `feat/chrome-de-verdad` `a2b9d18`, con cambios SIN COMMITEAR en `memory-service/` que no son de este plan). Worktree del mando: `/Users/hashdown/Projects/personal_agent/gemma-memory/.worktrees/mando-subsistema-a` (`feat/mando-subsistema-a` `4ac4c10`).

Medido:
- `feat/mando-subsistema-a` tiene **37 commits** sobre `main` (`e174784`) y **NO está fusionada** ni en `main` ni en `feat/chrome-de-verdad`. Ahí viven `browser/mando.py`, `browser/test_mando.py`, endpoints `GET /v1/browser/mando` y `POST /v1/browser/mando/pedir`, la puerta del `invoke`, los mensajes `mando_tomar`/`mando_devolver` y el reenvío de `input_*` en `relay.py`, `viewport_width/height` en el fotograma (`stream.py`), `BROWSER_ALLOWED_ORIGINS` en `.env.example`/compose (+4290/−63 en 14 ficheros).
- `main` y `feat/chrome-de-verdad` **no** tienen entrada de usuario: `browser/test_app.py:1257` ya afirma «Spec §7: nada de control remoto. Un `input_mouse` del visor no se reenvía».
- `feat/chrome-de-verdad:docker-compose.browser.yml` l.~55-60 tiene un comentario «De ahí el mando compartido: existe justamente para ese relevo».
- **No sé qué imagen corre hoy en el i3** (si se desplegó la rama A o no). Tarea 5 lo mide antes de proponer nada.
- La app de `main` NO llama a `/v1/browser/mando*` (grep: solo aparece en el plan A).

### Datos y configuración

- Llavero: servicio `lambert-dev-group.Gemma.secretos`, cuenta `browserBearerToken` → **se queda en uso** (es el token del stream y del agente). Nada que migrar ni borrar.
- `UserDefaults`: el mando no creó ninguna clave (grep de `SettingsKeys` y `@AppStorage`: ninguna del mando). `browserBearerToken` en `UserDefaults` ya es solo origen de migración; no cambia.
- Compose: `BROWSER_ALLOWED_ORIGINS` solo existe en la rama A. Si el `.env` del i3 la tiene, queda **huérfana e inocua** (Decisión mía 4).

---

### Task 1: La UI y el coordinador sueltan el mando; se borra `BrowserMando.swift`

**Files:**
- Delete: `Gemma/Gemma/Harness/BrowserMando.swift`, `Gemma/GemmaTests/BrowserMandoSesionTests.swift`, `Gemma/GemmaTests/MandoDeMentira.swift`, `Gemma/GemmaTests/BrowserPanelViewTests.swift`
- Modify: `Gemma/Gemma/Harness/BrowserPanelView.swift` (l.9-15, 81-85 overlay, 132 barra, 155-275 estáticos del mando y `sePuedeApuntar`)
- Modify: `Gemma/Gemma/Harness/AgentChatView.swift` (l.352-356, 583-586, 623)
- Modify: `Gemma/Gemma/Harness/BrowserPanelCoordinator.swift` (l.16-25, 29-45, 113-114, 133-143, 150-169, 255-279)
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (`makeRelayStream`, l.544-589)
- Modify tests: `BrowserPanelCoordinatorTests.swift`, `BrowserPanelWiringTests.swift` l.15, `BrowserPanelHarnessWiringTests.swift` l.19, `AvisoDeLaAppEnElTranscriptoTests.swift` l.22, `TokenDeConducirTests.swift` l.262-275

**Interfaces:**
- Consumes: nada.
- Produces:
  - `BrowserPanelCoordinator.StreamFactory = @MainActor () -> AsyncStream<BrowserRelayEvent>?` (desaparece `VisorDelRele`).
  - `BrowserPanelCoordinator` sin `mando(de:)` ni `sesion(de:)`. `aplica(_:al:)` se queda (interno) y en esta tarea sigue llamando a `state.apply(event)`; la comparación de `quienConduce` y `cambioElVolante()` desaparecen.
  - `static func makeRelayStream(defaults:almacen:abreElSocket:) -> AsyncStream<BrowserRelayEvent>?` en `HarnessModel` (mismos parámetros).
  - `BrowserPanelView(state: BrowserPanelState)` — único parámetro.
  - `ChatLogRow` sin `mando` ni `sesion`.

- [ ] **Step 1: Línea base.** Desde la raíz del worktree:
  ```
  xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' 2>&1 | tee /tmp/base.log | tail -3
  grep -E "^Test case" /tmp/base.log | grep "' failed" | sed 's/ on .*//' | sort -u > /tmp/base-fallos.txt
  grep -cE "^Test case .* passed" /tmp/base.log
  ```
  Esperado: conocido-fallido `HarnessModelTests.test_defaultBaseURL` (y lo que haya; se anota). Si sale «0 pruebas ejecutadas», mirar el disco (`df -h /`) antes que el código.
- [ ] **Step 2: Trasladar las dos pruebas que se quedan** a `BrowserPanelCoordinatorTests.swift`, dentro de `#if os(macOS)` (el host de iOS aborta al instanciar el coordinador, motivo ya escrito en el fichero de origen):
  ```swift
  @MainActor func test_sin_flujo_no_hay_panel() {
      let c = BrowserPanelCoordinator(stream: { nil })
      XCTAssertNil(c.openIfNeeded(toolName: "browser_open"))
  }
  @MainActor func test_makeRelayStream_solo_devuelve_visor_con_la_url_configurada() {
      let defaults = UserDefaults(suiteName: "quitar-el-mando-\(UUID().uuidString)")!
      XCTAssertNil(HarnessModel.makeRelayStream(defaults: defaults, almacen: AlmacenEnMemoria()), "sin URL no hay visor")
      defaults.set("http://192.0.2.1:8083", forKey: SettingsKeys.browserBaseURL)
      XCTAssertNotNil(HarnessModel.makeRelayStream(defaults: defaults, almacen: AlmacenEnMemoria()), "con URL válida sí hay visor")
  }
  ```
- [ ] **Step 3: Borrar** `BrowserPanelViewTests.swift`, `BrowserMandoSesionTests.swift`, `MandoDeMentira.swift`, `BrowserMando.swift` (`git rm`).
- [ ] **Step 4: `BrowserPanelView`**: quitar `let mando`, `let sesion` y sus comentarios; quitar el `.overlay { BrowserMandoGestos(...) }` y el comentario «EL GESTO VA ENGANCHADO A LA IMAGEN…» (la `Image` queda `.resizable().scaledToFit()`); quitar la línea `BrowserMandoBarra(...)`; quitar `sePuedeApuntar` y la sección `// MARK: el mando — lo que se puede probar sin pintar` entera hasta antes de `textoSinImagen` (los siete estáticos listados en el inventario). `textoSinImagen`, `muestraLaCuenta`, `cuenta`, `esperandoLaPrimera`, `frameID`, `decodeOffMain` se quedan sin cambios.
- [ ] **Step 5: `AgentChatView`**: en el `ChatLogRow(...)` quitar las líneas `// El volante del panel…` (3 líneas), `mando: …` y `sesion: …`; en `ChatLogRow` quitar las props `mando` y `sesion` con sus comentarios; `BrowserPanelView(state: panel)`.
- [ ] **Step 6: `BrowserPanelCoordinator`**: `StreamFactory` devuelve el flujo; `openIfNeeded` usa `guard let stream = makeStream()`; borrar `mandos`, `sesiones` y sus doc-comments, las dos asignaciones de l.113-114, las tres líneas del final del consumidor que sueltan mando/sesión (l.133-143 desde «El flujo terminó: el cliente se rindió…»), `mando(de:)`, `sesion(de:)`; `aplica` queda `panels[id]?.apply(event)` (con su guard); `retire` queda: `panels[id]?.freeze()` + `consumers.removeValue(forKey: id)?.cancel()` (sin la espera del gesto ni su comentario 🔴).
- [ ] **Step 7: `HarnessModel.makeRelayStream`**: tipo de retorno `AsyncStream<BrowserRelayEvent>?`, `return stream`; reescribir el doc-comment quitando el párrafo «Devuelve **también el cliente**…» (l.549-554). El resto (puente, `onTermination` que hace `client.stop()`) igual.
- [ ] **Step 8: Pruebas consumidoras**: `{ (stream, MandoDeMentira()) }` → `{ stream }` (y variantes con `openStreamForTest()`/`AsyncStream { _ in }`) en Coordinator ×9, Wiring l.15, HarnessWiring l.19, Aviso l.22; en `TokenDeConducirTests` cambiar el comentario l.271 a «No se para el cliente a mano: `makeRelayStream` solo devuelve el flujo.» (el código `let flujo = try XCTUnwrap(visor…)` compila igual).
- [ ] **Step 9: Verificar**:
  ```
  xcodebuild build -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'generic/platform=iOS Simulator' | tail -1   # ** BUILD SUCCEEDED **
  xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' 2>&1 | tee /tmp/t1.log | tail -3
  grep -E "^Test case" /tmp/t1.log | grep "' failed" | sed 's/ on .*//' | sort -u | diff /tmp/base-fallos.txt -   # sin diferencias
  grep -rnE "MandoDelNavegador|BrowserMando|MandoDeMentira|pulsacionesEnviadas" Gemma --include='*.swift'   # vacío
  ```
- [ ] **Step 10: Commit**
  ```
  git add Gemma/Gemma/Harness/BrowserPanelView.swift Gemma/Gemma/Harness/AgentChatView.swift Gemma/Gemma/Harness/BrowserPanelCoordinator.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/BrowserPanelCoordinatorTests.swift Gemma/GemmaTests/BrowserPanelWiringTests.swift Gemma/GemmaTests/BrowserPanelHarnessWiringTests.swift Gemma/GemmaTests/AvisoDeLaAppEnElTranscriptoTests.swift Gemma/GemmaTests/TokenDeConducirTests.swift
  git rm Gemma/Gemma/Harness/BrowserMando.swift Gemma/GemmaTests/BrowserMandoSesionTests.swift Gemma/GemmaTests/MandoDeMentira.swift Gemma/GemmaTests/BrowserPanelViewTests.swift
  git commit -m "refactor(mando): el panel solo mira; fuera el volante, el gesto y el teclado"
  ```

### Task 2: El cliente del relé y el estado del panel olvidan el volante

**Files:**
- Modify: `Gemma/Gemma/NativeServices/BrowserRelayClient.swift` (l.11-28, 53-58, 60-70 doc de `SocketDelVisor`, 123-152, 160-197, 256-264, 273-307, 355-436, 466-506)
- Modify: `Gemma/Gemma/Harness/BrowserPanelState.swift` (l.56-62, 120-135, 158-165)
- Modify: `Gemma/Gemma/Harness/BrowserPanelCoordinator.swift` (solo si quedó alguna referencia a `quienConduce`)
- Modify tests: `BrowserRelayClientTests.swift`, `BrowserPanelStateTests.swift`, `AgentBrowserLiveTests.swift` l.114

**Interfaces:**
- Consumes: Task 1 (nadie fuera del cliente llama ya a `tomaElMando`/`devuelveElMando`/`manda(entrada:)`).
- Produces:
  - `enum BrowserRelayEvent { case frame(seq:jpeg:capturedAt:viewport:), narration, host, state, summary, closed }` — seis casos (el viewport se va en T3).
  - `BrowserRelayClient.init(baseURL: URL, bearerToken: String, maxFps: Int? = nil, session: URLSession = .shared, abreElSocket: (@Sendable (URL, String) -> SocketDelVisor)? = nil)` — sin `ahora:`.
  - `BrowserRelayClient.decode(#"{"type":"mando","quien":"humano"}"#) == nil` (cae en `default`).
  - `BrowserPanelState` sin `quienConduce`.

- [ ] **Step 1: Prueba nueva que fija la tolerancia a un servidor viejo** (Review Focus 2), en `BrowserRelayClientTests`:
  ```swift
  func test_un_mensaje_de_mando_de_un_servidor_viejo_se_ignora() {
      for viejo in [#"{"type":"mando","quien":"humano"}"#, #"{"type":"mando","quien":"agente"}"#] {
          XCTAssertNil(BrowserRelayClient.decode(viejo), "el visor ya no sabe de volantes: \(viejo)")
      }
  }
  ```
  Ejecutar solo esa prueba: debe FALLAR (hoy decodifica `.mando`).
- [ ] **Step 2: Borrar de `BrowserRelayClientTests`** estas 20 pruebas: `test_los_dos_mensajes_del_mando_tienen_la_forma_exacta`, `test_el_mando_del_cable_trae_dos_valores_y_el_humano_anonimo_no_es_mio`, `test_un_mando_con_un_quien_que_no_entendemos_no_pinta_que_conduces_tu`, `test_con_mi_peticion_viva_el_humano_del_servidor_soy_yo`, `test_sin_peticion_mia_el_humano_del_servidor_es_otro_visor`, `test_solo_una_peticion_mia_viva_asciende_el_humano_anonimo_a_mio`, `test_el_agente_al_volante_descarta_mi_peticion_y_el_siguiente_humano_ya_no_es_mio`, `test_la_peticion_del_volante_caduca_en_el_plazo_exacto`, `test_el_plazo_es_de_un_viaje_generoso_y_no_de_un_minuto`, `test_dentro_del_plazo_la_misma_peticion_si_reclama_el_volante`, `test_una_peticion_sin_contestar_caduca_y_deja_de_reclamar_el_volante`, `test_una_peticion_que_no_salio_del_aparato_no_reclama_el_volante_despues`, `test_la_peticion_no_sobrevive_al_socket_que_la_mando`, `test_tomar_el_mando_manda_exactamente_el_mensaje_de_tomar_y_nada_mas`, `test_devolver_el_mando_manda_exactamente_el_mensaje_de_devolver`, `test_con_el_socket_abierto_la_entrada_sale_tal_cual_y_al_caerse_deja_de_salir`, `test_la_entrada_no_sale_si_nunca_se_abrio_el_socket`, `test_un_canal_que_ya_fallo_no_se_reintenta`, `test_una_entrada_que_pasa_el_tope_del_rele_no_se_manda_porque_el_rele_la_tiraria_en_silencio`, `test_ninguna_linea_de_registro_de_este_cliente_lleva_la_entrada_del_usuario`. Quitar el parámetro `ahora:` del helper `montaElCliente` (l.605-611) y lo que solo usaban esas pruebas (helpers de reloj, si quedan sin uso). **Se conservan**: `test_el_acuse_de_un_frame_sigue_saliendo_por_el_socket` (Review Focus 1; reescribir su doc-comment: «el acuse es lo único que el visor manda»), `test_stop_termina_el_flujo` y las de decode/socketURL/reconexión.
- [ ] **Step 3: Borrar de `BrowserPanelStateTests`** las 4 pruebas listadas en el inventario.
- [ ] **Step 4: `BrowserRelayClient`**: borrar `QuienConduce`, `case mando`, `caducidadDeLaPeticion`, los dos `payload…Mando`, `ahora` (propiedad e init), `canal`, `pedidoEl`, `peticionSigueViva`, `resuelve`, la sección `// MARK: el mando compartido` entera (`tomaElMando`, `devuelveElMando`, `manda(entrada:)`, `enviaPorElCanal`), la rama `case "mando":` de `decode`, en `runOnce` las líneas `canal = socket`, el bloque `if case .mando…` y `canal = nil; pedidoEl = nil` con su comentario. `event` pasa a `let`. Reescribir el doc de `SocketDelVisor` en dos frases: existe para que una prueba inyecte el socket, y lo único que el visor manda es el `ack` por fotograma.
- [ ] **Step 5: `BrowserPanelState`**: borrar `quienConduce` y su doc, `case .mando`, la asignación `quienConduce = .agente` y su comentario en `.closed` y en `freeze()`. Si `BrowserPanelCoordinator` aún menciona `quienConduce`, quitarlo.
- [ ] **Step 6: `AgentBrowserLiveTests` l.114**: borrar `case .mando(let quien): …`.
- [ ] **Step 7: Verificar**: la prueba del paso 1 pasa; build iOS ok; suite macOS con `diff /tmp/base-fallos.txt` vacío;
  ```
  grep -rnE "QuienConduce|quienConduce|tomaElMando|devuelveElMando|manda\(entrada|mando_tomar|mando_devolver|peticionSigueViva|enviaPorElCanal" Gemma --include='*.swift'   # vacío
  ```
- [ ] **Step 8: Commit** (`git add` de los 5-6 ficheros tocados, por ruta): `refactor(mando): el visor solo recibe y acusa; fuera el protocolo del volante`

### Task 3: El fotograma pierde el viewport; mueren el mapa del toque y los codificadores de entrada

**Files:**
- Delete: `Gemma/Gemma/Harness/BrowserInputEvents.swift`, `Gemma/Gemma/Harness/BrowserInputMapper.swift`, `Gemma/GemmaTests/BrowserInputEventsTests.swift`, `Gemma/GemmaTests/BrowserInputMapperTests.swift`
- Modify: `Gemma/Gemma/NativeServices/BrowserRelayClient.swift` (l.33-47 doc + caso, 225-244 decode, 476 patrón)
- Modify: `Gemma/Gemma/Harness/BrowserPanelState.swift` (l.17-28, 115, 136-143, 159)
- Modify tests: `BrowserPanelStateTests` (12 `viewport: nil`), `BrowserPanelCoordinatorTests` (6), `BrowserPanelWiringTests` (3), `BrowserRelayClientTests` l.29, 42, 71, `AgentBrowserLiveTests` l.108, `TroceadoDeFuente.swift` (doc l.9-12, 31, 66-76)

**Interfaces:**
- Consumes: Task 2.
- Produces: `case frame(seq: Int, jpeg: Data, capturedAt: Date)`; `BrowserPanelState` sin `dimensionesDelCable`.

- [ ] **Step 1: Prueba** en `BrowserRelayClientTests` (Review Focus 2):
  ```swift
  func test_un_frame_con_viewport_de_un_servidor_viejo_se_decodifica_igual() throws {
      let jpeg = Data([0xFF, 0xD8]).base64EncodedString()
      let texto = #"{"type":"frame","seq":3,"jpeg":"\#(jpeg)","captured_at":1,"viewport_width":1280,"viewport_height":720}"#
      guard case .frame(let seq, let bytes, _) = try XCTUnwrap(BrowserRelayClient.decode(texto)) else { return XCTFail("no es frame") }
      XCTAssertEqual(seq, 3); XCTAssertEqual(bytes, Data([0xFF, 0xD8]))
  }
  ```
  (No compila hasta el paso 3: es el «rojo» de esta tarea.)
- [ ] **Step 2: Borrar** los cuatro ficheros (`git rm`).
- [ ] **Step 3: Producción**: `.frame` con tres campos; en `decode` borrar el bloque `LAS DOS DIMENSIONES, O NINGUNA…` y la variable `viewport`; patrón de `runOnce` `case .frame(let seq, _, _)`; en `BrowserPanelState` borrar `dimensionesDelCable` (propiedad, doc, y las tres asignaciones) y el patrón `case .frame(_, let data, let capturedAt)`.
- [ ] **Step 4: Pruebas**: quitar `, viewport: nil` de las 21 llamadas; patrones de 4 a 3 campos en RelayClientTests ×3 y AgentBrowserLiveTests ×1. En `TroceadoDeFuente.swift` quitar de la doc las filas `BrowserPanelViewTests`, `BrowserInputMapperTests`, `BrowserInputEventsTests`, los puntos 1-2 de la lista de l.9-11 y el ejemplo de l.31, y corregir el recuento («Nueve ficheros…/Ocho…») contando de nuevo con `grep -rln '#filePath' Gemma/GemmaTests`.
- [ ] **Step 5: Verificar**: build iOS, suite macOS con diff vacío, y
  ```
  grep -rnE "BrowserInputEvents|BrowserInputMapper|DimensionesDelCable|dimensionesDelCable|paginaDesde|viewport:" Gemma --include='*.swift'   # vacío
  ```
- [ ] **Step 6: Commit**: `refactor(mando): el fotograma ya no lleva viewport; fuera el mapa del toque y los codificadores de entrada`

### Task 4: Prueba de ausencia y limpieza de las menciones vivas

**Files:**
- Create: `Gemma/GemmaTests/ElMandoNoExisteTests.swift`
- Modify (solo doc-comments): `Settings/TokenDeConducir.swift` (doc de `enum TokenDeConducir`, párrafo «POR QUÉ EXISTE ESTE FICHERO»), `Settings/SettingsKeys.swift` l.17-21, `Settings/SettingsView.swift` l.93-98, `Harness/HarnessModel.swift` l.567-569 y 654-656, `Forms/FormBroker.swift` l.16-17, `Harness/BrowserPanelState.swift` (cualquier resto que cite volante/toque), `NativeServices/BrowserRelayClient.swift` (resto que cite `relay.py:1033`, volante, toque), `GemmaTests/TroceadoDeFuente.swift` (fila nueva del censo)

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: `final class ElMandoNoExisteTests: XCTestCase` con `test_ningun_fuente_de_la_app_nombra_el_mando`, `test_el_panel_no_tiene_gestos_ni_campos`, `test_el_visor_solo_manda_acuses`.

- [ ] **Step 1: Escribir la prueba** (fuente CRUDO a propósito: incluye comentarios, para que tampoco vuelva la doc del mando). Localiza `Gemma/Gemma/` desde `#filePath` (`../../Gemma`), enumera con `FileManager.enumerator` todos los `.swift`.
  - `test_ningun_fuente_de_la_app_nombra_el_mando`: **primero** `XCTAssertGreaterThanOrEqual(ficheros.count, 100)` y que la lista contenga `Harness/BrowserPanelView.swift` y `NativeServices/BrowserRelayClient.swift` (control contra una red que lee otra carpeta; medir el número real en el paso 2 y fijarlo con margen hacia abajo); afirmar que no existen `Harness/BrowserMando.swift`, `Harness/BrowserInputEvents.swift`, `Harness/BrowserInputMapper.swift`; y que ningún fichero contiene ninguno de: `MandoDelNavegador`, `BrowserMando`, `BrowserInputEvents`, `BrowserInputMapper`, `QuienConduce`, `quienConduce`, `tomaElMando`, `devuelveElMando`, `manda(entrada`, `mando_tomar`, `mando_devolver`, `input_mouse`, `input_keyboard`, `input_touch`, `pulsacionesEnviadas`, `DimensionesDelCable`, `viewport_width`, `volante`. El mensaje de fallo nombra fichero y término. (NO se prohíbe la palabra suelta `mando`: `SmartMessageDrafter` dice «te mando un abrazo».)
  - `test_el_panel_no_tiene_gestos_ni_campos`: `BrowserPanelView.swift` no contiene `Gesture`, `onKeyPress`, `TextField`, `SecureField`, `.focused(`, `onTapGesture`.
  - `test_el_visor_solo_manda_acuses`: en `BrowserRelayClient.swift`, las líneas que contienen `.envia(` (excluida la declaración `func envia` y la implementación del protocolo) son exactamente 1 y esa línea contiene `ackPayload`.
  - Añadir la fila `ElMandoNoExisteTests  todo Gemma/Gemma  ausencias crudas, a propósito` al censo de `TroceadoDeFuente.swift`.
- [ ] **Step 2: Ejecutarla**: `xcodebuild test … -only-testing:GemmaTests/ElMandoNoExisteTests`. Esperado: FALLA en el primer test por `volante`/`quienConduce`… en comentarios que queden (es lo que el paso 3 limpia). Anotar el recuento real de ficheros.
- [ ] **Step 3: Limpiar las menciones vivas** hasta que pase. Cadenas exactas a sustituir (el resto de cada doc-comment se queda):
  - `TokenDeConducir.swift`, doc de `enum TokenDeConducir`: la frase «Y con el mando compartido ese token pasa a servir para **conducir** un Chrome real —teclas y clics— que en cuanto el usuario inicie sesión una vez tendrá su sesión de Google dentro.» → «Y es el token con el que el agente conduce el navegador (`HTTPAgentBrowserInvoker`) y con el que el visor del panel abre el stream (`BrowserRelayClient`).»
  - `SettingsKeys.swift` l.18-19 y `SettingsView.swift` l.94-95: «ese token conduce un Chrome con la sesión de Google del usuario dentro» / «Este token conduce un Chrome con la sesión de Google del usuario dentro» → «este token autoriza al agente a conducir el navegador y al panel a verlo».
  - `HarnessModel.swift` l.567: «este token conduce el Chrome del i3» → «este token autoriza el visor y al agente».
  - `FormBroker.swift` l.16-17: «Mismo patrón que `ReanudaUnaSolaVez` en `BrowserMando.swift`.» → borrar la frase.
  - Cualquier otro acierto que dé la prueba: reescribir sin el término, leyendo el contexto (no borrar comentarios que expliquen el stream).
- [ ] **Step 4: Medir que la prueba no es vacua** (mutación, en el árbol de trabajo, sin commitear; revertir con `git checkout -- <fichero>` tras cada una):
  1. Añadir `// tomaElMando` al final de `BrowserPanelState.swift` → `test_ningun_fuente…` ROJO nombrando ese fichero.
  2. `touch Gemma/Gemma/Harness/BrowserMando.swift` (vacío) → ROJO por existencia (`rm` después).
  3. Añadir `.onTapGesture {}` a la `Image` de `BrowserPanelView` → `test_el_panel_no_tiene_gestos…` ROJO.
  4. Añadir `try? await socket.envia("{}")` tras el ack en `runOnce` → `test_el_visor_solo_manda_acuses` ROJO.
  5. Control de ruta: cambiar temporalmente la ruta base de la prueba a `../../GemmaTests` → ROJO por el umbral de ficheros/la ausencia de `BrowserPanelView.swift` (demuestra que una ruta equivocada no pasa en verde).
  Las cinco tienen que ponerse rojas; si alguna sigue verde, la prueba está mal y se arregla antes de seguir. Anotar el resultado en el mensaje del commit.
- [ ] **Step 5: Verificar**: build iOS, suite macOS (diff vacío salvo las pruebas nuevas en verde), `graphify update .`
- [ ] **Step 6: Commit**: `test(mando): el mando no existe, medido sobre el fuente crudo` (+ líneas con las 5 mutaciones y su resultado).

### Task 5: Servidor `gemma-memory` — archivar la rama del mando y describir el despliegue

**Repo/worktree:** `/Users/hashdown/Projects/personal_agent/gemma-memory` (no tocar los cambios sin commitear de `memory-service/`: no son de este plan) y `…/gemma-memory/.worktrees/mando-subsistema-a`.

**Files:**
- Modify: `docker-compose.browser.yml` (en `feat/chrome-de-verdad`, comentario l.~55-60)
- Test: `browser/test_app.py` (se queda; su l.1257 ya fija «nada de control remoto»)

**Interfaces:**
- Consumes: nada de la app (el servidor de `main`/`feat/chrome-de-verdad` no habla de mando).
- Produces: rama `feat/mando-subsistema-a` archivada como etiqueta `archivo/mando-subsistema-a` (no se fusiona).

- [ ] **Step 1: Medir lo que corre en el i3** (solo lectura): `ssh <i3> 'docker exec gemma-browser-browser-1 sh -c "ls /app/mando.py; grep -c mando_tomar /app/relay.py"'`. Si `mando.py` existe → el i3 corre la rama A y el Paso 5 es necesario; si no existe → el i3 ya está sin mando y el Paso 5 no hace falta para este plan.
- [ ] **Step 2: Archivar la rama A**: `git -C …/gemma-memory tag archivo/mando-subsistema-a feat/mando-subsistema-a`; `git worktree remove …/.worktrees/mando-subsistema-a` (si tiene cambios sin commitear, PARAR y preguntar); `git branch -D feat/mando-subsistema-a`. No se fusiona nada de ella (ni siquiera `viewport_width`: solo servía al toque).
- [ ] **Step 3: Editar el comentario de `docker-compose.browser.yml`** en `feat/chrome-de-verdad` (commit SOLO de ese fichero, `git add docker-compose.browser.yml`): «De ahí el mando compartido: existe justamente para ese relevo.» → «Ese inicio de sesión se hace hoy en el Chrome real de la Mac; el panel del móvil solo mira (el mando se retiró: `personal_agent/docs/superpowers/plans/2026-11-12-quitar-el-mando.md`).»
- [ ] **Step 4: Verificar**: `cd …/gemma-memory && python3 -m pytest browser -q` → mismo resultado que antes del paso 3; `git grep -nE "mando_tomar|_reenvia_entrada|/v1/browser/mando" feat/chrome-de-verdad main` → vacío.
- [ ] **Step 5 (SOLO DESCRITO — requiere OK del usuario): redesplegar el i3** si el Paso 1 dijo que corre la rama A: en el i3, `git fetch && git checkout <rama acordada, p. ej. main o feat/chrome-de-verdad>` en el clon del servicio, `docker compose -f docker-compose.browser.yml up -d --build browser`, y comprobar: `curl -sH "Authorization: Bearer $TOKEN" http://<i3>:8083/v1/browser/mando` → **404**; el panel de la app muestra fotogramas. El volumen `perfil-navegador` no se toca (sobrevive al rebuild). La variable `BROWSER_ALLOWED_ORIGINS` que pudiera quedar en el `.env` del i3 se deja (Decisión mía 4).
- [ ] **Step 6: Commit** (el del paso 3): `docs(navegador): el panel ya no conduce; el mando se retiro`

### Task 6: Documentos — retirar el spec y señalar lo obsoleto; revisión final

**Files:**
- Modify: `docs/superpowers/specs/2026-11-08-mando-compartido-del-navegador-design.md` (cabecera), `docs/superpowers/plans/2026-11-08-mando-subsistema-a.md`, `docs/superpowers/plans/2026-11-08-mando-subsistema-b.md`, `docs/superpowers/notes/2026-11-09-protocolo-de-entrada-del-demonio.md` (cabecera)

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: nada de código.

- [ ] **Step 1: Banda de retirada** (NO se borra nada) justo bajo el título de los cuatro documentos:
  ```markdown
  > **RETIRADO el 2026-11-12** por `docs/superpowers/plans/2026-11-12-quitar-el-mando.md`. El usuario: «elimina ese control manual de raíz, solo necesito streaming del navegador abierto en mi mac hacia la app, sin controlarlo». Se conserva como historia; nada de lo que describe sobre la entrada del usuario existe ya en el código.
  ```
- [ ] **Step 2: Lista de memoria/ledger obsoletos** (los edita la sesión principal, que es la que tiene la memoria; aquí solo se listan en el commit):
  - `~/.claude/projects/-Users-hashdown-Projects-personal-agent/memory/cola-de-trabajo-navegador.md` — «subsistema A del mando en vuelo» y «tareas 6-7 del mando» quedan anuladas.
  - `…/memory/huella-del-browser.md` — «lo que falta es un login que solo el usuario puede hacer, con el mando»: el mando ya no existe; el login se hace en el Chrome de la Mac.
  - `…/memory/viewport-declarado-no-es-el-real.md` — el aviso «este fotograma no se puede situar» ya no existe; la medición del viewport sigue siendo verdad del demonio pero sin consumidor.
  - `…/memory/agent-browser-y-orden-de-trabajo.md` — referencias a «puntero del ratón» y al mando.
  - `MEMORY.md`, entradas de esas cuatro.
  - Ledger: **no encontré ninguno** del mando (`find … -iname '*ledger*'` vacío en ambos repos); si existe fuera de estos repos, no lo sé.
- [ ] **Step 3: Revisión adversarial con Codex** (regla de `CLAUDE.md` antes de dar la rama por hecha): `/codex:adversarial-review` sobre `main..feat/mando-subsistema-b`, pidiéndole explícitamente que busque (a) una vía por la que el panel aún envíe algo distinto del `ack`, (b) que el stream siga llegando en iOS, (c) que `ElMandoNoExisteTests` no sea vacua.
- [ ] **Step 4: Commit**: `docs(mando): el spec y sus planes quedan retirados`

---

## Decisiones mías (con su coste si me equivoco)

1. **Decisión mía: `TokenDeConducir` SE QUEDA, con su nombre y su cuenta de llavero.** El encargo lo listaba entre lo que se va, pero medido: es el bearer del servicio del navegador entero, lo leen `HarnessModel.makeRelayStream` (el STREAM) y `HarnessModel.browserInvoker` (el agente). Borrarlo deja el panel sin imagen y al agente sin navegador. No lo renombro: «conducir» sigue siendo verdad para el agente, y renombrar toca 13 ficheros y la superficie mejor probada de la app (seguridad del llavero) por un nombre. Coste si me equivoco: una tarea de renombrado mecánico más tarde (la cuenta `browserBearerToken` no cambiaría, así que sin migración de datos).
2. **Decisión mía: el viewport sale del fotograma** (no se deja «por si acaso»). Su único consumidor era el mapa del toque, y el servidor de `main` ni siquiera lo manda (solo la rama A). Coste si me equivoco: si algún día se quiere un puntero/overlay con coordenadas, hay que volver a decodificar dos enteros.
3. **Decisión mía: la rama A del servidor se archiva como etiqueta y no se fusiona nada de ella.** Coste: si había algo útil no relacionado con el mando dentro de esos 37 commits (p. ej. el arreglo «un open sin destino ya no pasa la puerta de la red», `49b27e4`, o la validación de `cli.py`), se pierde de la línea principal. Riesgo real: conviene que alguien mire `git log main..archivo/mando-subsistema-a -- browser/cli.py browser/stream.py` antes de borrar la rama; si hay arreglos independientes, se rescatan con `cherry-pick` en otro plan.
4. **Decisión mía: `BROWSER_ALLOWED_ORIGINS` en el `.env` del i3 se deja huérfana.** Nadie la lee sin la rama A; borrarla exige tocar un fichero con secretos en el i3. Coste: una línea muerta en un `.env`.
5. **Decisión mía: `BrowserPanelViewTests.swift` se borra entero** salvo dos pruebas trasladadas. Coste: si alguna de sus 43 pruebas medía algo del panel que no fuera mando, se pierde; las leí por nombre y por sus aserciones de fuente (todas leen `BrowserMando`/volante/toque/teclado/viewport).
6. **Decisión mía: la prueba de ausencia lee el fuente CRUDO, comentarios incluidos.** Obliga a limpiar la doc, y evita el troceador (que ya mintió una vez). Coste: un comentario futuro que diga «volante» con otro sentido pondrá la prueba roja; se arregla con la palabra exacta, a mano.

## Lo que no pude verificar

- Qué imagen corre en el i3 (Tarea 5, paso 1 lo mide).
- Que la suite esté verde hoy: no la he ejecutado (sesión de solo lectura); la línea base es el paso 1 de la Tarea 1.
- **El stream «desde mi Mac» que pide el usuario**: hoy el panel muestra el navegador del **i3** por su relé (`browserBaseURL` → `/v1/browser/stream`). Con `browserBaseURL` vacío el agente usa el Chrome real de la Mac (`ChromeRealDeLaMac`) y `makeRelayStream` devuelve `nil`: **no hay panel**. Este plan quita el mando; NO crea un stream del Chrome de la Mac hacia el móvil. Si eso es lo que el usuario espera, es otro proyecto.
