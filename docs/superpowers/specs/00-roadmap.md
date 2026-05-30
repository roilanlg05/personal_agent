# Gemma — Roadmap maestro y descomposición de specs

> Documento maestro. Cada **S#** abajo es un sub-proyecto independiente que tendrá su propio ciclo `brainstorming → spec → plan → implementación`. Este archivo NO es un spec; es el mapa que ordena los specs.
>
> **Fuente de verdad de la visión:** `docs/initial_idea.txt`. La sección _Matriz de cobertura_ al final mapea CADA capacidad de ese archivo a un spec, para garantizar que nada se omitió.

---

## 1. Identidad del proyecto

- **Nombre:** Gemma.
- **Forma:** Asistente personal tipo Jarvis, residente en iPhone.
- **Activación:** wake word **"Hey Gemma"** abre modo plática abierta. Se pausa con **"espera"** y se reanuda con **"continúa"**. Se cierra con un despido.
- **Uso:** personal, un solo usuario (el dueño). Sin objetivo de App Store por ahora.

---

## 2. Decisiones bloqueadas

Todas las decisiones de arquitectura fijadas en el brainstorming. Cualquier spec hijo las hereda como restricciones.

| Tema | Decisión | Implicación |
|---|---|---|
| Target hardware | iPhone 16 base ↑ (8GB RAM en toda la línea iPhone 16) | Gemma 4 E4B cuantizado es viable con margen. |
| Modelo base | **Gemma 4 E4B**, multimodal nativo (texto + imagen + audio + video) | Visión e ingest de audio ≤30s corren on-device sin cloud. |
| Candidatos de modelo | a) `litert-community/gemma-4-E4B-it-litert-lm` (oficial, LiteRT-LM); b) `llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic` (GGUF, uncensored); c) `HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive` (GGUF, uncensored) | S1 los compara con bench real en iPhone 16. |
| Runtime | Por decidir en S1: **LiteRT-LM vs llama.cpp**, bench obligatorio | Ambos en mesa; gana el que dé mejor tokens/s · RAM · TTFT · batería · calidad multimodal en iPhone 16. |
| Optimización | **Decoding especulativo** a evaluar en S1 (incluye selección de draft model pequeño) | Puede bajar latencia para que barge-in y frases dinámicas se sientan instantáneas. |
| Cloud | **NINGUNO ahora.** Router híbrido = fase posterior (S15). | Documentos largos (>X tokens) y razonamiento pesado quedan diferidos hasta S15. |
| Idioma | **Bilingüe ES/EN** con code-switching | STT/TTS y prompts bilingües. |
| Ejecución en background / wake-word always-on | iPhone NO jailbroken. Investigar máximo legítimo (S0 spike). | Resultado de S0 condiciona el alcance real de S11 compactación, S14 proactividad, S2 wake word always-on. |
| Memoria (capas L1-L4) | **L1 live + L2 daily on-device.** **L3 episodic + L4 identity + Qdrant + graphify en server casero.** | Memoria caliente embebida; memoria fría/grafo/episodios en server. |
| Server casero | i3 13th gen + 16 GB RAM + 512 GB, Linux/PC | Hosting de Qdrant, graphify, posiblemente VibeVoice y futuras tareas pesadas. |
| Pipeline de voz | Candidato **VibeVoice (streaming)**, probablemente server-side; se detalla en S2 | TTS streaming + STT + VAD + wake word + barge-in. |
| Smart home | **Ambos caminos:** HomeKit/Matter (S16) **y** escaneo/control directo de red (S17) | Dos specs distintos. |
| Ordering / Marketplace | El **marketplace tipo DoorDash es proyecto separado** (S19, solo nodo). El **ordering por voz estilo Alexa** (S18) es punto de decisión cuando lleguemos. | No se desarrolla el marketplace dentro de Gemma. |
| Extensibilidad | "Iremos agregando capacidades" → S4 debe nacer extensible (registro de tools, no hardcode) | CC2 transversal. |

---

## 3. Route map por fases

> Dentro de **Fase 0** el orden interno elegido es **slice vertical:** S1 → S4 → S2 → S3 (con S0 corriendo en paralelo como investigación), y S5 al final de la fase. Esto produce un agente conversacional por voz con 1 tool de prueba antes que la memoria esté completa.

### Fase 0 · Fundación

| Spec | Título | Cubre del archivo | Depende de | Riesgos / decisiones clave |
|---|---|---|---|---|
| **S0** | Spike: ejecución en background iOS | "agente podrá ejecutarse en 2do plano para compactar la memoria" | — | ¿Qué permite iOS sin jailbreak? Audio session, BGTask, VoIP push, location. Pivotal. |
| **S1** | Runtime del modelo on-device | "modelo correrá en el teléfono", "LiteRT-LM", "llama.cpp" | — | Bench LiteRT-LM vs llama.cpp; cuantización; decoding especulativo; selección de draft model. |
| **S1.1** | Cierre de S1: comparación de runtime/modelo + modalidades faltantes | lo de S1 que quedó abierto (ver §3.1) | S1 | Construir llama.cpp + GGUF uncensored para la comparación; mmap vs carga; energía; imagen multimodal funcional. |
| **S4** | Núcleo del agente + tool-calling framework | "langgraph", tool chaining (#6), scratchpad (#20), streaming de actividad (#10), latency tricks (#23), "iremos agregando capacidades" (CC2) | S1 | Function-calling confiable con modelo chico; registro extensible de tools. |
| **S2** | Pipeline de voz | wake word "Hey Gemma", barge-in (#13), VibeVoice streaming | S1 | Hosting VibeVoice (device vs server), latencia bilingüe, motor de wake word. |
| **S3** | Máquina de estados de conversación | "Hey Gemma"/"espera"/"continúa"/dismiss, modo plática abierta, interruption handling (#2) | S2, S4 | Turnos + barge-in en tiempo real; cancelación de tools en vuelo. |
| **S5** | Memoria v1 — **DESCOMPUESTA en S5a/S5b/S5c** (ver §3.2) | RAG personalidad usuario / recuerdos / conversaciones; **L1 live + L2 daily on-device**; **L3/L4 + Qdrant + graphify en server**; retrieval híbrido vector + grafo; smart context injection (#18); contextual auto memory (#1); TTL memory (#4); base de relationship/places graph (#17) | S1, S4, server | Sincronía device↔server; embeddings bilingües; esquema del grafo. |

#### 3.2 · Descomposición de S5 (2026-05-29)

S5 era demasiado grande para un solo spec. Se parte en tres sub-proyectos (cada uno spec → plan → ejecución):

- **S5a — Memoria on-device v1** (spec `2026-05-29-s5a-memoria-ondevice-design.md`, plan `…/plans/2026-05-29-s5a-memoria-ondevice.md`): L1 live + L2 daily + L4 identity, captura híbrida (tool `remember`/`forget` + consolidación post-turno), grafo base personas/lugares/relaciones, recuperación híbrida (vector Apple `NLContextualEmbedding` + grafo + recencia) e inyección de contexto (#18). DB **SQLite (GRDB)+FTS5** con esquema unificado nodo/arista que llega hasta S11 sin migración destructiva. **✅ CÓDIGO COMPLETO (2026-05-30), 30 suites de test verdes en sim; commits `22fdaa4`…`6f7fe09`.** sqlite-vec **diferido** → vectores con BLOB+coseno en Swift (misma interfaz; ver `01-s1-runtime-report.md` §9). **Pendiente: verificación manual en iPhone 16** (recall + persistencia).
- **S5b — Backend de memoria en servidor** (nodo): embeddings premium bilingües, Qdrant, graphify en el PC de casa.
- **S5c — Sync + retrieval híbrido contra servidor** (nodo): protocolo device↔servidor (columnas de sync ya nacen en S5a).

Decisiones diferidas §5: **esquema del grafo (base)** → resuelta en S5a; **embeddings bilingües** y **device↔server** → S5b/S5c.

#### 3.1 · Estado de S1 (2026-05-28)

S1 se ejecutó como una serie de planes (tags `s1-plan1-*` … `s1-plan3c-mtp-report`). La rama **LiteRT-LM** quedó funcional y verificada en iPhone 16 físico; lo que falta para **cerrar S1 se reagrupa en S1.1**.

**Hecho (cerrado):**
- Runtime **LiteRT-LM** real en **GPU/Metal**, texto, on-device (iPhone 16). Requiere entitlement `increased-memory-limit`; KV-cache 4096.
- Capa `ModelRuntime` + harness SwiftUI; infra de modelos (catálogo, descarga, gate de RAM, limpieza `.partial`).
- **Settings UI** (backend, contexto, MTP, sampler, system prompt, max tokens; persistida).
- **Benchmark** sobre la API oficial `benchmark()` + **decisión MTP = OFF** (reporte: `01-s1-runtime-report.md`). El "draft model para decoding especulativo" queda **moot** (MTP off por ahora).

**Pendiente → S1.1:**
1. **Decisión de runtime LiteRT-LM vs llama.cpp** — falta construir llama.cpp y benchear ambos (decisión central de S1, aún abierta).
2. **Variante de modelo oficial vs uncensored GGUF** (candidatos b/c del §2) — no probados (requieren llama.cpp).
3. **mmap vs carga completa** — sub-evaluación no corrida.
4. **Medición energética** (batería/temp + Instruments Energy Log).
5. **Modalidad imagen (multimodal)** — ✅ **HECHO y verificado en iPhone 16 (2026-05-29).** Se re-habilitó `visionBackend` vía cascada condicional GPU→CPU→text-only (`Runtime/MultimodalBackends.swift`, `LiteRTLMRuntime.load`); foto descrita correctamente en device. Audio cableado en la misma cascada, falta verificación con clip real (→ S10). Detalle: `01-s1-runtime-report.md` §7; spec/plan `2026-05-28-s1.1-multimodal*`. Se solapa con **S9**.

> Nota: S2/S4/S5 pueden arrancar con los números de la rama LiteRT-LM ya medidos; S1.1 no bloquea avanzar, pero la **decisión final de runtime/modelo** sí depende de S1.1.

### Fase 1 · Asistente útil del día a día

| Spec | Título | Cubre | Depende de |
|---|---|---|---|
| **S6** | Tools iOS nativas | schedule/Calendar, recordatorios, alarmas, contactos, abrir apps, Maps search + navegación deep-link (Apple **y** Google), weather | S4 |
| **S7** | Búsqueda web | "buscar en internet" | S4 |
| **S8** | Lectura de documentos | docs cortos on-device. **Largos → cloud (diferido a S15)**: "lectura de documentos, no muy largos, de lo contrario remitir a una versión web con más contexto" | S4 (largo: S15) |
| **S9** | Visión de imágenes | "análisis de imágenes, preguntas como '¿qué estoy viendo?' o '¿qué es esto?'" | S1 |
| **S10** | Comprensión de audio ≤30s | audio on-device usando capacidad multimodal nativa de Gemma 4 E4B | S1 |

### Fase 2 · Carácter ("se siente vivo")

| Spec | Título | Cubre | Depende de |
|---|---|---|---|
| **S11** | Memoria v2 (episódica + narrativa) | memoria episódica humana, timelines, daily graph + meta-graph cross-day, episodios (#"Japan Planning"), importance scoring (#22), soft confidence (#12), multi-step memory linking (#15), daily summary (#25), compresión (#9), compactación en background, emotional timelines, hábitos, **continuidad narrativa** | S5, S0 |
| **S12** | Personalidad y voz dinámica | personalidad persistente (#7: humor/estilo/expresiones), dynamic voice style (#24: rápido/relajado/serio/nocturno), emotion tagging (#14: estrés/prisa/cansancio/entusiasmo), frases cortas dinámicas (#3: "voy viendo eso", "un momento") | S2, S4, S5 |
| **S13** | Context awareness + focus mode | sensores #5 (hora, ubicación, batería, calendario, velocidad del carro, audífonos); focus mode #19 (trabajo/manejo/descanso → verbosity/velocidad/tipo de respuesta) | S4 |
| **S14** | Proactividad & ambient | modo proactivo #11 ("tráfico hacia el aeropuerto, sal 15 min antes"; "batería baja + reunión pronto"), ambient memory #8 (música, lugares, apps, hábitos; **con permisos**), background task memory #16 ("recuérdame cuando bajen los vuelos"), alertas iniciadas por el agente sin que el usuario hable ("va a llover") | S0, S11, S13, CC1 |

### Fase 3 · Expansión (cada uno es grande)

| Spec | Título | Cubre | Depende de |
|---|---|---|---|
| **S15** | Router híbrido local/cloud | hybrid brain (#21: conversación/memoria/privacidad local, tareas complejas cloud); selección de proveedor cloud; resumen de docs largos (habilita el camino largo de S8); definición del umbral X de tokens | S4 |
| **S16** | Smart home — HomeKit/Matter | "control de smart home" para dispositivos compatibles con HomeKit/Matter | S4 |
| **S17** | Red / IoT — escaneo y control directo | "acceso a la red de modo que pueda escanear dispositivos en la red, conectarse a ellos, controlarlos" (mDNS/Bonjour, port scan, HTTP/APIs propietarias) | S4 |
| **S18** | Ordering por voz (Alexa-style) | "ordering (uber eats type, lo que se hará es lo que hace alexa, busca en el mapa, ofrece el menú del restaurante y pone una orden)". **Punto de decisión cuando lleguemos.** | S6, S7 |
| **S19** | Marketplace estilo DoorDash/UberEats | "más adelante quiero hacer un marketplace... donde la gente hable con el agente, este le dé sugerencias, y pueda pedir, pagar". **PROYECTO SEPARADO de Gemma — solo nodo en este roadmap.** | Fuera de alcance interno |

### Transversales (no son fases, se diseñan dentro de los specs anteriores)

| ID | Título | Cubre |
|---|---|---|
| **CC1** | Framework de permisos & privacidad | "con permisos" (ambient memory), sensores de context awareness, controles del usuario sobre captura |
| **CC2** | Extensibilidad de tools/plugins | "iremos agregando más capacidades" → S4 nace con registro dinámico de tools |

---

## 4. Gráfico de dependencias (alto nivel)

```
            ┌── S0 (spike background) ───────────────┐
            │                                          ▼
S1 (runtime) ──► S4 (agente+tools) ──► S6/S7/S8/S9/S10  (Fase 1)
   │              ▲   │
   ▼              │   ├──► S2 (voz) ──► S3 (estado conv)
 (CC2 extens.)    │   ├──► S5 (memoria v1) ──► S11 (memoria v2) ──► S14 (proactivo)
                  │   │                          ▲
                  │   ├──► S12 (persona+voz din.) ┘
                  │   └──► S13 (context + focus) ─┘
                  │
                  └──► S15 (router cloud) ──► habilita S8 largo
                  └──► S16 (HomeKit) · S17 (red/IoT) · S18 (ordering)
                                                                  ▲
                                                          S19 (market) ← proyecto separado
```

---

## 5. Decisiones diferidas (cada una se resuelve dentro de su spec)

| Decisión | Spec donde se resuelve |
|---|---|
| LiteRT-LM vs llama.cpp final | **S1.1** (abierta — falta llama.cpp) |
| Variante de modelo final (oficial vs uncensored) | **S1.1** (abierta — falta probar GGUF) |
| Draft model para decoding especulativo | S1 — **resuelta: MTP off** (draft model moot por ahora; ver `01-s1-runtime-report.md`) |
| Mecanismo exacto de background iOS | S0 |
| Motor de wake word ("Hey Gemma") | S2 |
| STT engine bilingüe | S2 |
| TTS: VibeVoice on-device vs server vs alternativa | S2 |
| Modelo de embeddings bilingüe | S5 |
| Esquema del grafo (nodos/aristas/tipos) | S5 (base) y S11 (extensión) |
| Protocolo de sincronía device ↔ server | S5 |
| Proveedor cloud (Gemini/Claude/OpenAI/agnóstico) | S15 |
| Umbral X de tokens para enrutar a cloud | S8 / S15 |
| Política de captura ambient y opt-in | CC1 / S14 |

---

## 6. Matriz de cobertura — verificada contra `docs/initial_idea.txt`

### 6.1 Capacidades de la introducción (párrafo grande)

| Capacidad del archivo | Spec |
|---|---|
| Agente tipo Jarvis en iPhone | (proyecto entero) |
| Manejar schedule | S6 |
| Abrir app | S6 |
| Poner recordatorios | S6 |
| Alarmas | S6 |
| Buscar en internet | S7 |
| Buscar en Google Maps | S6 |
| Abrir el mapa con la dirección (Google **o** Apple Maps) | S6 |
| Info del weather en mi zona | S6 |
| Chat conversacional | S2 + S3 + S4 |
| Ordering tipo Uber Eats (Alexa-style: mapa → menú → orden) | S18 |
| Marketplace futuro tipo Uber Eats/DoorDash (sugerencias, pedir, pagar) | S19 *(proyecto separado, nodo)* |
| Lectura de documentos cortos | S8 |
| Documentos largos → versión web que devuelve resumen (contexto limitado por Gemma) | S8 + S15 *(diferido a fase cloud)* |
| Análisis de imágenes ("¿qué estoy viendo?", "¿qué es esto?") | S9 |
| Memoria — RAG para personalidad del usuario | S5 + S11 + S12 |
| Memoria — recuerdos del agente | S5 + S11 |
| Memoria — recuerdos de conversaciones | S5 + S11 |
| Recordar lugares | S5 + S11 |
| Recordar personas | S5 + S11 |
| Relación entre las personas | S5 (base) + S11 (extensión) |
| Agente me habla sin yo hablarle (ej. va a llover) | S14 |
| Control de smart home | S16 |
| Escanear dispositivos en la red | S17 |
| Conectarse a dispositivos | S17 |
| Controlar dispositivos | S17 |
| "Iremos agregando más capacidades" | CC2 |
| LiteRT-LM / google-ai-edge | S1 |
| llama.cpp | S1 |
| langgraph | S4 |
| graphify | S5 + S11 |
| Vector search (Qdrant) | S5 + S11 |
| Ejecutarse en 2do plano para compactar memoria corto plazo | S0 + S11 |
| Modelo corre en el teléfono | S1 |
| Wake word "Hey Gemma" | S2 |
| "Espera" pausa | S3 |
| Modo plática abierta tras "Hey Gemma" | S3 |
| "Continúa" reanuda | S3 |
| Despido termina | S3 |

### 6.2 Features numeradas 1–25

| # | Feature | Spec |
|---|---|---|
| 1 | Memoria contextual automática (comida favorita, lugares frecuentes, rutina, horario, personas mencionadas) | S5 |
| 2 | Interruption handling ("busca restaurantes ita—" "no, mejor sushi") | S3 |
| 3 | Frases cortas dinámicas ("voy viendo eso", "un momento", "déjame revisar", "ya te digo") | S12 (+ trigger en S4) |
| 4 | Memoria temporal automática TTL 2h (manejando / hambre / aeropuerto) | S5 |
| 5 | Context awareness (hora, ubicación, batería, calendario, velocidad, audífonos) | S13 |
| 6 | Tool chaining ("invita a Juan a cenar mañana" → calendario, hueco, contacto, evento, mensaje) | S4 |
| 7 | Personalidad persistente (humor, estilo, expresiones, forma de hablar) | S12 |
| 8 | Ambient memory (música, lugares visitados, apps usadas, hábitos, **con permisos**) | S14 + CC1 |
| 9 | Compresión inteligente de memoria (resumen "últimos 3 días") | S11 |
| 10 | Streaming de pensamiento visible ("buscando…", "comparando opciones…", "encontré algo") | S4 |
| 11 | Modo proactivo (tráfico al aeropuerto; batería baja + reunión) | S14 |
| 12 | Soft memory confidence (seguro / probable / quizá) | S11 |
| 13 | Voice barge-in | S2 + S3 |
| 14 | Emotion tagging ligero (estrés, prisa, cansancio, entusiasmo) | S12 (+ señal de entrada en S13) |
| 15 | Multi-step memory linking ("quiero ir a Japón" → semanas después "busca vuelos" conecta destino/fechas/presupuesto) | S11 |
| 16 | Background task memory ("recuérdame cuando bajen los vuelos" → "encontré uno más barato") | S14 |
| 17 | Relationship graph (Juan: amigo, trabaja contigo, le gusta sushi) | S5 (base) + S11 (deep) |
| 18 | Smart context injection (solo lo relevante / reciente / semánticamente relacionado) | S5 |
| 19 | Focus mode (trabajo / manejo / descanso → verbosity / velocidad / tipo de respuesta) | S13 |
| 20 | Internal scratchpad (memoria invisible temporal de la tarea actual) | S4 |
| 21 | Hybrid local/cloud brain | S15 |
| 22 | Memory importance scoring (relevancia, repetición, emoción, frecuencia) | S11 |
| 23 | Conversational latency tricks (responde instantáneo aunque siga pensando) | S4 (+ S2) |
| 24 | Dynamic voice style (rápido / relajado / serio / nocturno) | S12 (+ S2) |
| 25 | Daily summary memory (resumen al final del día) | S11 |

### 6.3 Arquitectura de memoria (lines 316–553 del archivo)

| Elemento del archivo | Spec |
|---|---|
| Memoria episódica humana / timelines / experiencias conectadas | S11 |
| Graph por día + Meta-Graph global | S5 (daily) + S11 (meta) |
| Nivel 1 — Daily Graphs | S5 |
| Nivel 2 — Cross-Day Graph (episodios) | S11 |
| Mantener contexto temporal | S11 |
| Comprimir días viejos | S11 |
| Crear "episodios" (ej. "Japan Planning") | S11 |
| Retrieval mejor con episodios relacionados | S11 |
| Reduce contexto brutalmente | S5 + S11 |
| Layer 1 — Live Context (TTL minutos) | S5 |
| Layer 2 — Daily Memory Graph (TTL 24h–7d) | S5 |
| Layer 3 — Episodic Memory (viajes, trabajo, relaciones, proyectos; TTL meses/años) | S11 |
| Layer 4 — Long-term Identity (personalidad, gustos, hábitos, relaciones) | S5 + S11 + S12 |
| Vector Search (similitud semántica) | S5 |
| Graph Traversal (relaciones, causalidad, episodios, timelines) | S5 + S11 |
| Retrieval híbrido (ejemplo "restaurante que mencioné cuando estaba con Juan") | S5 (+ S11 para deep) |
| Emotional timelines | S11 + S13 |
| Hábitos (martes: gimnasio, sushi, llamadas familiares) | S11 + S14 |
| "Construir continuidad narrativa" | S11 |

---

## 7. Estado y próximo paso

- **Estado (2026-05-28):** **S1 ejecutado en su rama LiteRT-LM** (runtime GPU on-device, harness, Settings, benchmark, decisión MTP=off — ver §3.1 y `01-s1-runtime-report.md`). **S1.1 abierta** (llama.cpp + GGUF uncensored para la decisión runtime/modelo, mmap, energía, imagen). **S0 no iniciado** (debía correr en paralelo en Fase 0).
- **Próximo paso (opciones):** (a) **S1.1** para cerrar la decisión runtime/modelo y la imagen multimodal; (b) **S0** spike de background iOS; (c) avanzar a **S4** con la rama LiteRT-LM ya medida (la decisión final de runtime/modelo sigue pendiente en S1.1).
- **Orden de Fase 0 (elegido):** S1 → S4 → S2 → S3, con **S0 en paralelo** como investigación, y **S5 al final** de la fase.
