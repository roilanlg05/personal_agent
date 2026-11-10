# Rescate de la ronda 8 — ruta de contraseña del mando

Estado: implementación escrita; verificación oficial por `xcodebuild test` BLOQUEADA por el sandbox de esta sesión. Se compilaron los tests de macOS e iOS y se ejecutó, como evidencia suplementaria, la suite ENTERA mediante XCTest directo, incluida una base sobre 411606f y las mutaciones. Esta alternativa no se declara equivalente al host firmado de Xcode.

## Cambios y efecto para el usuario

| Cambio | Antes | Después |
|---|---|---|
| A: migración compartida de TokenDeConducir y TokenDeMemoria | Un rechazo del llavero borraba el único token y ya no había origen para reintentar. | Solo se elimina el origen vacío, ya sustituido por el almacén, o escrito y releído con el mismo valor. Si falla, queda para reintentar; no garantiza autenticación hasta que el llavero funcione. |
| B: devolver y contacto cerrado | El mismo dedo podía abrir otro mousePressed durante la devolución o tras recuperar el mando. | `devuelve()` marca `devolviendo` sincrónicamente, antes de crear la Task; bloquea entrada nueva, conserva el cierre defensivo y rechaza el startLocation cerrado hasta su onEnded o un contacto distinto. Si devolver devuelve false, vuelve a admitir entrada nueva. |
| C: cola y generaciones de teclado | Un clic adelantaba al pegado y movía el foco; una cola de teclado anterior sobrevivía a cancelar la última. | Teclado y puntero usan la misma cadena por sesión; cada lote de teclado captura una generación y la consulta antes de cada envío, después de esperar a la cola anterior y del reparto de 17 ms. Perder, retirar o empezar a devolver invalida todos los lotes de teclado viejos. |

El cierre defensivo encola directamente y NO pasa por la puerta de entrada de gestos. No se cancela la cadena de producción. No se alteran el protocolo, el límite de 4096 bytes, los seis tipos de mensaje ni relay.py. No se añade registro de entrada, coordenadas, longitud ni una línea por pulsación. No se modifica TroceadoDeFuente ni se decide SwiftSyntax. No se ejecuta graphify update.

El reparto sigue siendo entre mensajes del MISMO lote, solo cuando indice > 0. Un clic puede esperar detrás de un pegado largo: latencia aceptada para preservar el foco. El primer false corta SU lote, llama a alFallar sin argumentos y deja que los lotes siguientes lo intenten (se añadió una prueba ejecutable de este contrato).

## Qué sobrevive a cada transición

Todas las operaciones de transición son síncronas en MainActor. El consumidor compara quienConduce antes y después de aplicar el evento y notifica en el mismo paso, sin esperar a un observador de vista. El fin del flujo invalida también antes de soltar la sesión.

| Transición | Teclado pendiente | Puntero ya encolado | Gesto abierto / cierre | Entrada nueva / contacto |
|---|---|---|---|---|
| `mando`: pérdida de `.yo` hacia agente u otro visor | Generación invalidada; no revive con la siguiente concesión. | Se drena en su orden. El relé puede descartarlo al perder el portador. | Se olvida; el cliente no puede entregar un cierre tras perder el portador. | La vista pierde la captura; el contacto se marca cerrado. |
| `.closed` con `.yo` | Misma invalidación en el consumidor del evento. | No se cancela; el canal muerto puede rechazarlo. | Se olvida; queda el hueco del relé por red muerta. | Sin captura; el contacto cerrado permanece identificado. |
| Fin del flujo, incluso sin `.closed` | Invalidado antes de liberar la sesión. | Tareas previas conservan el mando capturado y terminan o fallan; sin cancelar. | Se olvida, sin envío nuevo sobre el canal muerto. | La sesión se retira del coordinador. |
| Empezar a devolver | Incrementa generación ANTES de encolar el cierre. | Se drena delante del cierre. | Se encola un soltar defensivo exento del bloqueo; espera acotada a 1 s antes de mando_devolver. | `devolviendo = true` ANTES de la Task; se rechaza puntero y teclado nuevos. Contacto cerrado conservado. |
| Retirar panel | Incrementa generación ANTES de encolar el cierre. | Se drena delante del cierre; coordinador espera como mucho 1 s antes de cerrar. | Soltar defensivo, luego mando y cola de la sesión a nil. | Sin mando, no salen entradas nuevas; la vista se congela. |
| Nueva concesión `.yo` tras un cambio | Nueva generación; ningún lote viejo resucita. | Sigue el orden de lo ya encolado. | Se olvida el gesto viejo. | Se limpia devolviendo; el mismo startLocation cerrado sigue rechazado aunque falte onEnded. |
| Devolver falla con false | La generación anterior sigue invalidada. | Se drena lo anterior. | El gesto ya quedó cerrado con su soltar. | Se limpia devolviendo; un contacto nuevo vuelve a funcionar. |

Un mensaje que YA entró en `await mando.manda(entrada:)` no se puede retirar. Puede terminar de salir o fallar; la generación frena el siguiente. Tampoco se promete que una cola de puntero bloqueada en red se drene antes de 1 s: se conserva el plazo y se declara su coste.

## Pruebas añadidas y límites de su cobertura

Se añadieron 15 casos: 5 de migración, 9 de sesión/transición y 1 del contrato de lotes fallidos. Los nuevos casos con sesión/coordinador están dentro de `#if os(macOS)`; el caso puro de lotes fallidos corre en ambas plataformas. Las esperas nuevas de transición tienen plazo y devuelven Bool afirmado. La prueba de dos lotes pendientes usa MandoDeMentira.antesDeMandar para retener el puntero, pierde y recupera el volante tanto por mando como por closed, abre la puerta y exige exactamente pulsar, soltar y la tecla NUEVA: ninguna tecla de los dos lotes viejos puede salir. La prueba complementaria empieza el pegado antes de perder el mando. Devolver y retirar se prueban con 400 mensajes pendientes y se exige soltar dentro del plazo de 1 s.

La conexión de startLocation a los DOS callbacks y la llamada síncrona del botón se comprueban como presencias sobre fuente troceado. Las ausencias de cancelación y de cola propia de la barra se comprueban sobre crudo. No se atribuye a esas pruebas ejecución real de SwiftUI.

La lista blanca produjo un rojo aislado usando el propio TroceadoDeFuente del repositorio: rechazaba 14 identificadores nuevos sin revisar. Se incorporaron A MANO uno a uno con motivo: admite, admitido, cambioElVolante, cierraElContacto, contacto, contactoCerrado, contactoEnCurso, devolviendo, generacion, generacionDeTeclado, salio, startLocation, teclea, vigente. El mismo ejecutable del troceador devolvió luego [] con exit 0. No se amplió la gramática del troceador.

La primera exploración de la suite directa detectó además dos aserciones antiguas de cableado que necesitaban actualizarse: el argumento nuevo contacto y la indentación del bloque del botón. Se corrigieron contra el texto troceado real; no se tocó el troceador para hacerlas pasar. Recuento exploratorio: 1426 passed / 7 failed / 21 skipped = 1454, 13:32:43 EST (dos fallos propios de las aserciones, cinco de la base de este entorno). No es el control final.

## Entorno y recetas de medida

Fecha: 2026-11-10, America/Kentucky/Louisville (EST). Rama feat/mando-subsistema-b; base 411606f. llama.xcframework existe y se incorporó a la compilación. Se trabajó siempre en el worktree pedido.

La invocación literal solicitada falló antes de pruebas (exit 74) por escrituras prohibidas en SourcePackages, la caché de módulos y la caché de manifiestos de SwiftPM. No era el lock de otra compilación. Se copió SourcePackages por clone a /tmp, se usó DerivedData en /tmp y CFFIXED_USER_HOME y las cachés de módulos en /tmp. La compilación anidada de macros/manifiestos necesitó desactivar SU sandbox anidado; el sandbox exterior siguió activo. Sin firma (la sesión no accede a los certificados), la compilación de pruebas termina, pero Xcode aborta al contactar com.apple.testmanagerd.control: `Connection init failed at lookup with error 159 - Sandbox restriction`.

Para cada fila de la tabla se intentó `xcodebuild ... test` de TODA la suite, con esos ajustes de entorno. En TODAS dio SIGTRAP (-5 desde subprocess, 133 desde shell), 0 passed / 0 failed / 0 skipped = TOTAL 0. NO ES VERDE. La receta de recuento pedida (`case '[^']+' (passed|failed|skipped)`, failed deduplicados) se aplicó a esos logs; no pudo validarse contra una ejecución oficial de la base porque el host no arranca.

Como comprobación suplementaria se ejecutó el bundle COMPLETO ya compilado con el runner de XCTest, sin filtros:

```sh
env CFFIXED_USER_HOME=/tmp/round8-cache \
 DYLD_FRAMEWORK_PATH=/tmp/round8-cache/build/Build/Products/Debug/Gemma.app/Contents/Frameworks \
 DYLD_INSERT_LIBRARIES=/tmp/round8-cache/build/Build/Products/Debug/Gemma.app/Contents/MacOS/Gemma.debug.dylib \
 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
 /tmp/round8-cache/build/Build/Products/Debug/Gemma.app/Contents/PlugIns/GemmaTests.xctest
```

Este runner emite `Test Case '-[GemmaTests.Clase metodo]' passed|failed|skipped`; se contaron passed y skipped sin deduplicar y failed por caso único, sin contar aserciones. Las sumas se contrastaron con Executed N tests del runner. El runner directo devuelve exit 1 por los fallos de base. No se normalizaron sus logs para aparentar el formato del host de Xcode.

Base DIRECTA medida: 1413 / 5 / 21 = 1439. Base OFICIAL aportada por el usuario: 1420 / 4 / 15 = 1439. En la directa hay seis saltos adicionales por firma/acceso y un fallo extra en MemoryServiceLiveTests.test_recall_degrades_gracefully_when_service_unreachable (red restringida). Los otros cuatro coinciden con la base aportada. Estos resultados no son intercambiables.

La compilación `build-for-testing` de macOS y la de `generic/platform=iOS Simulator` terminaron con TEST BUILD SUCCEEDED usando los ajustes de entorno descritos; iOS compiló para arm64 y x86_64. No se ejecutó la suite iOS.

## Tabla de mutaciones

Los recuentos de esta tabla son de TODA la suite DIRECTA. Cada fila tuvo además el intento completo por Xcode descrito arriba, bloqueado con total 0. La base contiene 1439 casos; el control y cada mutación contienen los mismos 1454 casos (15 nuevos). No se cuentan saltos como evidencia de que una mutación murió.

| Fase / mutación | Qué se retira | Hora de fin EST | Passed | Failed únicos | Skipped | TOTAL | Fallos nuevos |
|---|---|---|---:|---:|---:|---:|---:|
| base-411606f | Base original (1439 casos) | 13:34:51 | 1413 | 5 | 21 | 1439 | 0 |
| control | Control con los 15 casos nuevos | 13:35:12 | 1428 | 5 | 21 | 1454 | 0 |
| A1-borra-tras-rechazo | Ignorar rechazo y releer: borrar origen aun si escribir falla | 13:35:30 | 1423 | 10 | 21 | 1454 | 5 |
| A2-no-verifica-lectura | Confiar solo en escribir, sin releer | 13:35:52 | 1425 | 8 | 21 | 1454 | 3 |
| B1-no-bloquea-devolucion | No activar devolviendo al empezar | 13:36:12 | 1425 | 8 | 21 | 1454 | 3 |
| B2-acepta-contacto-cerrado | Aceptar el startLocation cerrado tras concesión | 13:36:34 | 1427 | 6 | 21 | 1454 | 1 |
| B3-no-recupera-tras-fallo | No limpiar devolviendo si devolver falla | 13:36:56 | 1427 | 6 | 21 | 1454 | 1 |
| C1-generacion-neutral | Hacer siempre verdadera la vigencia del teclado | 13:37:21 | 1423 | 10 | 21 | 1454 | 5 |
| C2-cola-independiente | Teclado sin esperar a su predecesor (no simula por sí solo el clic que adelanta) | 13:37:45 | 1426 | 7 | 21 | 1454 | 2 |
| C3-devolver-sin-invalidar | No incrementar generación al empezar a devolver | 13:38:09 | 1427 | 6 | 21 | 1454 | 1 |
| C4-retirar-sin-invalidar | No incrementar generación al retirar | 13:38:30 | 1427 | 6 | 21 | 1454 | 1 |
| C5-no-avisa-transicion | Omitir notificación síncrona del cambio del volante | 13:38:55 | 1424 | 9 | 21 | 1454 | 4 |
| C6-fin-sin-invalidar | Fin de flujo solo olvida gesto, sin invalidar teclado | 13:39:17 | 1427 | 6 | 21 | 1454 | 1 |
| final | Primer control restaurado | 13:39:38 | 1428 | 5 | 21 | 1454 | 0 |
| C7-puntero-sin-predecesor | Puntero sin esperar a la cadena; clic adelanta al pegado | 13:40:15 | 1425 | 8 | 21 | 1454 | 3 |
| B4-boton-difiere-el-bloqueo | El botón difiere devuelve() dentro de una Task | 13:40:35 | 1427 | 6 | 21 | 1454 | 1 |
| final-restaurado | Control final restaurado | 13:40:57 | 1428 | 5 | 21 | 1454 | 0 |
| entrega-final | Entrega: solo comentario del llavero corregido, sin cambio de lógica | 13:43:43 | 1428 | 5 | 21 | 1454 | 0 |

Los fallos nuevos por mutación están detallados en el JSON de evidencia. No se introdujeron identificadores ajenos a las listas blancas con las mutaciones; C1 es una expresión neutral `X || !X` expresada con la igualdad y su desigualdad sobre la MISMA generación. Así se mide la eliminación de la invalidación sin un rojo de lista blanca por el instrumento.

**A1-borra-tras-rechazo**: `TokenDeConducirTests.test_la_migracion_con_lectura_distinta_conserva_el_origen`, `TokenDeConducirTests.test_la_migracion_que_no_lee_de_vuelta_lo_escrito_conserva_el_origen`, `TokenDeConducirTests.test_la_migracion_que_no_puede_escribir_conserva_el_origen_y_se_reintenta`, `TokenDeMemoriaTests.test_la_migracion_que_no_lee_de_vuelta_lo_escrito_conserva_el_origen`, `TokenDeMemoriaTests.test_la_migracion_que_no_puede_escribir_conserva_el_origen_y_se_reintenta`.

**A2-no-verifica-lectura**: `TokenDeConducirTests.test_la_migracion_con_lectura_distinta_conserva_el_origen`, `TokenDeConducirTests.test_la_migracion_que_no_lee_de_vuelta_lo_escrito_conserva_el_origen`, `TokenDeMemoriaTests.test_la_migracion_que_no_lee_de_vuelta_lo_escrito_conserva_el_origen`.

**B1-no-bloquea-devolucion**: `BrowserMandoSesionTests.test_devolver_con_un_pegado_en_curso_suelta_el_boton_antes_del_plazo`, `BrowserMandoSesionTests.test_devolver_no_deja_que_el_dedo_apoyado_abra_otro_gesto`, `BrowserMandoSesionTests.test_si_devolver_no_sale_la_sesion_vuelve_a_aceptar_entrada`.

**B2-acepta-contacto-cerrado**: `BrowserMandoSesionTests.test_devolver_no_deja_que_el_dedo_apoyado_abra_otro_gesto`.

**B3-no-recupera-tras-fallo**: `BrowserMandoSesionTests.test_si_devolver_no_sale_la_sesion_vuelve_a_aceptar_entrada`.

**C1-generacion-neutral**: `BrowserMandoSesionTests.test_devolver_con_un_pegado_en_curso_suelta_el_boton_antes_del_plazo`, `BrowserMandoSesionTests.test_el_fin_del_flujo_corta_las_teclas_pendientes`, `BrowserMandoSesionTests.test_lotes_pendientes_no_reviven_tras_perdida_y_concesion`, `BrowserMandoSesionTests.test_perder_el_volante_corta_todos_los_lotes_de_teclado_y_recuperarlo_no_los_revive`, `BrowserMandoSesionTests.test_retirar_con_un_pegado_en_curso_suelta_el_boton_antes_del_plazo`.

**C2-cola-independiente**: `BrowserMandoSesionTests.test_lotes_pendientes_no_reviven_tras_perdida_y_concesion`, `BrowserMandoSesionTests.test_perder_el_volante_corta_todos_los_lotes_de_teclado_y_recuperarlo_no_los_revive`.

**C3-devolver-sin-invalidar**: `BrowserMandoSesionTests.test_devolver_con_un_pegado_en_curso_suelta_el_boton_antes_del_plazo`.

**C4-retirar-sin-invalidar**: `BrowserMandoSesionTests.test_retirar_con_un_pegado_en_curso_suelta_el_boton_antes_del_plazo`.

**C5-no-avisa-transicion**: `BrowserMandoSesionTests.test_devolver_no_deja_que_el_dedo_apoyado_abra_otro_gesto`, `BrowserMandoSesionTests.test_lotes_pendientes_no_reviven_tras_perdida_y_concesion`, `BrowserMandoSesionTests.test_perder_el_volante_corta_todos_los_lotes_de_teclado_y_recuperarlo_no_los_revive`, `BrowserPanelViewTests.test_el_cuerpo_del_mando_cablea_las_puertas_que_la_suite_no_puede_ejecutar`.

**C6-fin-sin-invalidar**: `BrowserMandoSesionTests.test_el_fin_del_flujo_corta_las_teclas_pendientes`.

**C7-puntero-sin-predecesor**: `BrowserMandoSesionTests.test_el_soltar_defensivo_va_detras_de_la_cola_y_en_el_ultimo_punto_bueno`, `BrowserMandoSesionTests.test_lotes_pendientes_no_reviven_tras_perdida_y_concesion`, `BrowserMandoSesionTests.test_un_clic_detras_de_un_pegado_sale_detras_del_pegado`.

**B4-boton-difiere-el-bloqueo**: `BrowserPanelViewTests.test_el_cuerpo_del_mando_cablea_las_puertas_que_la_suite_no_puede_ejecutar`.

Cada mutación se aplicó con ancla única y texto exacto; las inserciones/supresiones de invalidación usaron ancla de dos o tres líneas que incluye el método o la operación siguiente. Restauración tras CADA mutación y tras la base: (1) bytes/texto exactos del control guardado, (2) SHA256 del disco, (3) SHA256 de `git show :ruta`, comparado con el índice guardado antes de la fase. No se usó git checkout, ni se cancelaron las colas como instrumento. El índice se mantuvo sin cambiar durante las mutaciones. El driver puso plazos externos de 180 s al intento de Xcode y 120 s a la suite directa; ningún timeout cuenta como rojo.

## Huecos que quedan y disparadores exactos

1. **Red/relé, sin arreglo cliente:** corte de datos móviles, cierre del socket o pérdida del portador mientras existe mousePressed. El soltar del cliente ya no puede alcanzar al demonio; hace falta decisión y arreglo en el relé de otro repositorio. No se promete un mouseReleased entregado con la red muerta.
2. **Envío ya dentro de await:** invalidar mientras manda está suspendido no retira ese mensaje. Se frena el siguiente, no el ya entregado a la llamada asíncrona.
3. **Plazo de 1 s frente a red bloqueada:** si un envío de puntero anterior no vuelve en 1 s, el cierre defensivo puede no salir antes de devolver/cerrar. El teclado largo ya no es la causa de esa demora; no se cambia el juicio de 1 s.
4. **startLocation no es un ID único:** si falta onEnded y el siguiente contacto nuevo empieza EXACTAMENTE en el mismo punto que el cerrado (ratón quieto en macOS), se ignora ese contacto hasta que se levante. Pérdida de un clic en la dirección segura. No se afirma que startLocation distinto sea necesario para todos los contactos nuevos.
5. **SwiftUI real no medido:** retención/recreación del DragGesture durante desactivar y conceder de nuevo, con el dedo aún apoyado. Se mide la sesión y la conexión textual de startLocation; falta medición de interfaz en dispositivo. Si SwiftUI reconstruyera la identidad/origen de un contacto vivo, hay que medir esa secuencia en dispositivo antes de atribuirle la cobertura de las pruebas unitarias.
6. **Llavero: nil ambiguo y escritura destructiva previa:** un error de SecItemCopyMatching se confunde con ausencia y escribir borra primero el elemento previo; puede perderse un token bueno del llavero. Esta ronda solo protege el origen de la migración.
7. **Llavero permanentemente fallido:** la copia antigua en UserDefaults puede quedar en claro indefinidamente. Conservarla permite reintentar; no garantiza que los lectores funcionen antes de recuperarse el llavero.
8. **Suite oficial y firma:** el sandbox bloquea testmanagerd y certificados; los tests de llavero real se saltan por firma. Hay que repetir la receta original fuera del sandbox. Los resultados directos no cierran este hueco.
9. **iOS:** build-for-testing compila, pero no se ejecutó ni la UI ni el host de pruebas de iOS, por el aborto preexistente documentado.
10. **Clases de prueba de fuente ya declaradas:** compilación condicional y fugas de llamadas partidas en dos líneas siguen fuera de lo que el troceado asegura. No se decidió SwiftSyntax.

## Discrepancias y entrega

No se cambian las decisiones A/B/C del encargo. Discrepancia medida de entorno: aquí la invocación oficial no ejecuta casos y la ejecución directa cambia seis saltos y un fallo respecto de la base aportada, aun con el MISMO total 1439; se declara sin presentar un cero como verde. startLocation se implementa como identidad aproximada con la colisión exacta declarada, no como identificador único garantizado.

La propuesta parcial se reutilizó después de contrastarla con el fuente; se completaron el cableado de pruebas de fuente, la lista blanca, la lectura distinta de A, los dos lotes completamente pendientes ante mando/closed y el contrato de lotes posteriores al fallo. No se heredó su verificación, porque no la tenía.

Código y pruebas commiteados: `08d9737e38559c3b1e4c09ac5410146cfea66d4b` (`fix: protege la ruta de contraseña del mando compartido`). Solo siete rutas concretas; no se usó git add -A y no se tocó main. Recuento final directo: 1428 passed / 5 failed / 21 skipped = TOTAL 1454, 13:43:43 EST. Cero casos propios fallidos respecto de la base directa; 13 de 13 mutaciones producen fallos nuevos (ninguna depende de saltos ni de identificadores nuevos).

Evidencia de las ejecuciones: `task-7-round8-codex-evidence.json` junto a este informe en el worktree; contiene cada fila, sus fallos únicos, los SHA de disco/índice, el texto exacto de las mutaciones y los comandos de medida. El driver adjunto registra el harness ejecutado sobre el árbol preparado antes del commit; para repetirlo desde un árbol ya limpio hay que fijar las siete rutas y la revisión base 411606f, en lugar de derivarlas del diff sin commitear. Logs completos en `/tmp/round8-evidence/`; drivers en `/tmp/round8-driver.py` y `/tmp/round8-extra.py`. No se añaden los logs voluminosos ni default.profraw al commit. Después de las mutaciones se corrigió solo el comentario del llavero que decía «en claro pero funcionando»: los lectores solo leen el almacén, así que no hay garantía de autenticación. Se repitió la suite entera sobre esta entrega y se guardaron sus hashes por separado de los de restauración de las mutaciones. Los siete hashes finales de disco/índice coinciden con el código commiteado.

**Estado de verificación oficial: BLOCKED.** Falta ejecutar la receta original con host firmado fuera del sandbox. Las medidas directas y las compilaciones son evidencia suplementaria, no se declaran verde oficial. UI real y hueco del relé continúan abiertos como se detalla arriba.

**Escritura del destino solicitado rechazada:** `cp` devolvió `Operation not permitted`; está fuera de las raíces escribibles del sandbox. El informe y el JSON de evidencia se entregan commiteados dentro del worktree, en `docs/superpowers/handoffs/task-7-round8-codex-report.md` y `docs/superpowers/handoffs/task-7-round8-codex-evidence.json`. No se solicitó escalada porque esta sesión tiene approval policy never.

Destino solicitado del informe: `/Users/hashdown/Projects/personal_agent/.superpowers/sdd/2026-11-08-mando-subsistema-b/task-7-round8-codex-report.md`.

