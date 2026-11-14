# Safari A to Z sync

La extensión 1.3 sigue `amazon_scheduler.py`: lee primero las cookies de la página de A to Z, visita el origen de la API en una pestaña temporal y recoge sus cookies. Las combina por nombre en ese orden: la segunda fuente reemplaza los nombres repetidos, igual que el diccionario de Python. La pestaña temporal se cierra después. No necesita visitar la pantalla de turnos. Los permisos de Safari deben permitir tanto `atoz.amazon.work` como `atoz-apps.amazon.work` en el perfil donde se inicia sesión.

El employee ID es el configurado en Python (`EMPLOYEE_ID`), no se deduce de `sub`. El token debe tener al menos 60 segundos de vigencia. El cliente conserva `User-Agent: Agent/Gemma`.

Antes de guardar, envía `verify: true` al servicio de conexiones. El servidor ejecuta una consulta de lectura con la cabecera exportada, sin cookies compartidas ni redirecciones. Solo una respuesta GraphQL válida y sin errores produce `verified: true`. Una lista vacía es válida. Los errores no reemplazan las credenciales guardadas. El endpoint sin `verify` conserva compatibilidad con otros clientes y no garantiza validación.

Para investigar capturas incompletas, `amazon-atoz-diagnostics` recibe únicamente nombres, dominios, rutas, expiraciones y estructura del token. No recibe valores de cookies, valores de claims ni cabeceras de autenticación de Amazon.

## Actualización

1. Recompilar y reiniciar `gemma-memory/memory-service` en la máquina que sirve el puerto 8081. Si se usa Docker Compose: `docker compose up -d --build memory` desde `gemma-memory`.
2. Compilar e instalar el scheme `GemmaSafari` desde `GemmaSafariExtension/GemmaSafari/GemmaSafari.xcodeproj` en el iPhone o simulador.
3. Activar la extensión en Safari y permitir los sitios de A to Z. Iniciar sesión en `https://atoz.amazon.work/`.
4. Abrir el popup y pulsar «Sincronizar con Gemma». Solo «Verificada con Amazon» confirma que las cookies funcionan fuera del navegador. «Volver a Gemma» es una acción manual.

El servidor y el bearer de la extensión siguen siendo los configurados en `background.js`; deben coincidir con el servicio. No pegues cookies ni tokens en logs o incidencias. Un servidor antiguo mostrará un error de actualización y no producirá un falso éxito.

## Pruebas

`node --test GemmaSafariExtension/tests/cookies.test.cjs`

Desde `gemma-memory/memory-service`: `swift test --filter 'AtoZSessionVerifierTests|ConnectionServicesEndpointsTests'`.

La aceptación real requiere login en Safari y conectividad con el servidor y Amazon. Las pruebas automáticas usan cookies sintéticas y no contactan Amazon.
