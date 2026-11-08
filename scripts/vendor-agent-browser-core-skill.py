#!/usr/bin/env python3
"""Vuelca la salida de `agent-browser skills get core` en un fuente Swift.

Uso:
    python3 -I vendor_core_skill.py <core-skill.md> <BrowserCoreSkill.swift>

El texto se emite dentro de un literal de cadena CRUDA multilinea de Swift, que es el unico
que sobrevive sin escapar nada a las comillas, las barras invertidas y las secuencias de
interpolacion que trae el markdown de la guia. El script se niega a escribir si el texto
contiene el terminador de ese literal, y deja una linea vacia extra antes del cierre para que
el literal conserve el salto de linea final del fichero original (Swift descarta el salto que
precede al delimitador de cierre, asi que sin esa linea el literal mediria un byte menos que
la salida real del CLI).
"""
import sys

CLI_VERSION = "0.41.2"
CAPTURED = "2026-11-08"
COMMAND = "agent-browser skills get core"


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as fh:
        raw = fh.read()
    text = raw.decode("utf-8")

    if '"""#' in text:
        print("ERROR: el texto contiene el terminador del literal crudo", file=sys.stderr)
        return 1
    if "\r" in text:
        print("ERROR: el texto trae CRLF; normalizalo antes de vendorizarlo", file=sys.stderr)
        return 1

    lines = text.split("\n")
    # `text` termina en "\n", asi que `lines` acaba en "". Esa cadena vacia es justamente la
    # linea en blanco que compensa el salto que Swift descarta antes del cierre.
    if lines[-1] != "":
        print("ERROR: se esperaba que la guia terminase en salto de linea", file=sys.stderr)
        return 1

    # El salto que Swift descarta es el que precede al delimitador de cierre. Para que el
    # literal conserve el "\n" final del fichero hace falta una linea EN BLANCO entre la
    # ultima linea de la guia y el cierre, es decir un "\n" mas que el texto original.
    body = text + "\n"

    header = f'''//
//  BrowserCoreSkill.swift
//  Gemma
//
//  FICHERO GENERADO — no editar a mano.
//
//  Guia oficial de uso de `agent-browser`, escrita por el autor del CLI para que la lean
//  agentes de IA. Nuestro agente conduce ese mismo CLI a traves de las herramientas
//  `browser_*` (ver `Agent.browserToolNames`) y hasta ahora solo habia visto la linea
//  escrita a mano que vive en el prompt del sistema. Esta es la guia entera, tal cual.
//
//  PROCEDENCIA (para que un lector futuro pueda saber si esta copia ha derivado):
//    - Comando exacto:  `{COMMAND}`
//    - Version del CLI: {CLI_VERSION}  (la que pinea `gemma-memory/browser/Dockerfile`:
//                       `npm install -g agent-browser@{CLI_VERSION}`, que es el CLI que
//                       corre de verdad en el servidor del usuario)
//    - Fecha de captura: {CAPTURED}
//    - Tamano exacto:    {len(raw)} bytes UTF-8, {text.count(chr(10))} lineas, termina en salto de linea
//
//  `BrowserCoreSkillTests` pinea ese tamano en bytes: si alguien re-captura la guia desde
//  otra version del CLI y no actualiza esta cabecera, el test se pone rojo y el lector sabe
//  que la cabecera y el contenido han dejado de corresponderse.
//
//  Como se regenera: se vuelca la salida del comando en un literal de cadena CRUDA
//  (`#"""..."""#`). Crudo a proposito: la guia lleva comillas, `#"..."` y signos que en un
//  literal normal de Swift habria que escapar uno a uno; en uno crudo el texto entra tal
//  cual y no hay interpolacion que lo altere.
//
//  Donde se usa: `Agent.browserGuideBlock()` lo pega a la nota de resultado de la PRIMERA
//  herramienta de navegador de cada turno (una sola vez por turno). No vive en el prompt del
//  sistema a proposito: son ~14 KB que de otro modo pagaria cada turno, incluidos los que
//  solo contestan una pregunta y nunca abren una pagina.
//

enum BrowserCoreSkill {{
    /// El texto integro de la guia, byte a byte como lo imprime el CLI.
    static let text = #"""
'''

    swift = header + body + '"""#\n}\n'
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(swift)
    print(f"escrito {dst}: {len(swift)} bytes de Swift para {len(raw)} bytes de guia")
    return 0


if __name__ == "__main__":
    sys.exit(main())
