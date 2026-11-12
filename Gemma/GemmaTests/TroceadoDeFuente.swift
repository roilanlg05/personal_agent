import Foundation

/// **EL TROCEADO DEL FUENTE PARA LAS PRUEBAS QUE LEEN EL FUENTE.** Una sola implementación, y
/// ésa es la característica, no una comodidad.
///
/// POR QUÉ VIVE AQUÍ Y NO EN CADA PANTALLA. **Tres** redes de seguridad de este proyecto leen el
/// fuente (eran cinco: las del mando y la del mapa del toque murieron con el mando, y sus
/// medidas de abajo se conservan como historia de por qué existe el troceado) y miden sobre el texto troceado:
///
///  1. la lista blanca del llavero y el token (`TokenDeConducirTests`), por la que pasa **el token
///     que conduce un Chrome con la sesión de Google del usuario dentro**;
///  2. la lista blanca de las claves de pago (`ClaveDeProveedorTests`) **y**, en el mismo fichero,
///     la regla que impide que el llavero **global** —donde viven las API keys de pago de
///     PRODUCCIÓN— se use como argumento;
///  3. el trinquete del placeholder débil del token de memoria (`TokenDeMemoriaTests`), que impide
///     que vuelva a cablearse en el binario la credencial conocida del `.env` del i3.
///
/// Las tres sostienen la misma propiedad: que por esos ficheros no pase nada que registre,
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
///
/// # LA REGLA, Y ES LA QUE IMPIDE QUE ESTO VUELVA A PASAR
///
/// **Toda prueba de este proyecto que lea fuente Swift usa este troceado.** No «las listas
/// blancas»: **toda**. Y **una copia a mano es un bypass por construcción**, porque cada arreglo
/// que entra aquí pasa de largo por ella — eso es literalmente la historia de este fichero: cinco
/// copias, tres arreglos, y la frase «cero copias restantes» escrita dos rondas antes de ser
/// verdad. El censo de la ronda 4 se hizo buscando la **forma exacta** (`range(of: "//")`) y por
/// eso no encontró la sexta copia, que estaba escrita con `hasPrefix("//")`. Un censo por forma no
/// es un censo: lo que hay que enumerar son **las pruebas que leen fuente**.
///
/// # EL CENSO, ENUMERADO (2026-11-10), QUE ES LO QUE CIERRA EL CONJUNTO
///
/// Siete ficheros de prueba localizan ficheros del proyecto con `#filePath` (sin contar este).
/// **Seis** leen fuente Swift, y los seis pasan por aquí:
///
///     fichero de prueba                 qué lee                      cómo mide
///     TokenDeConducirTests              TokenDeConducir, TokenDeMemoria,
///                                       SettingsView, GemmaApp           troceado + 1 ausencia cruda
///     ClaveDeProveedorTests             ClaveDeProveedor, LlaveroViejo…,
///                                       HarnessModel, SettingsView,
///                                       GemmaApp                         troceado + 3 ausencias crudas
///     TokenDeMemoriaTests               SettingsView, HarnessModel,
///                                       GemmaApp                         troceado + 3 ausencias crudas
///     AgentBrowserRegistrationTests     HarnessModel                     troceado
///     FormDraftTests                    FormCardView, AgentChatView      troceado
///     BrowserFillSecretToolTests        BrowserFillSecretTool            troceado
///     InfoPlistPrivacyKeysTests         AppInfo.plist                    n/a: no es fuente Swift
///     ElMandoNoExisteTests              todo Gemma/Gemma                 ausencias crudas, a propósito
///
/// # Y POR QUÉ ALGUNAS ASERCIONES SE QUEDAN SOBRE EL FUENTE CRUDO, A PROPÓSITO
///
/// Porque las dos direcciones del error no son simétricas, y cada clase de aserción se mide donde
/// no se la puede engañar:
///
///  - una **PRESENCIA** (incluidos **todos** los guardas de vacuidad, que son presencias) va sobre
///    el **troceado**: sobre el crudo se cumple con la característica BORRADA —se envuelve la
///    línea en `/* */`, el código desaparece y el texto se conserva—;
///  - una **AUSENCIA** va sobre el **crudo**: ahí lo peligroso es lo contrario, que el troceado se
///    trague una línea y la fuga pase en verde. Sobre el crudo, un `print(` escrito en un
///    comentario pone la prueba roja — ruido visible, que es el lado seguro.
///
/// Las listas blancas son el caso en el que esto no se puede elegir: su conjunto **tiene** que
/// venir del troceado, porque la prosa de los comentarios metería cientos de palabras y la lista
/// dejaría de medir. Ahí el precio está pagado desde el principio y declarado.
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
    /// # LA UNIDAD EN LA QUE SE RECORRE EL FUENTE: ESCALARES UNICODE, Y NO ES UN DETALLE
    ///
    /// Es la decisión técnica de la que dependía el hueco más grave que esta rama ha tenido, y
    /// estuvo **en las tres versiones** del troceado. Las dos primeras recorrían `Array(fuente)`,
    /// que son `Character`, y **un `Character` de Swift es un grafema extendido**: un conjunto de
    /// escalares que se presenta como un signo. De ahí salen dos cosas que parecen imposibles:
    ///
    ///  - `"\r\n"` es **UN** `Character`, y **no** es igual a `"\n"`. Así que el salto del
    ///    comentario de línea no paraba en una línea terminada en CRLF y **se comía la línea
    ///    siguiente**, y la resincronización tampoco se disparaba. Medido con la suite ENTERA en
    ///    **verde exacto** (1407/4/15 · 1426, 2026-11-10) con
    ///    `print("token \(valor)")` vivo en `TokenDeConducir.guardar` detrás de un comentario
    ///    terminado en CRLF: el token que conduce un Chrome con la sesión de Google del usuario
    ///    dentro yéndose al log unificado de macOS, y ni una queja. Control (el mismo `print` a la
    ///    vista): rojo. Alcanzable: no hay `.gitattributes`, `core.autocrlf` está sin poner, git
    ///    commitea el CRLF verbatim y el fichero compila.
    ///  - una **comilla seguida de una marca combinante** (`"` + U+0301) es también **UN**
    ///    `Character`, que **no** es igual a `"\""`. Con el recorrido por grafemas la comilla de
    ///    apertura era invisible, el troceador se creía en código, veía el `//` de dentro de la
    ///    cadena y **se tragaba el resto de la línea**. `let texto = "<U+0301>//x"; print(…)`
    ///    compila (`swiftc -parse` lo acepta: el lexador de Swift trabaja en escalares).
    ///
    /// Las dos son **la misma** avería: «este grafema contiene el delimitador pero no es igual a
    /// él». Tapar sólo el CRLF (reconocer `\r` y seguir en `Character`) habría dejado la segunda
    /// viva, así que la unidad del recorrido es ahora **el escalar Unicode, la del compilador**, y
    /// la clase entera se cierra de una vez. Medido: con los dos troceados pasados por los **156
    /// ficheros `.swift` de producción**, la salida es **idéntica en los 156** y los conjuntos de
    /// identificadores también (`difierenTexto=0 difierenIds=0`), así que ninguna lista blanca se
    /// relaja ni se endurece por este cambio.
    ///
    /// Y los fines de línea son **tres**: `\n`, `\r\n` y el `\r` solo, que es lo que el compilador
    /// reconoce (comprobado con `swiftc -parse`). U+2028 **no** lo es —comprobado también—, así
    /// que aquí tampoco: coincidir con el compilador es la propiedad, no «reconocer saltos».
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
    ///  3. **Cuatro comillas seguidas en código (`""""`).** ESTA DECLARACIÓN ESTABA MAL EN DOS
    ///     SENTIDOS y se corrige con lo medido, porque un hueco mal declarado es peor que uno sin
    ///     declarar. Lo que pasa de verdad: las **tres primeras** comillas **ABREN** un multilínea
    ///     (`corrida(i,"\"") >= 3`) y la cuarta se queda dentro como contenido. La
    ///     resincronización **no toca los marcos multilínea por construcción**
    ///     (`case .cadena(_, let multilinea): return !multilinea`), así que el marco **cruza
    ///     líneas** y el quitado de comentarios se apaga **en todo el resto del fichero**, no
    ///     «hasta el final de la línea». Comprobado: con `let a = """"` en la primera línea, un
    ///     `// SECRETO_EN_COMENTARIO` dos líneas más abajo **sobrevive** al troceado.
    ///     Y «no esconde» es correcto pero irrelevante: deja ciegas las aserciones de
    ///     **presencia**, que es el otro lado del silencio. Lo que de verdad hace inofensivo este
    ///     hueco **no es la resincronización**: es que `""""` **no compila** (`error: multi-line
    ///     string literal content must begin on a new line`), igual que el hueco nº2.
    ///  4. **Compilación condicional.** `#if os(iOS)` no se interpreta: el texto de **todas** las
    ///     ramas sale del troceado tal cual. ⚠️ **ESTA DECLARACIÓN DECÍA «NO ES UN HUECO DE
    ///     SILENCIO —SE VE MÁS, NO MENOS—», Y ERA FALSA** (H1 de la revisión de rama, medido con la
    ///     suite entera). Es verdad para una **lista blanca** y para una **ausencia**, que ven de
    ///     más. Es **falso para toda PRESENCIA**: una presencia pregunta «¿está este texto?», y
    ///     el texto sigue ahí aunque la rama no compile en la plataforma que el usuario ejecuta.
    ///     Disparador exacto: envolver `ClaveDeProveedor.migrarTodas()` de `GemmaApp` o
    ///     `Self.registerBrowserTools(…)` de `HarnessModel` en `#if os(iOS) … #endif` retiraba del
    ///     binario de macOS la migración de las claves de pago o el registro entero del
    ///     navegador, **con la suite en su verde exacto** (m6, m7). **Este troceado no lo puede
    ///     cerrar**, porque saber qué rama compila no es léxico: depende de la plataforma, de
    ///     `canImport`, de las banderas del compilador. Lo que sí se puede hacer, y es lo que hace
    ///     `codigoIncondicional`, es no intentar saberlo: quitar **todas** las ramas, de modo que
    ///     una presencia solo se cumpla con código que compila **en todas las plataformas**.
    ///     Las pantallas que afirman presencias de **arranque** (las migraciones de `GemmaApp`, el
    ///     registro del navegador) usan ésa; las listas blancas siguen con `sinComentarios`,
    ///     porque ahí ver de más es lo correcto.
    ///  5. **Lo que Swift añada mañana a su gramática léxica.** Es el hueco de fondo y no se cierra
    ///     con otra ronda: ver «QUÉ NO DEFIENDE».
    ///  6. **Esto distingue código de comentario; no reconstruye expresiones.** No es un hueco del
    ///     troceado, pero es un límite suyo que una pantalla ya paga, y se escribe aquí para que
    ///     nadie lo confunda con algo que el troceado arregle: una red que mida **línea a línea**
    ///     se esquiva partiendo la fuga en dos líneas. Disparador exacto, medido en
    ///     `BrowserRelayClientTests` (oculta verde, control roja):
    ///     `PanelLog.note("lo que el usuario teclea: "` en una línea y `+ entrada)` en la
    ///     siguiente. Está declarado también en esa prueba, y cerrarlo pide juntar las
    ///     continuaciones de una llamada, que es otra vez un analizador de Swift a mano.
    ///
    /// La resincronización acota un error de lexado a **una línea** solo cuando el marco mal
    /// abierto es de una línea (cadena normal o regex extendido en una línea). Un error dentro de
    /// un literal multilínea, de un regex extendido multilínea o de un comentario de bloque **no
    /// está acotado**: se arrastra hasta que su cierre aparezca.
    static func sinComentarios(_ fuente: String) -> String {
        // LA UNIDAD: **escalares Unicode**, que es la unidad en la que lexa el compilador, y no
        // `Character`. Ver «LA UNIDAD EN LA QUE SE RECORRE EL FUENTE» en el doc-comment: con
        // `Character` (grafema extendido) `"\r\n"` es UN solo carácter y **no** es igual a
        // `"\n"`, y una comilla seguida de una marca combinante es UN solo carácter que **no** es
        // igual a `"\""`. Las dos cosas estaban medidas con la suite entera en verde exacto.
        let c = Array(fuente.unicodeScalars)
        var salida = String.UnicodeScalarView()
        salida.reserveCapacity(c.count)
        var i = 0
        var pila: [Marco] = []

        /// Cuántos `cual` seguidos hay a partir de `desde`. Los `#` de las cadenas crudas y las
        /// comillas de los multilínea se cuentan, no se suponen.
        func corrida(_ desde: Int, _ cual: Unicode.Scalar) -> Int {
            var n = 0
            var j = desde
            while j < c.count, c[j] == cual { n += 1; j += 1 }
            return n
        }

        /// Los terminadores de línea **del compilador de Swift**, que son tres y no uno: `\n`,
        /// `\r\n` y el `\r` solo (comprobado con `swiftc -parse`: con cualquiera de los tres, un
        /// token basura detrás del terminador da error en la línea de DESPUÉS). Recorriendo por
        /// escalares, un `\r\n` son dos elementos y los dos contestan `true`, así que el salto
        /// del comentario de línea para en el `\r`, la resincronización se dispara ahí, y el
        /// `\r` y el `\n` salen los dos a la salida: el texto troceado conserva las mismas
        /// líneas y el mismo terminador que la entrada.
        ///
        /// U+2028 (LINE SEPARATOR) **no** está aquí a propósito: medido, Swift **no** lo trata
        /// como fin de línea, así que tratarlo como tal sería desalinearse del compilador en la
        /// dirección peligrosa (cerrar un comentario que el compilador deja abierto).
        func esFinDeLinea(_ s: Unicode.Scalar) -> Bool { s == "\n" || s == "\r" }

        while i < c.count {
            let ch = c[i]

            // LA RESINCRONIZACIÓN. Si al llegar al salto de línea hay abierto un marco que no
            // puede cruzar líneas, el lexado está roto: se cierra ése y todo lo que se apoyaba en
            // él, para que el estropicio no pase de esta línea. Ver el doc-comment.
            if esFinDeLinea(ch) {
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
                    if vistos == numerales, j < c.count, !esFinDeLinea(c[j]) {
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
                if ch == "\\", i + 1 < c.count, !esFinDeLinea(c[i + 1]) {
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
                    while i < c.count, !esFinDeLinea(c[i]) { i += 1 }
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
                            if esFinDeLinea(c[i]) { salida.append(c[i]) }
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
                        let multilinea = i + largo < c.count && esFinDeLinea(c[i + largo])
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
        return String(salida)
    }

    /// El código que compila **en todas las plataformas**: el fuente sin comentarios
    /// (`sinComentarios`) y **sin ningún bloque de compilación condicional** — de cada `#if` a su
    /// `#endif`, con todas sus ramas (`#elseif`, `#else`) y los anidados, se quita todo.
    ///
    /// # POR QUÉ, Y PARA QUÉ ASERCIONES (H1 de la revisión de rama)
    ///
    /// Una aserción de **PRESENCIA** sobre `sinComentarios` se cumple con el código dentro de un
    /// `#if os(iOS)`, que en macOS **no existe en el binario**. Medido con la suite entera: con
    /// `ClaveDeProveedor.migrarTodas()` o `Self.registerBrowserTools(…)` envueltos así, la suite
    /// se quedaba en su verde exacto con la migración de las claves de pago o el registro del
    /// navegador fuera del binario de macOS. Saber **qué** rama compila no es léxico —depende de
    /// la plataforma, de `canImport`, de banderas— y este troceado no lo va a saber; así que no
    /// lo intenta: **ninguna** rama cuenta. Una presencia sobre este texto solo se cumple con
    /// código incondicional.
    ///
    /// Es el lado que hay que elegir para las presencias de **arranque**, y no por comodidad:
    /// una migración envuelta en `#if os(macOS)` compila en la plataforma de la prueba y **falta
    /// en el teléfono**, que es el cliente real del usuario. Si algún día una presencia tiene que
    /// estar legítimamente en una rama, esta función la pone roja: **ruido visible**, y entonces
    /// esa presencia se mide con `sinComentarios` y con su motivo escrito al lado.
    ///
    /// NO ES PARA LAS LISTAS BLANCAS NI PARA LAS AUSENCIAS, que tienen que ver **de más**: un
    /// nombre de una rama que no compila aquí sigue siendo código del proyecto.
    ///
    /// LO QUE NO DEFIENDE, con su disparador: una línea de una cadena **multilínea** que empiece
    /// por `#if` se toma por directiva (el troceado conserva el contenido de las cadenas). Sin su
    /// `#endif` se lleva el resto del fichero: la presencia se pone **roja**, que es el lado
    /// visible. Y una directiva que no empiece la línea no se reconoce; Swift exige que la
    /// empiece.
    static func codigoIncondicional(_ fuente: String) -> String {
        var salida: [Substring] = []
        var profundidad = 0
        // Los tres fines de línea del compilador, comparados como `Character`: `"\r\n"` es UN
        // `Character` y no es igual a `"\n"` (ver «LA UNIDAD EN LA QUE SE RECORRE EL FUENTE»),
        // así que partir por `"\n"` a secas no partiría un fichero con CRLF y una directiva
        // detrás de un CRLF no se vería.
        let lineas = sinComentarios(fuente).split(omittingEmptySubsequences: false,
                                                  whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        for linea in lineas {
            let directiva = Self.directiva(de: linea)
            switch directiva {
            case "#if":
                profundidad += 1
                salida.append("")
            case "#endif":
                profundidad = max(0, profundidad - 1)
                salida.append("")
            case "#elseif", "#else":
                salida.append("")
            default:
                salida.append(profundidad == 0 ? linea : "")
            }
        }
        return salida.joined(separator: "\n")
    }

    /// La directiva de compilación condicional con la que empieza la línea, o `nil`. Las cuatro
    /// palabras se reconocen enteras: `#ifdef` no es Swift, y `#iffy` no es `#if`.
    private static func directiva(de linea: Substring) -> String? {
        let recortada = linea.drop(while: { $0 == " " || $0 == "\t" })
        for palabra in ["#elseif", "#endif", "#else", "#if"] where recortada.hasPrefix(palabra) {
            let resto = recortada.dropFirst(palabra.count)
            guard let siguiente = resto.unicodeScalars.first else { return palabra }
            if siguiente == " " || siguiente == "\t" || siguiente == "(" || siguiente == "!"
                || siguiente == "\r" { return palabra }
            return nil
        }
        return nil
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
