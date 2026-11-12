# Task 2 - Boveda de secretos: informe

## Implementado
`Gemma/Gemma/Forms/SecretVault.swift`: `SecretoGuardado` y `SecretVault` con la API exacta del brief
(guarda, valor(de:), lista, origen(de:), borra, valoresActuales, static origenPermite).
Almacenamiento: cuenta `secreto.<name>` (JSON value/etiqueta/origen) + cuenta `indice` (JSON de nombres).
Decisiones: nombre validado con `^[a-z0-9_]{1,40}$` (y rechazo explicito de "\n" final); valor vacio se
rechaza; orden secreto->indice y si el indice falla se retira el secreto (sin huerfanos); indice corrupto
= vacio y se recupera al siguiente guarda; entradas corruptas se omiten; NSLock serializa el
leer-modificar-escribir del indice. `origenPermite` normaliza mayusculas, punto final y puerto; host vacio
nunca autoriza; el padre no hereda del hijo.

## Tests (12, todos pasan, 0 fallos)
guarda_y_lee, lista_no_contiene_valores, reemplazo sin duplicar indice, borra, almacen rechaza,
indice-falla-no-deja-huerfano, nombre_invalido, indice_corrupto, entrada_corrupta, origenPermite (4 casos del
brief), origenPermite normalizacion/vacios/padre, valoresActuales_omite_vacios.

## TDD Evidence
RED: `xcodebuild test ... -only-testing:GemmaTests/SecretVaultTests` -> `error: cannot find 'SecretVault' in scope`.
GREEN: mismo comando -> `grep -oE "' (passed|failed|skipped) on '"` = 12 passed, 0 failed.

## Ficheros
- Gemma/Gemma/Forms/SecretVault.swift
- Gemma/GemmaTests/SecretVaultTests.swift

## Autorrevision
- Regex rota: `$` de NSRegularExpression admite "\n" final; se comprueba rango completo. Probado "a\nb".
- Dudas: ninguna bloqueante. `guarda` con valor vacio devuelve false (decision mia, no en el brief).
- Limite conocido: si se sobrescribe un nombre existente y el indice falla, el valor viejo se pierde (el
  indice ya contenia el nombre, asi que en ese caso no se llega a reescribir; el caso solo afecta a nombres nuevos).

## Ronda de arreglo 1/5
### Cambios
1. `origenPermite` valida el juego de caracteres tras normalizar, en AMBOS lados: cada etiqueta debe ser
   `[a-z0-9-]+` y no vacía (punycode `xn--` vale). `evil.com/.google.com`, `#`, `?`, `\`, salto de línea,
   espacio, `@`, etiquetas vacías, unicode y `evil.com:google.com` devuelven false. Solo se quita UN punto final.
2. El índice ilegible ya no es `[]`: `leerIndice()` devuelve `[]` si no existe y `nil` si está ilegible.
   `guarda` se niega (false) y NO escribe ni el secreto; `borra` borra el valor y no toca el índice;
   `lista`/`valoresActuales` devuelven vacío. Comentario falso «se reconstruye» reescrito.
### TDD
RED: 3 tests fallan (`indice_corrupto_sin_secretos...`, `indice_corrupto_con_secretos_ya_guardados_no_se_pisa`,
`origenPermite_rechaza_hosts_con_caracteres_que_no_son_de_host`).
GREEN: `xcodebuild test ... -only-testing:GemmaTests/SecretVaultTests` -> `grep -oE "' (passed|failed|skipped) on '"` = 15 passed, 0 failed.
### Duda
Con índice corrupto, `valoresActuales()` NO puede devolver los secretos existentes (no se pueden enumerar sin
índice); el test comprueba que el índice y los valores no se pisan (`valor(de:)` sigue funcionando) y que al
arreglar el índice vuelven a verse. El redactor sigue ciego mientras el índice esté ilegible; arreglo real
exigiría que el llamador falle cerrado (p. ej. no teclear/guardar) si la bóveda está ilegible.
