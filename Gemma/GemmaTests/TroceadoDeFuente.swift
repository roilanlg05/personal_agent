import Foundation

/// **EL TROCEADO DEL FUENTE PARA LAS PRUEBAS QUE LEEN EL FUENTE.** Una sola implementación, y
/// ésa es la característica, no una comodidad.
///
/// POR QUÉ VIVE AQUÍ Y NO EN CADA PANTALLA. Cuatro listas blancas de este proyecto —la del mando
/// (`BrowserPanelViewTests`), la del mapa del toque (`BrowserInputMapperTests`), la del llavero y
/// el token (`TokenDeConducirTests`) y la de las claves de pago (`ClaveDeProveedorTests`, que
/// reusa el troceado de la anterior)— sostienen la misma propiedad: que por esos ficheros no
/// pase nada que registre, persista, notifique o acumule un secreto del usuario. Tenían **tres
/// copias** del mismo troceado, carácter por carácter, y eso es exactamente cómo se arregla un
/// agujero y siguen vivos los otros dos: el 2026-11-09 se midió que el corte ciego de las tres
/// dejaba pasar una fuga, se arregló **una** y las otras dos siguieron abiertas hasta esta ronda.
///
/// LO QUE SE MIDIÓ, porque es el motivo de que esto no sea un refactor cosmético. Con el corte
/// ciego, estas dos mutaciones dejaban la suite **entera** en su verde exacto:
///
///     // en `BrowserInputMapper.paginaDesde`, que ve DÓNDE toca el usuario
///     let width = "x//y"; print("toque en \(punto)")                      → VERDE
///     // en `TokenDeConducir.guardar`, que ve el TOKEN del navegador
///     let texto = "dev//dev"; print("token \(valor)")                      → VERDE
///
/// y sus dos controles —las mismas líneas **sin** la cadena delante— salían rojos. Es decir: la
/// red existía, funcionaba, y bastaba una cadena con `//` por delante para cegarla.
enum TroceadoDeFuente {

    /// El fuente sin sus comentarios de línea, que es el paso previo de **toda** medición sobre
    /// el fuente de este proyecto: una aserción contra el fuente crudo se cumple con la
    /// característica escrita en un comentario, y eso ya se midió en esta rama.
    ///
    /// **POR QUÉ NO VALE CORTAR EN EL PRIMER `//` DE LA LÍNEA, MEDIDO.** Es lo que hacía la
    /// versión anterior, y un revisor fresco midió el agujero con la suite entera:
    ///
    ///     if "//".isEmpty { } else { ultimoPunteroDeLaVista = valor.location }   → VERDE
    ///     if "x//y".isEmpty { } else { print("toque en \(valor.location)") }     → VERDE
    ///     print("toque en \(valor.location)")               (control, a la vista) → ROJO
    ///
    /// El corte ciego se tragaba **todo lo que fuera detrás de una cadena que contuviera `//`**,
    /// así que la línea entera se volvía invisible para **todas** las aserciones de texto de las
    /// cuatro pantallas de arriba — y, lo grave, para las listas blancas que existen para que no
    /// se registren la contraseña del usuario, la coordenada de su dedo, el token del navegador
    /// y sus claves de pago. No hace falta mala fe para tropezar con eso: un
    /// `let ayuda = "https://…"` con cualquier cosa detrás en la misma línea ya lo dispara.
    ///
    /// Y EL ARGUMENTO QUE LAS TRES COPIAS TENÍAN ESCRITO ERA DEL TIPO EQUIVOCADO. Decían, cada
    /// una a su manera, que el corte «es seguro en ESTE fichero porque ninguna de sus cadenas
    /// contiene `//`»: eso es una afirmación sobre **el contenido de hoy**, no una propiedad, y
    /// una línea nueva la tumba. Dos de ellas añadían además que «si alguna llegara a
    /// contenerlo, el guarda de vacuidad lo caza», y eso es **falso**: ese guarda (el ancla de
    /// ruta y el recuento mínimo) detecta que el troceado **entero** se rompa, no que se le
    /// esconda **una** línea.
    ///
    /// Lo que hay ahora es un corte que distingue los dos estados, código y cadena, y que en la
    /// duda **no corta**: dejar un comentario dentro solo produce ruido visible (una roja que
    /// alguien mira), mientras que tragarse una línea de código produce **silencio**, que es el
    /// único fallo que estas pantallas no se pueden permitir.
    ///
    /// **POR QUÉ NO SE BLANQUEA EL INTERIOR DE LAS CADENAS, que era la otra vía.** Porque abre un
    /// agujero peor: una interpolación puede llevar una llamada **con efectos**
    /// (`"\(UserDefaults.standard.set(x, forKey: k))"`), así que esconder el interior de las
    /// cadenas esconde código ejecutable de la lista blanca. Se conserva el contenido, y como
    /// efecto secundario las palabras de las cadenas siguen entrando en el conjunto — que es
    /// justo lo que las cuatro listas blancas ya tenían asumido y justificado.
    ///
    /// **EL HUECO QUE QUEDA, DECLARADO Y NO ATRIBUIDO A NINGUNA PRUEBA:** una línea que viva
    /// dentro de un literal multilínea (`"""`) se devuelve entera, comentarios incluidos, así que
    /// su prosa entra en el conjunto de identificadores. Hoy ninguno de los ficheros medidos
    /// tiene literales multilínea; el día que los tenga, la lista blanca se pondrá roja con las
    /// palabras de esa prosa, que es el lado ruidoso y no el silencioso.
    static func sinComentarios(_ fuente: String) -> String {
        var enMultilinea = false
        return fuente.split(separator: "\n", omittingEmptySubsequences: false)
            .map { linea -> String in
                let texto = String(linea)
                let triples = texto.components(separatedBy: "\"\"\"").count - 1
                guard !enMultilinea, triples == 0 else {
                    if triples % 2 == 1 { enMultilinea.toggle() }
                    return texto
                }
                return sinComentarioDeLinea(texto)
            }
            .joined(separator: "\n")
    }

    /// Corta `linea` en su primer `//` **que esté fuera de una cadena literal**, y la devuelve
    /// entera si no hay ninguno.
    ///
    /// Las comillas se cuentan respetando el escape (`\"` no abre ni cierra nada), así que las
    /// cadenas crudas (`#"…"#`) quedan protegidas igual: sus comillas son comillas de verdad.
    private static func sinComentarioDeLinea(_ linea: String) -> String {
        var resultado = ""
        var enCadena = false
        var escapando = false
        var anterior: Character?
        for caracter in linea {
            if escapando {
                escapando = false
            } else if caracter == "\\", enCadena {
                escapando = true
            } else if caracter == "\"" {
                enCadena.toggle()
            } else if caracter == "/", anterior == "/", !enCadena {
                resultado.removeLast()      // la primera barra ya estaba puesta
                return resultado
            }
            resultado.append(caracter)
            anterior = caracter
        }
        return resultado
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
