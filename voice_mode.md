# Arquitectura ideal para Gema (2026)

Lo que te voy a describir NO es un chatbot con voz.
Es una arquitectura pensada específicamente para:

- latencia humana,
- conversación natural,
- atención contextual,
- interrupciones,
- full duplex,
- y uso eficiente de un cerebro gigante (120B).

La idea central es:

```text id="w3g4tb"
el LLM NO controla la conversación en tiempo real
```

El LLM piensa.

Pero otro sistema controla:

- atención,
- timing,
- interrupciones,
- prioridad,
- streaming,
- turn-taking,
- estado conversacional.

Eso es lo que hace que se sienta vivo.

---

# Arquitectura General

```text id="0tw8jl"
                ┌─────────────────────┐
                │     MICROPHONE      │
                └──────────┬──────────┘
                           │
                  Realtime Audio Bus
                           │
 ┌─────────────────────────────────────────────────────┐
 │                                                     │
 ▼                                                     ▼

VAD Engine                                      Speaker Engine
(Silero/WebRTC)                                 (ECAPA/pyannote)

 │                                                     │
 └──────────────┬──────────────────────────────────────┘
                ▼

        Attention Arbitration Layer
      (THE MOST IMPORTANT COMPONENT)

                │
                ▼

      Conversational State Machine
    (dialog/interruptions/context)

                │
                ▼

          Streaming STT Engine
          (faster-whisper)

                │
                ▼

       Intent + Context Layer
      (small local model/rules)

                │
                ▼

          AGI Orchestrator
        (your Cerebras 120B)

                │
                ▼

        Realtime TTS Engine
         (streaming audio)

                │
                ▼

              OUTPUT
```

---

# EL COMPONENTE MÁS IMPORTANTE

# Attention Arbitration Layer

Este es el “sistema nervioso”.

NO usa el LLM gigante.

Usa:

- scores,
- reglas,
- embeddings pequeños,
- señales acústicas,
- estado conversacional.

---

# Su trabajo

Decidir en tiempo real:

```text id="4x0vgn"
¿Gema debe:
- escuchar,
- ignorar,
- esperar,
- responder,
- callarse,
- pausar,
- continuar,
- cancelar TTS,
- retomar contexto?
```

Todo en:

- 5ms
- 10ms
- 20ms

NO 500ms.

---

# Arquitectura Interna REAL

# 1. Audio Layer

## Objetivo:

Nunca perder audio.

---

# Diseño correcto

## Ring Buffer continuo

```text id="z5yw4h"
últimos 30–60 segundos
```

Siempre en RAM.

---

# Chunks

```text id="29fe46"
10ms–30ms chunks
```

No más.

---

# Tecnología

- PortAudio
- sounddevice
- PyAudio
- Rust/C++ backend idealmente

Python solo coordina.

---

# 2. VAD Layer

## Función

Eliminar:

- silencio,
- teclado,
- ruido,
- ventilador,
- TV baja,
- ambiente.

---

# Tiempo esperado

```text id="zv0f08"
< 2ms
```

---

# Recomendación

- Silero VAD

Porque:

- rápido,
- local,
- robusto.

---

# 3. Speaker Recognition Layer

CRÍTICO.

---

# Objetivo

Saber:

- eres tú,
- otra persona,
- TV,
- audio externo.

---

# Tecnología

- ECAPA-TDNN
- pyannote
- resemblyzer

---

# Resultado

```json id="v4i5yw"
{
  "speaker": "roilan",
  "confidence": 0.97
}
```

---

# IMPORTANTÍSIMO:

# Speaker Persistence

NO recalcular identidad cada chunk.

Mantener:

```text id="n1clqq"
active speaker lock
```

por unos segundos.

---

# 4. Attention Arbitration Engine

# (EL CEREBRO REAL)

Este componente decide TODO.

---

# Inputs

## Audio signals

- volumen,
- pausa,
- energía,
- dirección.

---

## Conversational signals

- wake word,
- continuidad,
- embeddings,
- timing.

---

## Contextual signals

- estado actual,
- quién habló antes,
- conversación activa,
- tiempo desde última interacción.

---

# Produce

```json id="g9ifp8"
{
  "attention_score": 0.91,
  "conversation_state": "ACTIVE_DIALOG",
  "assistant_targeted": true,
  "interrupt_detected": false
}
```

---

# Lo MÁS importante:

# probabilidades acumulativas

NO decisiones binarias.

---

# 5. Conversational State Machine

Esto hace que Gema parezca viva.

---

# Estados

```text id="lnp0yx"
IDLE
PASSIVE_LISTENING
ACTIVE_DIALOG
BACKGROUND
WAITING_USER
INTERRUPTED
SPEAKING
THINKING
```

---

# Ejemplo real

## Tú:

> “Hey Gema…”

```text id="t8nyih"
IDLE → ACTIVE_DIALOG
```

---

## Tu esposa habla

```text id="j0g2l7"
ACTIVE_DIALOG → BACKGROUND
```

---

## Tú retomas

```text id="3xkjmq"
BACKGROUND → ACTIVE_DIALOG
```

---

# Esto es MÁS importante que el LLM.

---

# 6. Streaming STT

NO batch.

---

# Necesitas partial transcripts

Ejemplo:

```text id="avnj9s"
"Hey..."
"Hey G..."
"Hey Gema..."
```

---

# Tecnologías

## Mejor local

- faster-whisper
- whisper.cpp

---

# Mejor cloud realtime

- Deepgram
- ElevenLabs realtime
- Groq realtime ASR

---

# CRÍTICO:

# speculative understanding

NO esperes frase completa.

---

# 7. Intent Layer

Modelo pequeño.

NO el 120B.

---

# Objetivo

Decidir:

- comando,
- pregunta,
- small talk,
- interrupción,
- confirmación,
- side conversation.

---

# Modelos ideales

- Qwen2 0.5B
- Gemma small
- Phi-3-mini

cuantizados.

---

# Tiempo objetivo

```text id="9wj24n"
10ms–40ms
```

---

# 8. AGI Orchestrator

Aquí entra tu cerebro gigante vía Cerebras Systems.

Pero IMPORTANTÍSIMO:

```text id="01mz4g"
NO recibe audio crudo.
```

Solo recibe:

- intención limpia,
- contexto relevante,
- memoria activa,
- estado conversacional.

---

# Lo que el orquestador hace

## Manejo de:

- memoria,
- herramientas,
- agenda,
- reasoning,
- RAG,
- personalidad,
- decisiones complejas.

---

# CRÍTICO:

# respuesta streaming

El LLM debe responder token-streaming inmediatamente.

---

# 9. Realtime TTS

ESTO define la percepción humana.

---

# Debe:

- hablar streaming,
- ser interrumpible,
- cortar instantáneamente,
- reaccionar mid-sentence.

---

# TTS ideal

- ElevenLabs realtime
- Cartesia
- Orpheus
- OpenVoice

---

# Arquitectura de interrupciones

# (MUY importante)

Mientras Gema habla:

```text id="zqkhlz"
seguir escuchando SIEMPRE
```

---

# Si detecta:

- tu voz,
- cambio de intención,
- interrupción fuerte,

Entonces:

```text id="xv40z6"
cancel current TTS
```

instantáneamente.

---

# Esto requiere:

# full duplex audio

Como una llamada telefónica.

---

# Latencias reales objetivo

## VAD

```text id="29d0gn"
1–5ms
```

---

## Speaker recognition

```text id="0h0wlh"
5–20ms
```

---

## Arbitration

```text id="d7tv1g"
1–10ms
```

---

## STT partial

```text id="n1j1zv"
50–150ms
```

---

## Intent layer

```text id="jlwmcq"
10–40ms
```

---

## Cerebras response start

```text id="mwpd8u"
100–400ms
```

---

## TTS first audio packet

```text id="db6z8x"
50–120ms
```

---

# Resultado final percibido

Humano siente:

```text id="m87i2r"
respuesta instantánea
```

aunque internamente hubo múltiples capas.

---

# Stack REAL que usaría

## Lenguaje principal

Python.

Porque ya trabajas con:

- FastAPI,
- microservicios,
- realtime,
- IA.

---

# Pero:

# componentes críticos en Rust/C++

## Audio

## buffers

## VAD

## streaming

NO Python puro.

---

# Comunicación interna

NO REST.

---

# Usa:

- ZeroMQ
- NATS
- Redis Streams
- shared memory
- gRPC streaming

---

# Arquitectura física recomendada

## PC principal

Corre:

- arbitration,
- audio,
- TTS,
- STT,
- orchestration.

---

## Cerebras cloud

Solo reasoning grande.

---

# El secreto REAL

La magia NO estará en el modelo de 120B.

Estará en:

```text id="48ljn0"
cómo manejas la atención
```

Porque si Gema:

- sabe cuándo hablar,
- cuándo callarse,
- cuándo esperar,
- cuándo retomar,
- cuándo interrumpirse,

la gente automáticamente asumirá:

> “esto es inteligente”.

Aunque gran parte del sistema sea:

- probabilístico,
- heurístico,
- reactivo,
- y basado en estados.
