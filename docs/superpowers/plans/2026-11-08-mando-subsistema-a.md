# El mando compartido, subsistema A — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el servicio del navegador del i3 sepa quién conduce —el agente o el
humano—, lo imponga en vez de confiarlo a nadie, y deje al humano tomar el mando
y devolverlo.

**Architecture:** Un módulo nuevo y **puro** (`browser/mando.py`) con la máquina de
estados y la detección del muro, al lado de `browser/stream.py`, que ya es puro
por el mismo motivo: sin red, sin ficheros, sin reloj y sin registrar nunca el
cuerpo de un mensaje. El relé (`browser/relay.py`, 809 líneas) solo lo consulta y
obedece; `browser/app.py` expone los endpoints. Ninguna decisión de estado vive en
un cliente.

**Tech Stack:** Python 3 + FastAPI + websockets, en el contenedor
`gemma-browser-browser-1` del i3. Pruebas con `pytest` sobre `browser/`.

**Spec:** `docs/superpowers/specs/2026-11-08-mando-compartido-del-navegador-design.md`
(en el repositorio hermano `personal_agent`; este plan vive en `gemma-memory`).

## Global Constraints

- **El relé reenvía al demonio una LISTA DE PERMITIDOS de mensajes del visor:**
  solo `input_mouse`, `input_keyboard` e `input_touch`. **`config` no se reenvía
  jamás** — medido: `{"type":"config","maxFps":0}` a mitad de conexión levanta el
  tope de fotogramas y rompe el `pacing=ack`.
- **Tomar y devolver el mando viajan por el SOCKET del visor, no por HTTP**
  (`mando_tomar` y `mando_devolver`, que el relé ATIENDE y no reenvía al demonio).
  Razón: el portador **es un socket**. `Mando.toma(visor, …)` necesita saber quién
  lo tiene para poder darle los fotogramas solo a él y para devolver el mando
  cuando se desconecte, y una petición HTTP no trae ningún socket consigo. Por
  HTTP quedan solo las dos cosas que no necesitan identidad: **leer** el estado
  (`GET /v1/browser/mando`) y la **señal del agente** (`POST
  /v1/browser/mando/pedir`).
- **La entrada del visor no se registra, no se narra con su contenido y no entra en
  el contexto del modelo.** Un `input_keyboard` se narra como «el usuario está
  escribiendo», nunca con la tecla. Mismo patrón que `stream.py` con los `params`.
- **Mientras conduce el humano: los fotogramas van solo al portador**, y el agente
  no puede mirar la página (ni `snapshot`, ni `get`, ni `read`), **ni en el
  instante siguiente a devolver el mando**.
- **Ningún secreto por `argv`**, y la lista de permitidos de subcomandos de
  `browser/cli.py` **no se abre**: el scroll remoto se hace con
  `input_mouse`/`mouseWheel`, no con el subcomando `scroll`.
- **`mando.py` es puro:** sin red, sin ficheros, sin reloj propio (el tiempo entra
  como parámetro), y **nunca** reproduce el cuerpo de un mensaje en una excepción o
  un valor de retorno.
- Los tres puertos del i3 no se pisan: memoria 8081, voz 8082, navegador 8083.
- **No se toca el i3 ni docker desde una tarea.** Las mediciones y el despliegue
  los hace el controlador.
- Añadir siempre rutas concretas al índice, **nunca `git add -A`**.

## El arnés de pruebas que ya existe

Las tareas 4 a 7 **no escriben dobles nuevos**. `browser/test_app.py` ya tiene el
arnés y hay que usarlo tal cual:

| pieza | qué es |
|---|---|
| `VisorFalso(auto_ack=True, lento=0.0, se_va_tras_frames=None)` | visor de prueba; `.enviados`, `.frames`, `.tipos`, `.desconectar()`, `.inyectar_acuse(seq)` |
| `_demonio_falso(guion, acuses, lecturas, cierra=False)` | servidor del stream del demonio |
| `_cablear(guion, visores, hasta, acuses=…, tras=…)` | levanta demonio + relé + visores `[(visor, max_fps)]`, espera `hasta`, corre `tras`, desmonta |
| `_paso(texto, espera_acuse=False)`, `_frame(seq)` | guion del demonio |
| `_esperar(predicado, timeout)` | espera activa |

**Dos cosas importantes del arnés:**

1. **`acuses` recoge TODO lo que el relé le manda al demonio**, no solo los acuses
   (`async for crudo in ws: acuses.append(...)`). Por eso la entrada reenviada se
   comprueba ahí, filtrando por `type`. **No se renombra `acuses`** — lo usan unas
   veinte pruebas; las tareas nuevas filtran en local.
2. **`_cablear` no expone el `Relay`**, y las tareas 4-7 lo necesitan (el mando vive
   en él). La Tarea 4 cambia `tras` para que reciba el relé: `await tras(rele)`, y
   actualiza los **tres** `tras=` que ya existen (líneas 976, 1047 y 1230) a
   `async def comprobar(rele)`. Es un cambio de tres sitios, no una migración.

## Review Focus

1. **Dos visores piden el mando en el mismo instante.** Uno lo obtiene y el otro
   recibe una negativa con motivo; nunca los dos. Tarea 3.
2. **El portador se desconecta sin devolver el mando.** El mando no puede quedarse
   trabado para siempre: al irse el socket del portador, vuelve al agente. Tarea 4.
3. **Una página de muro que navega a sí misma.** No devuelve el mando: es el «error
   de que el captcha no se resolvió» del usuario. Tarea 3.
4. **Un cliente sin cabecera `Origin`.** La app de Swift no manda `Origin`;
   rechazarla rompería el teléfono. Ausente se acepta, presente se comprueba.
   Tarea 6.
5. **Una inundación de eventos de entrada del portador.** El demonio tiene un solo
   socket: una avalancha hambrea los acuses y congela el panel de todos. Tarea 6.

---

### Task 1: `url` y el título dejan de morir en el relé

**Files:**
- Modify: `browser/stream.py`
- Test: `browser/test_stream.py`

**Interfaces:**
- Produces: `decode(text) -> dict` gana dos `kind` nuevos: `"url"` (rellena la clave
  `url`, que **ya existe** en `_empty` — no se añade otra) y `"tabs"` (rellena una
  clave `title` nueva en `_empty`).
- Produces: `wire_messages(decoded)` gana las dos ramas, y **publica el host, no la
  URL**.

El mensaje `url` del demonio es la señal de «cambió la página» que devuelve el
mando, y **hoy `decode` lo clasifica como `other` y se pierde**. El `tabs` trae el
título de la pestaña activa, que es lo que permite detectar los muros de
Cloudflare **sin leer la página**.

⚠️ **La URL completa no cruza el cable, y esto no se cambia.** Es una decisión ya
tomada y ya probada en este módulo: `test_navigate_manda_narracion_y_host_pero_no_la_url_completa`
afirma que de `https://www.amazon.es/dp/B0?ref=secreto` sale el host
`www.amazon.es` y que `secreto` no aparece en el cable, porque una query string
lleva secretos. La URL entera vive **solo dentro del relé**, para que el mando
compare «¿es la misma página?»; al visor va un mensaje `host`, igual que ya hace
`navigate`.

- [ ] **Step 1: Escribir las pruebas que fallan**

En `browser/test_stream.py`:

```python
def test_el_mensaje_url_sobrevive_al_decode():
    d = stream.decode(json.dumps({"type": "url", "url": "https://www.amazon.es/"}))
    assert d["kind"] == "url"
    assert d["url"] == "https://www.amazon.es/"

def test_el_titulo_de_la_pestana_activa_sobrevive_al_decode():
    d = stream.decode(json.dumps({"type": "tabs", "tabs": [
        {"active": False, "title": "otra"}, {"active": True, "title": "Just a moment..."}]}))
    assert d["kind"] == "tabs"
    assert d["title"] == "Just a moment..."

def test_un_url_sin_esquema_http_se_descarta():
    # Misma regla que ya aplica _decode al host: `javascript:` y `file:` no pasan.
    for u in ("javascript:alert(1)", "file:///etc/passwd", "", 42):
        d = stream.decode(json.dumps({"type": "url", "url": u}))
        assert d["url"] is None

def test_un_tabs_sin_pestana_activa_no_inventa_titulo():
    d = stream.decode(json.dumps({"type": "tabs", "tabs": [{"active": False, "title": "x"}]}))
    assert d["title"] is None

def test_el_titulo_se_recorta():
    largo = "x" * 500
    d = stream.decode(json.dumps({"type": "tabs", "tabs": [{"active": True, "title": largo}]}))
    assert len(d["title"]) <= stream.MAX_TITLE

def test_el_url_del_demonio_publica_el_host_y_NUNCA_la_url_completa():
    # Mismo candado que ya protege a `navigate`: una query string lleva secretos.
    d = stream.decode(json.dumps({"type": "url", "url": "https://www.amazon.es/dp/B0?ref=secreto"}))
    msgs = stream.wire_messages(d)
    cable = json.dumps(msgs)
    assert [m["type"] for m in msgs] == ["host"]
    assert msgs[0]["host"] == "www.amazon.es"
    assert "secreto" not in cable and "/dp/B0" not in cable

def test_un_tabs_no_publica_nada_al_cable():
    # El titulo es para clasificar el muro, no para pintarlo en el panel.
    d = stream.decode(json.dumps({"type": "tabs", "tabs": [{"active": True, "title": "Just a moment..."}]}))
    assert stream.wire_messages(d) == []
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_stream.py -v`
Expected: FAIL — hoy los dos `kind` salen `other` y las claves no existen.

- [ ] **Step 3: Añadir los dos `kind` a `stream.py`**

`_empty` gana **solo** la clave `title` (en `None`); `url` ya está ahí y se
reutiliza. `decode` gana las dos ramas y `wire_messages` también: la de `url`
devuelve `[{"type": "host", "host": host_of(url)}]` cuando hay host y `[]` cuando
no; la de `tabs` devuelve `[]`. El saneado de la URL es `host_of`, que es el
criterio que el módulo ya tiene (solo `http` y `https`), así que no se escribe uno
nuevo. `MAX_TITLE = 200`, constante nueva al lado de `_MAX_HOST`, con un
comentario que diga por qué existe el tope (un título es un título, no un
contenido).

**No tocar `_decode_command`:** su `url` cruda se queda como está. Las dos ramas
nuevas son aditivas.

- [ ] **Step 4: Correr y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS, y las 143 que ya había siguen verdes.

- [ ] **Step 5: Commit**

```bash
git add browser/stream.py browser/test_stream.py
git commit -m "feat(mando): el mensaje url y el titulo de la pestana dejan de morir en el decode"
```

---

### Task 2: La detección del muro, pura

**Files:**
- Create: `browser/mando.py`
- Test: `browser/test_mando.py`

**Interfaces:**
- Produces: `clasifica_muro(titulo: str | None, cuerpo: str | None) -> str | None`
  — devuelve el nombre del muro (`"cloudflare"`, `"cloudflare_duro"`,
  `"datadome"`, `"estrangulamiento_amazon"`) o `None`. `cuerpo` es opcional **a
  propósito**: con solo el título se detectan los dos de Cloudflare, que es lo que
  permite clasificar sin leer la página.
- Produces: `MUROS_POR_TITULO` y `MUROS_POR_CUERPO`, los dos `tuple` de pares
  (firma, nombre), públicos para que una prueba los recorra.

Las firmas están medidas el 2026-11-08 contra el i3 y son estas, literales:

| firma | dónde | muro |
|---|---|---|
| `Just a moment...` | título | `cloudflare` |
| `Attention Required!` (prefijo) | título | `cloudflare_duro` |
| `var dd={` con `cid` y `hsh` | cuerpo | `datadome` |
| `Lo sentimos.` como título **y** cuerpo de menos de 500 caracteres | título + cuerpo | `estrangulamiento_amazon` |

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
def test_cloudflare_se_detecta_por_el_titulo_sin_leer_la_pagina():
    assert mando.clasifica_muro("Just a moment...", None) == "cloudflare"
    assert mando.clasifica_muro("Attention Required! | Cloudflare", None) == "cloudflare_duro"

def test_datadome_necesita_el_cuerpo():
    cuerpo = "var dd={'rt':'c','cid':'AHrlqAA','hsh':'C254CBC8'}"
    assert mando.clasifica_muro("autozone.com", None) is None
    assert mando.clasifica_muro("autozone.com", cuerpo) == "datadome"

def test_el_estrangulamiento_de_amazon_pide_titulo_y_cuerpo_corto():
    assert mando.clasifica_muro("Lo sentimos.", "x" * 357) == "estrangulamiento_amazon"
    # Un articulo de Wikipedia que se llamara igual no es un muro.
    assert mando.clasifica_muro("Lo sentimos.", "x" * 20000) is None

def test_una_pagina_normal_no_es_un_muro():
    assert mando.clasifica_muro("Amazon.es : raquetas ping pong", "x" * 18720) is None
    assert mando.clasifica_muro(None, None) is None

def test_ninguna_firma_reproduce_el_cuerpo_que_la_activo():
    # El nombre del muro viaja al chat del usuario: no puede arrastrar la pagina.
    for _, nombre in mando.MUROS_POR_TITULO + mando.MUROS_POR_CUERPO:
        assert nombre.replace("_", "").isalnum()
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_mando.py -v`
Expected: FAIL — el módulo no existe.

- [ ] **Step 3: Crear `browser/mando.py` con la clasificación**

Cabecera del módulo en el estilo de `stream.py`: qué hace, que es puro, y **que
las firmas están medidas y de dónde** (la tabla de arriba, con fecha). El cuerpo
solo se mira si llega; el título basta para Cloudflare.

- [ ] **Step 4: Correr y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/test_mando.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add browser/mando.py browser/test_mando.py
git commit -m "feat(mando): clasificar un muro antibot, por titulo cuando se puede"
```

---

### Task 3: La máquina de estados

**Files:**
- Modify: `browser/mando.py`
- Test: `browser/test_mando.py`

**Interfaces:**
- Produces: `class Mando` con:
  - `__init__(self, *, plazo_humano: float = 600.0)`
  - `quien_conduce -> str` — `"agente"` o `"humano"`
  - `portador -> object | None` — el visor que tiene el mando, o `None`
  - `pide_el_agente(self, muro: str | None, ahora: float) -> bool` — el agente
    solicita el paso de mando; `False` si ya conduce el humano
  - `toma(self, visor, ahora: float) -> bool` — un visor lo toma; `False` si ya lo
    tiene otro
  - `devuelve(self, visor, ahora: float) -> bool` — el portador lo devuelve
  - `se_fue(self, visor, ahora: float) -> bool` — el socket del portador murió
  - `al_navegar(self, url: str | None, muro: str | None, ahora: float) -> bool` —
    llegó un `url` nuevo; devuelve `True` si el mando volvió al agente
  - `vencio(self, ahora: float) -> bool` — el plazo del humano se agotó
  - `mensaje_de_estado(self) -> dict` — lo que se publica a los visores
- Produces: `MANDO_AGENTE = "agente"`, `MANDO_HUMANO = "humano"`, `MAX_URL = 2048`.

⚠️ **La URL que el `Mando` retiene es lo más peligroso de esta tarea.** La
revisión de la Tarea 1 lo midió: la URL que sobrevive al `decode` conserva la
**query string** y el **`userinfo`** (`https://usuario:clave@host/…`), y el
`Mando` la **retiene** para la salvaguarda de «la misma página no cuenta». Por eso:

1. `al_navegar` **recorta a `MAX_URL = 2048`** antes de guardarla. El módulo acota
   todo lo demás que entra por el cable (`_MAX_HOST = 255`, `MAX_TITLE = 200`) y
   un campo sin tope rompe ese patrón; y aquí no es de paso, es retenido.
2. **`mensaje_de_estado()` no contiene la URL, ni un trozo, ni el host.** Lo que
   se publica es quién conduce. Quien quiera saber dónde está, ya recibe el
   mensaje `host` por su cuenta.
3. **Ninguna excepción ni ningún valor de retorno la reproduce**, igual que en
   `stream.py`.

**El tiempo entra como parámetro** (`ahora`), nunca se lee del reloj: así el módulo
sigue siendo puro y el plazo se prueba sin esperar diez minutos.

Reglas del regreso, que son las tres salvaguardas del spec:
1. Vuelve al agente cuando llega un `url` **cuyo muro clasificado es `None`**.
2. Una URL igual a la que ya había **no** cuenta (la página de muro que navega a
   sí misma).
3. Un `url` nuevo que sigue siendo muro **no** cuenta.

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
def test_empieza_conduciendo_el_agente():
    assert mando.Mando().quien_conduce == mando.MANDO_AGENTE

def test_un_visor_toma_el_mando_y_lo_devuelve():
    m, v = mando.Mando(), object()
    assert m.toma(v, 0.0) is True
    assert m.quien_conduce == mando.MANDO_HUMANO and m.portador is v
    assert m.devuelve(v, 1.0) is True
    assert m.quien_conduce == mando.MANDO_AGENTE and m.portador is None

# Review Focus 1
def test_dos_visores_a_la_vez_solo_uno_conduce():
    m, a, b = mando.Mando(), object(), object()
    assert m.toma(a, 0.0) is True
    assert m.toma(b, 0.0) is False
    assert m.portador is a
    assert m.devuelve(b, 1.0) is False   # el que no lo tiene no lo devuelve

# Review Focus 2
def test_si_el_portador_se_desconecta_el_mando_vuelve_al_agente():
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    assert m.se_fue(v, 1.0) is True
    assert m.quien_conduce == mando.MANDO_AGENTE

def test_que_se_vaya_otro_visor_no_mueve_el_mando():
    m, a, b = mando.Mando(), object(), object()
    m.toma(a, 0.0)
    assert m.se_fue(b, 1.0) is False
    assert m.portador is a

def test_el_mando_vuelve_cuando_la_pagina_deja_de_ser_un_muro():
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    assert m.al_navegar("https://www.amazon.es/s?k=raquetas", None, 5.0) is True
    assert m.quien_conduce == mando.MANDO_AGENTE

# Review Focus 3
def test_un_muro_que_navega_a_si_mismo_no_devuelve_el_mando():
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    assert m.al_navegar("https://pccomponentes.com/x", "cloudflare", 1.0) is False
    assert m.al_navegar("https://pccomponentes.com/x", None, 2.0) is False  # misma URL
    assert m.quien_conduce == mando.MANDO_HUMANO

def test_navegar_a_otro_muro_tampoco_devuelve_el_mando():
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    assert m.al_navegar("https://otro.example/x", "datadome", 1.0) is False

def test_el_plazo_del_humano_vence_y_el_mando_vuelve():
    m, v = mando.Mando(plazo_humano=600.0), object()
    m.toma(v, 0.0)
    assert m.vencio(599.0) is False
    assert m.vencio(601.0) is True
    assert m.quien_conduce == mando.MANDO_AGENTE

def test_el_agente_no_puede_pedir_el_mando_si_ya_conduce_el_humano():
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    assert m.pide_el_agente("cloudflare", 1.0) is False

def test_el_mensaje_de_estado_dice_quien_conduce_y_nada_del_visor():
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    msg = m.mensaje_de_estado()
    assert msg["type"] == "mando" and msg["quien"] == mando.MANDO_HUMANO
    assert repr(v) not in json.dumps(msg)   # el portador no se identifica al cable

def test_el_mensaje_de_estado_NO_lleva_la_url_ni_un_trozo():
    # La URL retenida conserva query y userinfo (medido en la revisión de la
    # Tarea 1). El estado va al cable y a tres clientes: no puede arrastrarla.
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    m.al_navegar("https://pepe:clave123@secreto.example/x?token=abc", "cloudflare", 1.0)
    cable = json.dumps(m.mensaje_de_estado())
    for trozo in ("clave123", "token=abc", "secreto.example", "pepe"):
        assert trozo not in cable, trozo

def test_una_url_larguisima_se_recorta_antes_de_guardarse():
    m, v = mando.Mando(), object()
    m.toma(v, 0.0)
    larga = "https://x.example/" + "a" * 10_000
    m.al_navegar(larga, "cloudflare", 1.0)
    # Observable sin exponer un atributo privado: la misma URL recortada sigue
    # contando como «la misma página», así que no devuelve el mando.
    assert m.al_navegar(larga, None, 2.0) is False
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_mando.py -v`
Expected: FAIL — `Mando` no existe.

- [ ] **Step 3: Implementar `Mando` en `browser/mando.py`**

El estado es el portador: si hay portador conduce el humano, si no conduce el
agente. `al_navegar` guarda la última URL vista para la salvaguarda 2. Comentar
**por qué el tiempo entra como parámetro** y **por qué el mensaje de estado no
identifica al visor** (va al cable y a tres clientes; quién conduce es un hecho,
qué dispositivo es no le importa a nadie más).

- [ ] **Step 4: Correr y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add browser/mando.py browser/test_mando.py
git commit -m "feat(mando): la maquina de estados de quien conduce el navegador"
```

---

### Task 4: El relé obedece al mando y filtra lo que el visor manda

**Files:**
- Modify: `browser/relay.py`
- Test: `browser/test_app.py`

**Interfaces:**
- Consumes: `mando.Mando`, `mando.clasifica_muro`, y los `kind` `url`/`tabs` de la
  Tarea 1.
- Produces: `Relay.mando` (el `Mando` de esa sesión), `Relay.toma_el_mando(viewer)`,
  `Relay.devuelve_el_mando(viewer)`, y el reenvío de entrada al demonio.
- **El reloj lo pone el relé, no el mando:** los métodos del `Relay` NO llevan
  `ahora`; el relé lee `time.monotonic()` y se lo pasa a `Mando`. Así `mando.py`
  sigue siendo puro y el relé sigue siendo el único sitio con reloj.

Hoy el bucle del visor (`relay.py`, en `add_viewer`) solo entiende `ack` y la
cabecera del módulo dice «no hay control remoto». Esto lo cambia, **con lista de
permitidos**.

- [ ] **Step 1: Escribir las pruebas que fallan**

Primero, dos cambios de arnés en `browser/test_app.py`:
`VisorFalso.inyectar_entrada(crudo: str)` (igual que `inyectar_acuse`, pero con el
texto entero), y `_cablear` llamando `await tras(rele)` con sus tres llamantes
actualizados.

Las pruebas, con `_env = lambda a: [m for m in a if m.get("type") != "ack"]` como
filtro local:

```python
def test_el_rele_reenvia_la_entrada_del_portador():
    visor, acuses = VisorFalso(), []
    raton = {"type": "input_mouse", "x": 10, "y": 20, "eventType": "mousePressed"}
    async def comprobar(rele):
        rele.toma_el_mando(visor)
        visor.inyectar_entrada(json.dumps(raton))
        assert await _esperar(lambda: _env(acuses))
    asyncio.run(_cablear([_paso(_frame(1))], [(visor, 0)],
                         lambda: len(visor.frames) >= 1, acuses=acuses, tras=comprobar))
    assert _env(acuses) == [raton]

def test_el_rele_ignora_la_entrada_de_quien_no_tiene_el_mando():
    # Dos visores, el mando en el primero: lo que manda el segundo no llega.
    # assert _env(acuses) == []

def test_el_rele_ignora_la_entrada_mientras_conduce_el_agente():
    # Nadie tomó el mando: assert _env(acuses) == []

def test_el_rele_NUNCA_reenvia_config():
    # El portador manda {"type":"config","maxFps":0}: assert _env(acuses) == []
    # Candado del agujero de caudal ilimitado que la rama anterior cerró.

def test_el_ack_sigue_funcionando_con_el_mando_tomado():
    # El guion pide acuse y sigue fluyendo con el mando en el visor.

def test_un_mensaje_desconocido_del_visor_se_descarta_y_no_aparece_en_ningun_sitio():
    # {"type":"vete_a_saber","secreto":"abc"}: assert _env(acuses) == []
    # y "abc" no aparece en json.dumps(acuses).

def test_el_url_del_demonio_llega_al_mando_entero_y_al_visor_solo_el_host():
    # Guion con {"type":"url","url":"https://www.amazon.es/dp/B0?ref=secreto"}:
    # al visor le llega {"type":"host","host":"www.amazon.es"}, y
    # "secreto" not in json.dumps(visor.enviados). El mando lo recibe entero,
    # observable por el efecto: con el mando tomado y sin muro, vuelve al agente.

def test_al_irse_el_portador_el_mando_vuelve_al_agente():   # Review Focus 2
    # visor.desconectar() -> _esperar(lambda: rele.mando.quien_conduce == "agente")

def test_el_visor_toma_y_devuelve_el_mando_por_su_propio_socket():
    # inyectar_entrada({"type":"mando_tomar"}) -> quien_conduce == "humano"
    # inyectar_entrada({"type":"mando_devolver"}) -> quien_conduce == "agente"

def test_los_mensajes_del_mando_NO_se_reenvian_al_demonio():
    # Son del protocolo del panel, no del navegador: assert _env(acuses) == []
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py -v -k "mando or entrada or config"`
Expected: FAIL.

- [ ] **Step 3: Implementar el filtro y el cableado en `relay.py`**

Una función **pura** `mensaje_del_visor(text) -> tuple[str, dict] | None` que
clasifique en `("ack", …)`, `("input", …)`, `("mando_tomar", {})`,
`("mando_devolver", {})` o `None`, al lado de `_ack_from` y con el mismo criterio:
**no reproduce nunca el contenido** en un error. El bucle de `add_viewer` la usa.

Las cuatro clases se tratan distinto: `ack` como hoy; `input` **se reenvía** al
demonio y solo si el visor es `self.mando.portador`; `mando_tomar` y
`mando_devolver` **los atiende el relé y NO se reenvían nunca** (son del protocolo
del panel, no del navegador). Actualizar la cabecera del módulo: la frase «no hay
control remoto» deja de ser verdad y tiene que decir qué la sustituye.

- [ ] **Step 4: Correr y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add browser/relay.py browser/test_app.py
git commit -m "feat(mando): el rele reenvia la entrada del portador, y solo la entrada"
```

---

### Task 5: Mientras conduce el humano, los fotogramas van solo al portador

**Files:**
- Modify: `browser/relay.py`
- Test: `browser/test_app.py`

**Interfaces:**
- Consumes: de la Tarea 4, `Relay.mando`, `Relay.toma_el_mando(viewer)` y el
  `_cablear` que ya pasa el relé a `tras`. Esta tarea no crea arnés nuevo.

Hoy `_fan_out` reparte el fotograma a **todos** los visores. Cuando el usuario
teclee una contraseña durante un paso de mando, lo que la filtra no es el teclado:
es la imagen. Esto es la mitad que falta de «un solo portador».

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
def test_mientras_conduce_el_humano_el_fotograma_va_solo_al_portador():
    portador, mirón = VisorFalso(), VisorFalso()
    guion = [_paso(_frame(1)), _paso(_frame(2), espera_acuse=True),
             _paso(_frame(3), espera_acuse=True)]
    async def comprobar(rele):
        rele.toma_el_mando(portador)
        assert await _esperar(lambda: len(portador.frames) >= 3)
    asyncio.run(_cablear(guion, [(portador, 0), (mirón, 0)],
                         lambda: len(portador.frames) >= 1, tras=comprobar))
    antes = 1  # el o los que vio antes de que se tomara el mando
    assert len(mirón.frames) <= antes, "el mirón deja de ver la pantalla del humano"
    assert len(portador.frames) >= 3

def test_mientras_conduce_el_agente_el_fotograma_va_a_todos():
    # Sin tomar el mando, los dos visores ven el mismo primer seq (como hoy).

def test_el_estado_y_el_resumen_siguen_yendo_a_todos():
    # Un visor que no conduce tiene que SABER que no conduce: el mensaje de
    # estado no es el fotograma y no se restringe.
    # assert "mando" in mirón.tipos (o el estado que publique la Tarea 4)

def test_el_acuse_del_portador_basta_para_acusar_al_demonio():
    # Con el mando tomado y el mirón con auto_ack=False, el guion con
    # espera_acuse=True sigue fluyendo: assert [a["seq"] for a in acuses[:2]] == [1, 2]
    # Si el relé esperara al mirón, que ya no recibe frames, el flujo se pararía.
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py -v -k "fotograma"`
Expected: FAIL.

- [ ] **Step 3: Restringir el reparto del fotograma en `_fan_out`**

Solo el fotograma se restringe; el estado, el resumen, la narración y el host
siguen yendo a todos. Comentar **por qué** (lo de la contraseña por la imagen) y
**la consecuencia sobre el acuse**: con un solo destinatario, `_pending_viewers`
es ese y el ritmo depende de él.

- [ ] **Step 4: Correr y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add browser/relay.py browser/test_app.py
git commit -m "fix(mando): el fotograma va solo al portador mientras conduce el humano"
```

---

### Task 6: El `Origin` y el límite de caudal de la entrada

**Files:**
- Modify: `browser/app.py`, `browser/relay.py`
- Test: `browser/test_app.py`

Un WebSocket **no respeta CORS**. Sin comprobar el `Origin`, cualquier página que
el usuario visite podría abrir el socket del relé y conducir su Chrome logueado con
solo conocer el token. El demonio tiene esa protección —da 403 a un origen no
local— y **el relé la perdió al ponerse delante**.

Y el token **viaja en la query** (`?token=`, `app.py` en el endpoint del stream;
es la única vía de un cliente de WebSocket que no puede poner cabeceras). Un token
en una URL se filtra en historiales, registros y referers, así que el `Origin` no
es una capa de más: es la única que queda cuando el token se escapa. Hasta hoy eso
no importaba porque **ningún mensaje del visor llegaba al navegador**; la Tarea 4
acaba de cambiar eso, y es lo que convierte esta tarea en obligatoria y no en
higiene.

**Dónde va:** en `browser_stream`, junto a la comprobación del token y **antes de
`ws.accept()`** —un rechazo de handshake, no un `closed`—, porque un origen no
permitido no debe llegar ni a levantar un Chromium. El `Origin` se lee de
`ws.headers.get("origin")`.

**Ojo con el Review Focus 4:** la app de Swift **no manda `Origin`**. Ausente se
acepta; presente se comprueba contra una lista de permitidos. Rechazar lo ausente
rompería el teléfono, que es el cliente principal.

**Interfaces:**
- Produces: `BROWSER_ALLOWED_ORIGINS`, variable de entorno con una lista separada
  por comas; vacía significa «solo clientes sin `Origin`».
- Produces: `relay.origen_aceptado(origen: str | None, permitidos: frozenset[str]) -> bool`,
  pura y probable sola.
- Produces: el tope de entrada por visor en `relay.py`, con su constante y su
  procedencia en el comentario.

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
# Review Focus 4
def test_un_cliente_sin_origin_se_acepta():
    assert relay.origen_aceptado(None, frozenset()) is True

def test_un_origin_no_permitido_se_rechaza():
    assert relay.origen_aceptado("https://evil.example", frozenset({"http://localhost:8083"})) is False

def test_un_origin_permitido_se_acepta():
    assert relay.origen_aceptado("http://localhost:8083", frozenset({"http://localhost:8083"})) is True

def test_sin_lista_de_permitidos_ningun_origin_pasa():
    # Un navegador solo entra si alguien lo autorizo explicitamente.
    assert relay.origen_aceptado("http://localhost:8083", frozenset()) is False

async def test_el_upgrade_con_origin_no_permitido_se_cierra():
    # El endpoint ws de app.py rechaza antes de aceptar el socket.

# Review Focus 5
async def test_una_inundacion_de_entrada_se_recorta_y_no_tumba_el_ritmo():
    # N eventos muy por encima del tope en una ventana: los de mas se descartan,
    # el visor NO se desconecta, y un ack posterior sigue llegando al demonio.
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py browser/test_compose.py -v -k "origen or origin or inundacion"`
Expected: FAIL.

- [ ] **Step 3: Implementar la comprobación y el tope**

`origen_aceptado` pura en `relay.py`. El endpoint del socket en `app.py` la
consulta **antes** de aceptar. El tope de entrada es por visor y por ventana de
tiempo, descarta en vez de desconectar (un visor legítimo con el dedo pegado no
merece perder la sesión), y su comentario dice de dónde sale el número y por qué
descartar y no cerrar.

- [ ] **Step 4: Añadir la variable al compose y su candado**

`BROWSER_ALLOWED_ORIGINS` en **los dos** composes (`docker-compose.browser.yml` y
`docker-compose.yml`), vacía por omisión, y una prueba en `browser/test_compose.py`
que exija que esté declarada en los dos y que **coincida**, como ya hace la de
nitidez.

- [ ] **Step 5: Correr y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add browser/app.py browser/relay.py browser/test_app.py browser/test_compose.py docker-compose.browser.yml docker-compose.yml
git commit -m "fix(mando): comprobar el Origin del visor y acotar su caudal de entrada"
```

---

### Task 7: Los endpoints del mando, y el agente deja de mirar la página

**Files:**
- Modify: `browser/app.py`
- Test: `browser/test_app.py`

**Interfaces:**
- Consumes: de la Tarea 4, `Relay.mando` y el manejo de `mando_tomar` /
  `mando_devolver` por el socket del visor. **Tomar y devolver NO son endpoints
  HTTP** (Global Constraints: el portador es un socket).
- Produces: `GET /v1/browser/mando` → `{"quien": "agente"|"humano"}`, y
  `POST /v1/browser/mando/pedir` (la señal del agente cuando detecta un muro; no
  cambia quién conduce).
- Produces: `/v1/browser/invoke` rechaza con **409** y un motivo legible mientras
  conduce el humano.

Esto es lo que hace que el mando **se imponga** en vez de prometerse. Y la
restricción del spec se extiende: el agente no mira la página **ni en el instante
siguiente** a que el mando vuelva, porque los datos están en la página de después.

- [ ] **Step 1: Escribir las pruebas que fallan**

Con `client` y `AUTH`, que el fichero ya tiene, y `monkeypatch.setattr(appmod,
"_relay", …)` para el relé, igual que hace `_max_fps_que_recibe_el_rele`:

El estado se fuerza por `monkeypatch` sobre un relé propio, **no tomando el mando
de verdad**: el `client` del módulo comparte el relé entre pruebas y un mando
tomado y no devuelto contaminaría a la siguiente.

```python
def _con_mando(monkeypatch, quien):
    """Un relé falso cuyo mando dice `quien`. Es la unica forma limpia de probar
    la puerta del invoke: tomar el mando de verdad necesita un socket."""
    rele = type("ReleFalso", (), {"mando": mando.Mando()})()
    if quien == "humano":
        rele.mando.toma(object(), 0.0)
    monkeypatch.setattr(appmod, "_relay", lambda: rele)
    return rele

def test_los_endpoints_del_mando_piden_token():
    assert client.get("/v1/browser/mando").status_code == 401
    assert client.post("/v1/browser/mando/pedir").status_code == 401

def test_get_mando_dice_quien_conduce(monkeypatch):
    _con_mando(monkeypatch, "agente")
    r = client.get("/v1/browser/mando", headers=AUTH)
    assert r.status_code == 200 and r.json()["quien"] == "agente"
    _con_mando(monkeypatch, "humano")
    assert client.get("/v1/browser/mando", headers=AUTH).json()["quien"] == "humano"

def test_invoke_se_rechaza_con_409_mientras_conduce_el_humano(monkeypatch):
    _con_mando(monkeypatch, "humano")
    r = client.post("/v1/browser/invoke", json={"arguments": ["get", "text", "body"]},
                    headers=AUTH)
    assert r.status_code == 409
    assert "mando" in json.dumps(r.json()).lower()

def test_invoke_pasa_cuando_conduce_el_agente(monkeypatch):
    # El candado al reves: sin el, un 409 permanente pasaria por exito.

def test_el_motivo_del_409_no_reproduce_nada_de_la_pagina(monkeypatch):
    # Mismo criterio que test_el_motivo_de_un_argumento_rechazado_no_reproduce_su_valor:
    # el motivo nombra el estado, nunca la URL ni el contenido.

def test_el_agente_no_puede_mirar_la_pagina_justo_despues_de_recuperar_el_mando(monkeypatch):
    # Mando devuelto en t=0 con la gracia sin agotar: `get text` sigue en 409,
    # y `open` y `close` pasan, porque son la salida del muro.

def test_pedir_el_mando_lo_pide_pero_no_lo_toma(monkeypatch):
    # /pedir es la senal del agente al usuario: NO cambia quien conduce.
    _con_mando(monkeypatch, "agente")
    assert client.post("/v1/browser/mando/pedir", headers=AUTH).status_code == 200
    assert client.get("/v1/browser/mando", headers=AUTH).json()["quien"] == "agente"
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py -v -k "mando or invoke"`
Expected: FAIL.

- [ ] **Step 3: Implementar los endpoints y la puerta del `invoke`**

Los cuatro endpoints, con el mismo bearer que el resto del servicio. La puerta del
`invoke` consulta `relay.mando` y devuelve 409 con un motivo que **no** reproduce
nada de la página. La gracia posterior al regreso es una constante con su
procedencia comentada, y la lista de subcomandos que SÍ se permiten durante ella
(`open`, `close`) va escrita y probada, no inferida.

- [ ] **Step 4: Correr la suite entera**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add browser/app.py browser/test_app.py
git commit -m "feat(mando): los endpoints del mando, y el invoke se cierra mientras conduce el humano"
```

---

### Task 8 (controlador): desplegar y medirlo en vivo

**No es tarea de un implementador:** toca el i3 y docker, y eso lo hace el
controlador.

- [ ] **Step 1: Sincronizar y reconstruir solo el servicio nombrado**

Respaldo primero, luego copiar a `~/Projects/gemma-browser/` y
`docker compose up -d --build browser`. **Nunca un `down` sin nombre de servicio.**

- [ ] **Step 2: Verificar en vivo, con el token por variable de entorno**

Contenedor `healthy`, `/healthz` 200, `GET /v1/browser/mando` dice `agente`,
tomar el mando cambia el estado, un `invoke` da 409 mientras conduce el humano, y
un `input_mouse` del portador mueve la página de verdad (`scrollOffsetY` cambia).

- [ ] **Step 3: Escribir la medición**

`docs/superpowers/notes/2026-11-08-mando-medicion.md` en `personal_agent`, con lo
que se verificó en vivo y lo que no se pudo.

---

## Lo que este plan NO hace, a propósito

- **La reanudación del turno.** El spec decide que el turno termine y se reanude;
  eso vive en la app (Swift) y es el subsistema B. A deja el estado expuesto y
  acotado, que es lo que B necesita.
- **Avisar al usuario.** También B.
- **El cliente web, el puntero y el mapeo de coordenadas.** B.
- **El perfil persistente, el modo con ventana y el idioma.** C.
- **El plazo de inactividad a 10 minutos**, que se congela al crear el demonio y
  pide su propia medición. C.
- **La identidad del agente.** D.
- **Gobernar el camino del navegador LOCAL** (cuando no hay `browserBaseURL` y el
  agente conduce el navegador de la máquina del usuario). Es un agujero real que el
  revisor señaló, pero vive en la app, no en el servicio: va a B.
