# Handoff del cerebro de Gemma

## Punto de reanudación

Las tareas 1–10 están cerradas. **Empieza por la tarea 11.** El usuario pidió detener esta sesión después de terminar la 10 y preparar este relevo. Ya autorizó las 17 tareas y las copias aisladas. Lee el [diseño vigente](../plans/2026-11-05-cerebro-gemma.md), el [plan de implementación](../plans/2026-11-05-cerebro-gemma-implementation.md) y el registro central [progress.md](../../../.superpowers/sdd/2026-11-05-cerebro-gemma-implementation/progress.md). Las notas de relevo anteriores describen estados históricos.

- App y documentos en `/Users/hashdown/Projects/personal_agent/.worktrees/gemma-brain-20261105`.
- Backend en el repositorio Git independiente `gemma-memory` dentro de ese worktree. Su último commit verificado es `5e03851`.
- Ambas ramas se llaman `codex/gemma-brain-20261105`. Comprueba `git status --short` y `git log -5 --oneline` en ambas antes de escribir. Otra sesión puede haber avanzado.
- Hitos de backend para ubicar el historial. Task 6 `9f708a9`, Task 7 `a8f9e06`, Task 8 `01ee013`, Task 9 `eb3be3b`, seguimiento de citas y HTTP `3435fa0`, Task 10 `5e03851`.
- Cambios de diseño más recientes en la app. `65ea556` especifica continuidad de proyectos y `3439305` incorpora la aclaración sobre el contexto de arranque y la recuperación activada al hablar.

## Lo entregado en la tarea 10

- `AffectiveContextService` recibe propuestas estructuradas de un clasificador inyectable. Valida sujeto, calificación y un intervalo UTF-8 de un turno de usuario comprometido. El clasificador puede recibir hasta cuatro fuentes anteriores del mismo hilo. Todo el soporte enviado queda registrado y se vuelve a verificar al regresar el resultado.
- Las interpretaciones y las señales de foco, interés y tensión duran como máximo lo que permita la primera fuente que caduque. Se mantienen en memoria del proceso, con límite por sesión, y se descartan al reiniciar, terminar la sesión o retirar evidencia. Un turno admitido más nuevo invalida una señal vieja aunque el nuevo siga pendiente. Una señal de tono sin etiqueta emocional también se puede descartar por su ID.
- `TastePreferenceService.profile` lee afirmaciones versionadas. Separa agrado y desagrado, comparaciones y petición del momento. Conserva procedencia, intensidad, ámbito y vigencia. Una sugerencia propia seguida de una reacción ambigua no establece un gusto. La intención explícita más nueva se resuelve antes de comprobar caducidad y se desempata por la secuencia del hilo si coinciden los tiempos.
- Los cambios de gustos pasan por `BrainTurnProposal` y el commit validado. El campo directo `BrainCommitRequest.tastes` sigue reservado. La guía de trato expresada y las señales de tono se incorporan al contexto solo si caben en el presupuesto, con fuentes marcadas como soporte derivado. El tono inferido no se proyecta a la identidad. La tarea 10 no añade migraciones.

## Qué se verificó

- Tarea 10 aprobada tras revisión independiente de especificación y calidad. Suite final **510/510** en backend, con 108 de servicio, 385 de núcleo y 17 de contrato. Los 13 escenarios específicos de Task 10 pasaron. Contrato compartido comprobado para iOS 17. `git diff --check` limpio y Graphify actualizado mediante AST.
- La prueba inicial RED falló porque faltaban los servicios. Las regresiones de revisión reprodujeron 8, 10, 2 y 1 fallos esperados antes de aplicar sus cambios. Los logs locales comienzan por `/private/tmp/gemma-task10-`. El resultado final está en `gemma-task10-final-verified.log`. Los logs temporales pueden desaparecer tras reiniciar.
- `3435fa0` reduce la reserva obligatoria a un aviso agregado por clase de omisión. La regresión de 20 originales pasó dentro del presupuesto y conserva una cita disponible. Un margen insuficiente todavía devuelve error explícito. `sourceReferences` contiene metadatos. `sourceUses` declara qué se entregó y `exactCitationSourceReferences(includingRenderedContext:forwardedRecentUnitIDs:)` exige indicar qué se reenvió realmente.
- `POST /v1/brain/context` se probó por HTTP de loopback con autenticación, selección explícita y base sintética. Claude Code con Haiku reprodujo literalmente una cita sintética de esa respuesta en 1,7 segundos. Ese ensayo confirma una ruta y un ejemplo, y la precisión semántica del clasificador afectivo sigue sin medir. El gateway, la app y el despliegue aún tienen sus propias pruebas pendientes.
- **Nunca vuelvas a ejecutar la prueba local con Ollama o cargar Gemma local para esta validación.** La prueba anterior provocó un apagado por uso de memoria y fue eliminada por instrucción expresa del usuario. Usa dobles de prueba en el desarrollo. Si se requiere una prueba autorizada con modelo real, usa Claude Code en la nube con datos sintéticos y avisa antes si prevés una espera larga.

## Primera tarea al volver

Implementa Task 11 del plan actualizado. La conversación nueva tiene su historial propio y recibe una orientación pequeña del último intercambio autorizado. Usa el asunto inicial y dónde quedó, con fragmentos del inicio y del cierre cuando ayuden. La orientación conserva su procedencia y ocupa un bloque distinto de los mensajes de la conexión actual. Revalida el estado y las correcciones antes de admitirla.

Al pedir «sigamos con el proyecto XXX», reúne el último punto confirmado de ese proyecto a partir de recuerdos autorizados de varias conversaciones. Conserva la distinción entre decisiones, avances verificados y propuestas pendientes. Usa alias, evidencia temporal y una aclaración breve cuando dos proyectos sean plausibles. El usuario también puede restaurar expresamente una conversación anterior.

Activa la búsqueda por pistas **antes de la primera generación**. La misión del puente de Call of Duty es el escenario de referencia. Task 11 entrega selección asociativa y revalidación. Task 14 conecta el gateway y verifica su primera petición con un proveedor grabador. Task 15 puede adelantar candidatos con fragmentos estables de voz activa y busca al enviar texto. Los candidatos son efímeros y se contrastan con la entrada final, permisos, evidencia y conexión. Task 17 mide selección, fidelidad, latencia y descarte de resultados obsoletos.

## Workflow y límites del relevo

1. Mantén Superpowers y el ledger. Despacha un implementador fresco para cada tarea, verifica RED/GREEN, revisa de forma independiente especificación y calidad y registra los rulings y riesgos residuales. Completa y revisa una tarea antes de empezar la siguiente.
2. Haz las pruebas Swift con un solo trabajo. Reutiliza la caché si existe. Desde el repositorio backend, ejecuta el comando de abajo y añade `--filter` para iteraciones enfocadas. Usa `graphify query` al investigar si existe el grafo, y `graphify update .` después de los cambios de código.
3. Si una aprobación de escritura se queda colgada en un subagente, pide sus cambios exactos con guardas de rama y estado y transpórtalos desde el controlador con la aprobación del sandbox. Verifica el estado de ambos repositorios dentro de cada comando de escritura para evitar sobrescribir trabajo adelantado por otra sesión. Añade al commit solo los archivos propios de la tarea.
4. Preserva los cambios ajenos en los worktrees, las herramientas de Gemini, Safari y `Agent/Gemma`. Usa bases sintéticas. Evita pushes, merges, despliegues y migraciones de HomeLab. Antes de Task 13/14, lee [REVISAR-IMPORTANTE.md](../../../REVISAR-IMPORTANTE.md) para coordinar el puente Calendario ↔ memoria.
5. Al integrar Task 14, conserva una instancia afectiva por el ámbito de sesión autorizado desde antes de capturar turnos, usa observación después del commit y ensambla antes de generar. Reutiliza la ruta de contexto. El bearer actual es de propietario único y la validación de transporte de producción sigue pendiente. Task 15 debe inyectar configuración sintética antes de que `HarnessModel` consulte Keychain.
6. Riesgo residual aprobado para seguimiento. Si se admite y olvida un turno nuevo por completo durante la espera de una observación antigua, la consulta de turnos supervivientes puede dejar elegible la anterior. Si se endurece ese caso, conserva una marca de admisión que no contenga texto ni emoción. La corrección y el olvido de las fuentes de la interpretación sí tienen pruebas.

```sh
swift test --package-path memory-service --jobs 1 --scratch-path /private/tmp/gemma-brain-swift-build
```

Para retomar desde otra sesión, abre el worktree de app indicado arriba y da esta instrucción.

> Lee `docs/superpowers/handoffs/2026-11-07-gemma-brain-task-11.md`, el diseño, el plan y el ledger. Verifica las dos ramas aisladas y continúa desde Task 11 con Superpowers. Conserva la separación entre orientación de arranque, historial actual y recuerdos autorizados. Usa dobles de prueba y jamás cargues Ollama/Gemma local para validar la memoria.
