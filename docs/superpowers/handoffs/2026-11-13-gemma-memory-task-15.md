# Relevo de memoria de Gemma para Claude Code

La revisión de la tarea 15 está cerrada en las ramas aisladas. La siguiente tarea del [plan aprobado](../plans/2026-11-05-cerebro-gemma-implementation.md) es la 16. El usuario aprobó las 17 tareas, el trabajo por subagentes con Superpowers y las copias aisladas. El [registro de trabajo](../../../.superpowers/sdd/2026-11-05-cerebro-gemma-implementation/progress.md) conserva las decisiones y las pruebas anteriores.

## Dónde retomar

La app está en `/Users/hashdown/Projects/personal_agent/.worktrees/gemma-brain-20261105`. El backend es el repositorio Git independiente `gemma-memory` dentro de esa carpeta. Ambas ramas se llaman `codex/gemma-brain-20261105`. Usa `git status --short` y `git log -3 --oneline` en cada repositorio. Gemini trabaja las herramientas de la app principal en otra copia. Conserva los archivos ajenos, incluido el estado previo de `graphify-out` y los relevos anteriores.

El usuario prohibió volver a arrancar Ollama/Gemma local por un apagado de la Mac bajo presión de memoria. Ejecuta una sola compilación a la vez y un solo trabajo de Swift/Xcode, con datos sintéticos, `URLProtocol` o proveedores grabadores. Para una prueba real autorizada, usa Claude Code en la nube y avisa antes si será larga. El flujo de trabajo no incluye publicar, mezclar ramas, actualizar el servicio instalado ni migrar datos reales.

## Estado verificado

- Las tareas 1–14 están completas. El backend de la 14 quedó en `bc1d539`. El seguimiento `8720e39` devuelve el recibo de admisión cuando el contexto opcional excede el presupuesto. El modelo nativo puede responder con historial local y completar el turno que ya guardó. La petición explícita de contexto conserva el 422. Pasaron 607 pruebas del backend y la revisión independiente aprobó el cambio.
- La app parte de `56b725f`, que conserva los mensajes recientes cuando falla la memoria remota y exige evidencia para tratar un nombre como confirmado. La tarea 15 enlaza `BrainContract`, guarda el mensaje actual una vez, usa el mismo ID en reintentos ambiguos, distingue persistencia pendiente y prepara memoria antes de la primera generación. El avance intermedio quedó en `005b1ee`.
- Una conexión nueva empieza con su propio historial. Puede usar el punto de continuidad de un proyecto sin abrir un chat anterior. El Inspector de transcripciones permite restaurar deliberadamente un hilo. El perfil de gustos usa el hilo capturado y distingue gustos duraderos, comparaciones e intención del momento. Se verificó la selección de herramientas nativas de turnos y calendario con un presupuesto de 4096. Las pruebas no ejecutan operaciones contra Amazon.
- La búsqueda del dictado activo usa `mode=prefetch`. Solo una coincidencia exacta de texto, hilo y cliente transfiere el ID de operación a la admisión. El backend `e6dc2fa` puede reutilizar un vector durante 15 segundos y revalida fuentes y permisos al construir el contexto final. Conserva como máximo 16 entradas efímeras. Un fragmento corregido, cancelado o de otra conexión no entra en el historial ni en la primera generación. El ensayo sintético comprueba llamadas al embedder y persistencia. La suite completa pasó 608 pruebas, en `/private/tmp/gemma-task15-handoff-backend.log`. Aún falta medir la latencia en el uso real.

## Correcciones del cierre de la tarea 15

1. **Borrado.** Un recibo válido invalida el historial local del hilo, el contexto de la siguiente generación y las respuestas de voz que siguen en curso en esa app. Las pruebas comprueban una caída posterior del servicio y una respuesta de voz tardía. El vaciado afecta a toda la ventana local del hilo. El cliente no sincroniza su copia en memoria con borrados hechos desde otro dispositivo mientras está desconectado.
2. **Originales.** `load_messages` acepta el ID de evidencia que vio el modelo. Comprueba el permiso del turno, el hilo y la entrega íntegra del original. El rango queda disponible para servidores heredados dentro del hilo actual.
3. **Herramientas.** La persistencia del resultado mínimo de una herramienta ejecutada continúa después de cancelar la generación. Conserva el turno y el ID del resultado, usa el reintento acotado existente y omite argumentos y respuestas crudas. Los runtimes nativos actuales entregan la solicitud de herramienta a `Agent`, que ejecuta y registra el resultado.
4. **Presupuesto.** El backend `a893c27` deja el mensaje actual fuera del historial del bundle de admisión porque ya forma parte de la consulta. La ruta real entrega la orientación y el punto del proyecto a 4096. La prueba de app comprueba el primer envío con las herramientas de producción y el valor de salida por defecto. La reserva de memoria puede reducir la salida disponible en una ventana pequeña.
5. Pasaron 609 pruebas de backend, 200 pruebas sintéticas de macOS y la compilación de iOS sin firma. Logs en `/private/tmp/gemma-task15-review-backend-full.log`, `/private/tmp/gemma-task15-review-wide.log` y `/private/tmp/gemma-task15-review-ios.log`. Se excluyeron `AtoZTests`, `KeychainStoreTests`, `HarnessModelProviderTests`, `ServerManagerLiveTests` y `MemoryServiceLiveTests` por sus efectos reales. Codex cerró la revisión personalmente a petición del usuario, con los hallazgos de la revisión independiente anterior.

La app instalada queda pendiente de verificación con credenciales configuradas. Los transcripts originales del incidente de «Lucas» y la pérdida del mensaje anterior no estaban en el servidor consultado. El respaldo local se probó con fallos simulados. El perfil de gustos no implica una integración de catálogo ni de reproducción musical. El guardado inmediato de hechos libres fuera de los tipos de aprendizaje admitidos todavía depende de la consolidación.

## Verificación y tareas siguientes

Usa el directorio temporal `/private/tmp/gemma-brain-swift-build` para SwiftPM. Para la app están preparados `/private/tmp/gemma-task15-dd` y `/private/tmp/gemma-task15-source-packages`. La verificación nativa usa `build-for-testing`, firma ad hoc solo del bundle temporal y `test-without-building` con `Gemma_Gemma_macosx27.0-arm64.xctestrun`. Fija `-jobs 1`, `-parallel-testing-enabled NO` y las banderas `GEMMA_LIVE_SERVER=0`, `TEST_RUNNER_GEMMA_LIVE_SERVER=0`, `GEMMA_LIVE_DOCKER=0`. El relevo de implementación de la tarea 15 en `.superpowers/sdd/2026-11-05-cerebro-gemma-implementation/task-15-implementer-report.md` conserva el detalle de los incrementos.

```sh
swift test --package-path memory-service --jobs 1 --scratch-path /private/tmp/gemma-brain-swift-build
```

En el backend están preparados los documentos `task-16-brief.md` y `task-17-brief.md` bajo `.superpowers/sdd/2026-11-05-cerebro-gemma-implementation/`. La 16 debe versionar el espacio de embeddings, preservar el índice activo hasta validar un reemplazo y verificar el protocolo de herramientas de Anthropic con peticiones interceptadas. La 17 debe ejecutar el corpus sintético por rutas reales, informar cobertura y procedencia, y distinguir las mediciones automáticas de la calidad conversacional con un modelo real.
