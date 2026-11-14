# Relevo de Gemma tras las tareas 16 y 17

## Ramas

Ambos repositorios usan `codex/gemma-brain-20261105`. La app está en `/Users/hashdown/Projects/personal_agent/.worktrees/gemma-brain-20261105` y el backend en el repositorio independiente `gemma-memory` dentro de esa carpeta.

- App desde `a0d82d8` hasta el código verificado en `f1c5a9d`. Incluye el respaldo local de mensajes recientes desde `56b725f` y la integración de memoria nativa de la tarea 15. La tarea 17 volvió a verificar esa app, que sigue pendiente de distribución.
- Backend desde `ea42d5f` hasta `53dc713`. `a125778` corresponde a la tarea 16 y `29f746c` corrige duplicados. `53dc713` contiene la evaluación de la tarea 17.

## HomeLab

Se migró la base activa de v10 a `v24-embedding-index` y se activó el índice BAAI/bge-m3 de 1024 dimensiones, revisión de modelo `5617a9f61b028005a4858fdac845db406aefb181`. Un despliegue con los vectores heredados puede usar búsqueda textual mientras prepara y activa su índice.

El usuario autorizó borrar la memoria activa, incluidos eventos y tareas. El borrado autenticado devolvió un recibo confirmado. Tras el reinicio se verificaron cero conversaciones guardadas, afirmaciones, evidencias, eventos y tareas. Los hubs estructurales se recrean al iniciar y las conexiones configuradas siguen presentes. Se dejaron fuera del borrado las copias SQLite anteriores, los datos locales de dispositivos y las cuentas externas. No se creó una copia nueva.

El proyecto Compose original usa un override enlazado al release aislado en `/home/hashdown/.gemma-memory-a125778.RO3Jty`. Las imágenes fijadas son `gemma-memory-memory:a125778-dedup` y `gemma-memory-embedder:a125778`. El servicio de memoria, voz y el embedder pasaron sus comprobaciones de salud. El arreglo impide convertir preparativos inferidos en tareas activas y reutiliza eventos por título normalizado e inicio, preservando los datos explícitos o vinculados a Apple. Se verificó con pruebas de regresión. Todavía falta comprobar ciclos reales de reflexión y sueño con datos nuevos. La migración ya se ejecutó y su borrado no debe repetirse al retomar.

## Evaluación de la tarea 17

Pasaron 640 pruebas de backend, incluidas 17 del contrato compartido, y 200 pruebas sintéticas de macOS. Terminó la compilación genérica de iOS sin firma. Se excluyeron las suites con efectos reales de AtoZ, Keychain, proveedor y servicios instalados. La revisión independiente del evaluador detectó referencias retiradas fuera del texto e identificadores desconocidos descartados por el adaptador. La suite final incluye regresiones para ambos casos.

El corpus versionado tiene 200 casos, 140 de ajuste y 60 reservados por plantilla. El runner ejecutó 150 historias por rutas HTTP en proceso sobre SQLite aislado, reabrió sus bases y verificó 25 retiradas de fuentes, con cero exposiciones en contexto, FTS, híbrido y vectorial. Entregó cinco citas exactas asistidas, todas del conjunto reservado. Las otras 195 afirmaciones quedaron sin cobertura semántica y hubo cero casos ausentes. La cobertura de afirmaciones y su exactitud global fueron 2,5 %. FTS encontró 103 de 165 referencias esperadas. Contexto, híbrido y vectorial encontraron 165 de 165, con 10 referencias adicionales en cada ruta. Los casos tenían como máximo dos mensajes históricos y usaron vectores sintéticos.

Los cinco escenarios adicionales pasaron 33 comprobaciones. Cubren proyectos entre conexiones, contexto disponible en la primera petición, dictado y revocación, distinción entre gustos y preferencias, compactación y retirada de fuentes tras restaurar filas antiguas, validez de procedimientos y envío de la política de criterio propio. La prueba de restauración conserva el registro de borrado. La restauración física completa, el ranking con embeddings reales, la ejecución externa y las respuestas naturales y con criterio del proveedor siguen pendientes de validación.

El [procedimiento reproducible](../../../gemma-memory/memory-service/BrainEvaluation.md) describe las métricas. El informe JSON de esta ejecución quedó en `/private/tmp/gemma-task17-evaluation.json`. Los logs quedaron en `/private/tmp/gemma-task17-backend-final.log`, `/private/tmp/gemma-task17-macos-final.log` y `/private/tmp/gemma-task17-ios-final.log`.

## Siguiente verificación

Integrar la rama de memoria de la app con la rama de herramientas en coordinación con Gemini. Con la app resultante instalada y el endpoint y token configurados, verificar continuidad entre conexiones, respaldo local ante fallo remoto, nombres con evidencia, correcciones, borrado desde otro dispositivo y deduplicación tras reflexión y sueño. Verificar por separado la calidad conversacional y el recuerdo semántico con el proveedor real. El usuario prohibió ejecutar el modelo local que agotó la memoria de la Mac. Para pruebas reales autorizadas, usar Claude Code en la nube y avisar antes si serán largas.
