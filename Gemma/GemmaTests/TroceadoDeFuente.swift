import Foundation

/// **EL TROCEADO DEL FUENTE PARA LAS PRUEBAS QUE LEEN EL FUENTE.** Una sola implementación, y
/// ésa es la característica, no una comodidad.
///
/// POR QUÉ VIVE AQUÍ Y NO EN CADA PANTALLA. **Cinco** redes de seguridad de este proyecto leen el
/// fuente y miden sobre el texto troceado:
///
///  1. la lista blanca del mando (`BrowserPanelViewTests`), por la que pasa **la contraseña del
///     usuario** y la coordenada de su dedo;
///  2. la lista blanca del mapa del toque (`BrowserInputMapperTests`);
///  3. la lista blanca del llavero y el token (`TokenDeConducirTests`), por la que pasa **el token
///     que conduce un Chrome con la sesión de Google del usuario dentro**;
///  4. la lista blanca de las claves de pago (`ClaveDeProveedorTests`) **y**, en el mismo fichero,
///     la regla que impide que el llavero **global** —donde viven las API keys de pago de
///     PRODUCCIÓN— se use como argumento;
///  5. el trinquete del placeholder débil del token de memoria (`TokenDeMemoriaTests`), que impide
///     que vuelva a cablearse en el binario la credencial conocida del `.env` del i3.
///
/// Las cinco sostienen la misma propiedad: que por esos ficheros no pase nada que registre,
/// persista, notifique o acumule un secreto del usuario. **Tenían cinco copias del mismo troceado,
/// carácter por carácter**, y eso es exactamente cómo se arregla un agujero y siguen vivos los
/// otros cuatro: el 2026-11-09 se midió que el corte ciego dejaba pasar una fuga, se arregló
/// **una** copia, luego **tres**, y las dos últimas siguieron abiertas hasta esta ronda — una de
/// ellas dentro de un fichero que un informe ya daba por limpio. La afirmación «cero copias» se
/// escribió **dos rondas antes** de ser verdad.
///
/// LO QUE SE MIDIÓ, porque es el motivo de que esto no sea un refactor cosmético. Con el corte
/// ciego, estas mutaciones dejaban la suite **entera** en su verde exacto:
///
///     // en `BrowserInputMapper.paginaDesde`, que ve DÓNDE toca el usuario
///     let width = "x//y"; print("toque en \(punto)")                      → VERDE
///     // en `TokenDeConducir.guardar`, que ve el TOKEN del navegador
///     let texto = "dev//dev"; print("token \(valor)")                      → VERDE
///     // en `ClaveDeProveedor.guardar`, que ve las CLAVES DE PAGO del usuario
///     let texto = "dev//dev"; print("clave \(valor)")                      → VERDE
///     // en `HarnessModel.chatProvider`, contra la regla del llavero GLOBAL (ronda 4)
///     let ayuda = "//"; _ = ClaveDeProveedor.leer(proveedor: "cerebras",
///                                                 almacen: LlaveroDelSistema.compartido) → VERDE
///     // en `MemoryClient`, contra el trinquete del placeholder débil (ronda 4)
///     let ayuda = "//"; let debil = "replace-me-…"; _ = debil               → VERDE
///
/// y sus controles —las mismas líneas **a la vista**— salían rojos. Es decir: las cinco redes
/// existían, funcionaban, y bastaba una cadena con `//` por delante para cegarlas.
///
/// Cada una de las cinco se midió **aparte y a propósito**, aunque compartan el troceado y por
/// tanto estuvieran cubiertas por deducción: en esta misma tarea la cobertura deducida falló
/// **tres** veces, y las tres el argumento parecía correcto.
enum TroceadoDeFuente {

    /// El estado del troceador. Son cuatro contextos y no dos, y eso es justo lo que las dos
    /// versiones anteriores no modelaban: dentro de una cadena, dentro de un literal de regex
    /// extendido, y dentro de una **interpolación**, que es código otra vez y puede llevar otra
    /// cadena dentro, con su propia profundidad de paréntesis.
    private enum Marco {
        case cadena(numerales: Int, multilinea: Bool)
        case regex(numerales: Int, multilinea: Bool)
        case interpolacion(parentesis: Int)
    }

    /// El fuente sin sus comentarios —de línea (`//`) **y de bloque** (`/* … */`)—, que es el paso
    /// previo de **toda** medición sobre el fuente de este proyecto: una aserción contra el fuente
    /// crudo se cumple con la característica escrita en un comentario, y eso ya se midió dos veces
    /// en esta rama.
    ///
    /// # QUÉ DEFIENDE ESTO, Y ES EL MOTIVO DE QUE EXISTA
    ///
    /// Que un cambio futuro que **registre, persista, notifique o acumule un secreto escrito de
    /// forma normal** ponga roja una de las cinco redes de arriba. Ésa es la amenaza real y está
    /// medida en esta rama cuatro veces: alguien añade un `print` o un `UserDefaults.set` en un
    /// fichero por el que pasa la contraseña del usuario, y **no se entera**, porque la línea de
    /// al lado llevaba una URL con `//` dentro de una cadena y el troceado se tragó la línea
    /// entera. No hace falta mala fe para tropezar con eso: `let ayuda = "https://…"` con
    /// cualquier cosa detrás en la misma línea ya lo dispara.
    ///
    /// # QUÉ NO DEFIENDE, DICHO SIN ADORNOS
    ///
    /// A alguien que **esconda código a propósito**. Un troceado escrito a mano es un analizador
    /// léxico de Swift compitiendo con el compilador, y **no va a ganar**: cada forma léxica que
    /// Swift tenga y aquí no esté modelada es un camino para esconder una línea, y la lista de
    /// abajo es la de las que **sé** que quedan, no la de las que hay. Si esta propiedad tiene que
    /// resistir a un adversario, lo que hace falta es un analizador de verdad (SwiftSyntax), no
    /// una ronda más de parches; está dicho con su coste en el informe de la ronda 4.
    ///
    /// Y EL ARGUMENTO QUE LAS CINCO COPIAS TENÍAN ESCRITO ERA DEL TIPO EQUIVOCADO. Decían, cada
    /// una a su manera, que el corte «es seguro en ESTE fichero porque ninguna de sus cadenas
    /// contiene `//`»: eso es una afirmación sobre **el contenido de hoy**, no una propiedad, y
    /// una línea nueva la tumba. Dos de ellas añadían que «si alguna llegara a contenerlo, el
    /// guarda de vacuidad lo caza», y eso es **falso**: ese guarda (el ancla de ruta y el recuento
    /// mínimo) detecta que el troceado **entero** se rompa, no que se le esconda **una** línea.
    /// Hay siete líneas legítimas con el llavero global, así que esconder la octava sobra para
    /// pasar un `>= 3` — medido.
    ///
    /// # EL CRITERIO CUANDO EL TROCEADO SE EQUIVOCA
    ///
    /// Los dos errores no son simétricos y no hay una dirección segura, que es el otro argumento
    /// que esta rama tuvo escrito y no se sostiene:
    ///
    ///  - **Cortar de MÁS** (tragarse código) deja ciegas las cuatro reglas de AUSENCIA: la fuga
    ///    pasa en verde. **Silencio.** Medido cuatro veces (el corte ciego).
    ///  - **Cortar de MENOS** (dejar un comentario dentro) pone rojas las listas blancas con la
    ///    prosa del comentario —ruido visible— pero deja ciegas las aserciones de **presencia**:
    ///    la característica se puede escribir en un comentario y la prueba pasa. **También
    ///    silencio**, por el otro lado. Medido: con el `.overlay` del anillo envuelto en `/* */`
    ///    —la característica BORRADA, el texto conservado— la suite entera se quedaba en su verde
    ///    exacto y pasaban las trece comprobaciones de la prueba del anillo, incluido su guardián
    ///    de esquema cerrado, porque cuenta texto.
    ///
    /// Así que la respuesta no es elegir un lado: es **no adivinar** donde se puede lexar bien, y
    /// donde haya que adivinar, **acotar el daño a una línea**. De ahí la resincronización en el
    /// salto de línea: una cadena de una línea sin cerrar es un troceado roto, y limitar el
    /// estropicio a esa línea es la diferencia entre una prueba roja y un fichero entero sin
    /// medir. Es lo que mataba el hueco de los `"""` descompensados de la versión anterior, que
    /// apagaba el quitado de comentarios **en todo el resto del fichero**.
    ///
    /// **POR QUÉ NO SE BLANQUEA EL INTERIOR DE LAS CADENAS, que era la otra vía.** Porque abre un
    /// agujero peor: una interpolación puede llevar una llamada **con efectos**
    /// (`"\(UserDefaults.standard.set(x, forKey: k))"`), así que esconder el interior de las
    /// cadenas esconde código ejecutable de la lista blanca. Se conserva el contenido, y como
    /// efecto secundario las palabras de las cadenas siguen entrando en el conjunto — que es
    /// justo lo que las cinco redes ya tenían asumido y justificado.
    ///
    /// # LOS HUECOS QUE QUEDAN, UNO POR UNO, CON SU DISPARADOR, Y NO ATRIBUIDOS A NINGUNA PRUEBA
    ///
    ///  1. **Literales de regex corrientes (`/…/`).** No se reconocen: para el troceado son dos
    ///     operadores de división. **No tengo un disparador**, y el motivo es léxico: un `/` sin
    ///     escapar cierra el literal, así que un `//` no puede aparecer dentro de uno. Lo escribo
    ///     igual porque es la forma que **no** está modelada, no porque la haya conseguido usar.
    ///     (El extendido, `#/…/#`, sí está modelado: ahí un `/` suelto es legal y era un camino de
    ///     verdad. Medido en `TroceadoDeFuenteTests`.)
    ///  2. **Un `/*` sin cerrar se come el resto del fichero.** Disparador exacto: un `/*` en
    ///     contexto de código sin un `*/` detrás. Medido. No es alcanzable en un fichero
    ///     commiteado, porque **no compila**: la corrección del quitado de bloques se apoya en que
    ///     el fichero compile, y eso es una dependencia, no una garantía propia.
    ///  3. **Cuatro comillas seguidas en código (`""""`).** Se cierra el multilínea con las tres
    ///     primeras y queda una comilla suelta, que abre una cadena que muere en el salto de línea
    ///     por la resincronización. Medido: **no esconde** (el resto de la línea sigue visible),
    ///     pero el troceado deja de ser correcto desde ahí hasta el final de la línea.
    ///  4. **Compilación condicional.** `#if os(iOS)` no se interpreta: los identificadores de las
    ///     **dos** ramas entran en el conjunto. No es un hueco de silencio —se ve más, no menos—,
    ///     pero una lista blanca puede estar permitiendo un nombre de una rama que en esta
    ///     plataforma no se compila.
    ///  5. **Lo que Swift añada mañana a su gramática léxica.** Es el hueco de fondo y no se cierra
    ///     con otra ronda: ver «QUÉ NO DEFIENDE».
    ///
    /// La resincronización acota un error de lexado a **una línea** solo cuando el marco mal
    /// abierto es de una línea (cadena normal o regex extendido en una línea). Un error dentro de
    /// un literal multilínea, de un regex extendido multilínea o de un comentario de bloque **no
    /// está acotado**: se arrastra hasta que su cierre aparezca.
    static func sinComentarios(_ fuente: String) -> String {
        let c = Array(fuente)
        var salida = ""
        salida.reserveCapacity(c.count)
        var i = 0
        var pila: [Marco] = []

        /// Cuántos `cual` seguidos hay a partir de `desde`. Los `#` de las cadenas crudas y las
        /// comillas de los multilínea se cuentan, no se suponen.
        func corrida(_ desde: Int, _ cual: Character) -> Int {
            var n = 0
            var j = desde
            while j < c.count, c[j] == cual { n += 1; j += 1 }
            return n
        }

        while i < c.count {
            let ch = c[i]

            // LA RESINCRONIZACIÓN. Si al llegar al salto de línea hay abierto un marco que no
            // puede cruzar líneas, el lexado está roto: se cierra ése y todo lo que se apoyaba en
            // él, para que el estropicio no pase de esta línea. Ver el doc-comment.
            if ch == "\n" {
                if let k = pila.firstIndex(where: {
                    switch $0 {
                    case .cadena(_, let multilinea), .regex(_, let multilinea): return !multilinea
                    case .interpolacion: return false
                    }
                }) {
                    pila.removeSubrange(k...)
                }
                salida.append(ch)
                i += 1
                continue
            }

            switch pila.last {
            case .some(.cadena(let numerales, let multilinea)):
                // En una cadena CRUDA la contrabarra no escapa nada por sí sola: hacen falta sus
                // `#`. Tratarla como escape era el bypass medido de `#"\"#`, que se comía la
                // comilla de cierre y dejaba el troceador creyendo que estaba en código.
                if ch == "\\" {
                    var j = i + 1
                    var vistos = 0
                    while vistos < numerales, j < c.count, c[j] == "#" { vistos += 1; j += 1 }
                    // `\(`, o `\#(` con los `#` de esta cadena: interpolación. Es CÓDIGO otra vez,
                    // y puede llevar otra cadena dentro — de ahí la pila y no un `Bool`.
                    if vistos == numerales, j < c.count, c[j] == "(" {
                        salida.append(contentsOf: c[i...j])
                        pila.append(.interpolacion(parentesis: 1))
                        i = j + 1
                        continue
                    }
                    if vistos == numerales, j < c.count, c[j] != "\n" {
                        salida.append(contentsOf: c[i...j])
                        i = j + 1
                        continue
                    }
                    salida.append(ch)
                    i += 1
                    continue
                }
                if ch == "\"" {
                    let comillasDelCierre = multilinea ? 3 : 1
                    if corrida(i, "\"") >= comillasDelCierre,
                       corrida(i + comillasDelCierre, "#") >= numerales {
                        let largo = comillasDelCierre + numerales
                        salida.append(contentsOf: c[i..<(i + largo)])
                        pila.removeLast()
                        i += largo
                        continue
                    }
                    salida.append(ch)
                    i += 1
                    continue
                }
                salida.append(ch)
                i += 1

            case .some(.regex(let numerales, _)):
                // Literal de regex EXTENDIDO (`#/…/#`): ahí un `/` suelto es legal, así que un
                // `//` dentro no es un comentario. Era un camino de verdad para esconder media
                // línea, medido antes de cerrarlo.
                if ch == "\\", i + 1 < c.count, c[i + 1] != "\n" {
                    salida.append(contentsOf: c[i...(i + 1)])
                    i += 2
                    continue
                }
                if ch == "/", corrida(i + 1, "#") >= numerales {
                    let largo = 1 + numerales
                    salida.append(contentsOf: c[i..<(i + largo)])
                    pila.removeLast()
                    i += largo
                    continue
                }
                salida.append(ch)
                i += 1

            default:
                // CONTEXTO DE CÓDIGO: fuera de toda cadena, o dentro de una interpolación.
                if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                    while i < c.count, c[i] != "\n" { i += 1 }
                    continue
                }
                // LOS COMENTARIOS DE BLOQUE DE SWIFT **ANIDAN**: `/* /* */ */` es uno solo, así
                // que hace falta un contador de profundidad y no «busca el primer `*/`». Los
                // saltos de línea se conservan para que el texto troceado siga teniendo las
                // mismas líneas: las aserciones de bloque contiguo de la prueba del anillo
                // dependen de eso.
                if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                    var profundidad = 1
                    i += 2
                    while i < c.count, profundidad > 0 {
                        if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" {
                            profundidad += 1
                            i += 2
                        } else if c[i] == "*", i + 1 < c.count, c[i + 1] == "/" {
                            profundidad -= 1
                            i += 2
                        } else {
                            if c[i] == "\n" { salida.append("\n") }
                            i += 1
                        }
                    }
                    continue
                }
                // `#` + `/` abre un regex extendido; `#` + `"` abre una cadena cruda; `#` a secas
                // es `#available`, `#if`, `#filePath`… y no abre nada.
                if ch == "#" {
                    let numerales = corrida(i, "#")
                    if i + numerales < c.count, c[i + numerales] == "/" {
                        let largo = numerales + 1
                        let multilinea = i + largo < c.count && c[i + largo] == "\n"
                        salida.append(contentsOf: c[i..<(i + largo)])
                        pila.append(.regex(numerales: numerales, multilinea: multilinea))
                        i += largo
                        continue
                    }
                }
                if ch == "#" || ch == "\"" {
                    let numerales = ch == "#" ? corrida(i, "#") : 0
                    if i + numerales < c.count, c[i + numerales] == "\"" {
                        let multilinea = corrida(i + numerales, "\"") >= 3
                        let largo = numerales + (multilinea ? 3 : 1)
                        salida.append(contentsOf: c[i..<(i + largo)])
                        pila.append(.cadena(numerales: numerales, multilinea: multilinea))
                        i += largo
                        continue
                    }
                    let largo = max(numerales, 1)
                    salida.append(contentsOf: c[i..<(i + largo)])
                    i += largo
                    continue
                }
                // El cierre de una interpolación necesita su propio contador: `"\(f(g("//")))"`
                // tiene tres paréntesis y el `//` vive en una cadena de dentro.
                if let ultimo = pila.last, case .interpolacion(let abiertos) = ultimo,
                   ch == "(" || ch == ")" {
                    let ahora = ch == "(" ? abiertos + 1 : abiertos - 1
                    salida.append(ch)
                    i += 1
                    if ahora <= 0 {
                        pila.removeLast()
                    } else {
                        pila[pila.count - 1] = .interpolacion(parentesis: ahora)
                    }
                    continue
                }
                salida.append(ch)
                i += 1
            }
        }
        return salida
    }

    /// Los identificadores de un fuente Swift, **sin los comentarios**.
    ///
    /// Los comentarios se quitan porque son prosa y meterían cientos de palabras en el conjunto,
    /// que es justo lo que haría inútil la lista blanca. El troceado reconoce letras Unicode a
    /// propósito: los identificadores de este proyecto llevan `ñ` (`tamañoDeLaVista`) y
    /// partirlos daría trozos que no están en la lista.
    static func identificadores(de fuente: String) -> Set<String> {
        let troceado = Self.sinComentarios(fuente)

        var encontrados: Set<String> = []
        var actual = ""
        for caracter in troceado.unicodeScalars {
            let esLetra = CharacterSet.letters.contains(caracter)
            let esDigito = CharacterSet.decimalDigits.contains(caracter)
            if esLetra || caracter == "_" || (!actual.isEmpty && esDigito) {
                actual.unicodeScalars.append(caracter)
            } else {
                if !actual.isEmpty { encontrados.insert(actual) }
                actual = ""
            }
        }
        if !actual.isEmpty { encontrados.insert(actual) }
        return encontrados
    }
}
