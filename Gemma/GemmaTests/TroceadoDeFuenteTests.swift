import XCTest
@testable import Gemma

/// **EL INSTRUMENTO DE MEDIDA, MEDIDO.** `TroceadoDeFuente` es el punto único del que dependen
/// **cinco** redes de seguridad de este proyecto —la contraseña del usuario, la coordenada de su
/// dedo, el token del navegador, las API keys de pago y el token del servicio de memoria— y hasta
/// esta ronda **no tenía ni una prueba propia**.
///
/// POR QUÉ ESO ERA EL AGUJERO DE FONDO, MEDIDO. Con el árbol por lo demás limpio, revertir
/// `sinComentarios` al corte ciego (`linea.range(of: "//")`) **no ponía roja ninguna prueba de la
/// suite**: el verde era exacto. Es decir, alguien que «simplificara» ese fichero mañana no se
/// enteraría y las cinco redes volverían a estar ciegas a la vez. Y al revés: cuatro aserciones
/// puras sobre una función pura habrían cazado en segundos el bypass que costó tres rondas de
/// mutaciones con `xcodebuild`.
///
/// EL CRITERIO DE QUE ESTAS PRUEBAS SON SUFICIENTES, Y ES MEDIBLE. Compilé cuatro variantes del
/// troceado aparte y pasé los veinte casos de abajo por las cinco. Ninguno de los veinte pasa con
/// todas, así que ninguno es vacuo:
///
///     variante                                            casos en verde
///     el troceado de este fichero                              20 / 20
///     el corte ciego (`range(of: "//")`)                         7 / 20
///     el de la ronda 3 (un `Bool` `enCadena` y un `escapando`)  10 / 20
///     bloques quitados en una pasada previa, sin anidar          16 / 20
///     el troceado BORRADO (devuelve el fuente tal cual)           8 / 20
///
/// Los dos casos que solo mata la variante ingenua son los que impiden que el arreglo de los
/// bloques se pase de largo: el bloque **anidado** y el `/*` **dentro de una cadena**. Los dos que
/// solo mata la variante borrada son los controles de que el troceado siga haciendo su trabajo.
///
/// Y LO QUE ESTAS PRUEBAS **NO** CUBREN está escrito en el doc-comment de `TroceadoDeFuente`, con
/// su disparador exacto cada uno, y no se lo atribuyo a ninguna de las de aquí.
final class TroceadoDeFuenteTests: XCTestCase {

    /// Una aserción pura: entrada, salida exacta, y el motivo por el que esa salida importa.
    private func trocea(_ entrada: String, _ esperado: String, _ porque: String) {
        XCTAssertEqual(TroceadoDeFuente.sinComentarios(entrada), esperado, porque)
    }

    // MARK: el control, primero: que el troceado siga haciendo su trabajo

    /// Si esto se pone rojo, el troceado no quita comentarios y **todas** las aserciones de
    /// presencia de este proyecto se cumplen con la característica escrita en prosa.
    func test_un_comentario_de_linea_de_verdad_se_quita() {
        trocea("let a = 1 // fuga del token\nlet b = 2",
               "let a = 1 \nlet b = 2",
               "el troceado ha dejado de quitar los comentarios de línea")
        trocea("if #available(macOS 14, *) { } // fuga",
               "if #available(macOS 14, *) { } ",
               "`#available` no es una cadena cruda: `#` a secas no abre nada")
        trocea(#"let a = ""; let b = 2 // fuga"#,
               #"let a = ""; let b = 2 "#,
               "la cadena vacía no puede quedarse abierta")
    }

    // MARK: las barras dentro de una cadena (G1: el bypass que costó cuatro rondas)

    /// `let ayuda = "https://…"` con cualquier cosa detrás en la misma línea. El corte ciego se
    /// tragaba el resto de la línea y la fuga pasaba en verde en las cinco redes.
    func test_las_barras_dentro_de_una_cadena_no_cortan() {
        trocea(#"let texto = "dev//dev"; print("token \(valor)")"#,
               #"let texto = "dev//dev"; print("token \(valor)")"#,
               "se cortó dentro de una cadena: la línea entera se vuelve invisible")
        trocea(#"let a = "x\"//y"; print("z")"#,
               #"let a = "x\"//y"; print("z")"#,
               "la comilla escapada no abre ni cierra nada")
        trocea(##"let a = #"http://x"#; print("y")"##,
               ##"let a = #"http://x"#; print("y")"##,
               "en una cadena cruda las comillas son comillas y las barras son barras")
    }

    /// **LA INTERPOLACIÓN ANIDADA.** Con un `Bool` en vez de una pila, el `\` ponía el troceador en
    /// modo escape, se comía el `(`, y la comilla de la cadena **de dentro** apagaba el estado «en
    /// cadena»: a partir de ahí creía estar en código y cortaba. Medido con la suite entera: verde
    /// exacto con el token del navegador filtrándose al log de macOS.
    func test_la_interpolacion_anidada_no_desincroniza() {
        trocea(#"let texto = "dev \("//") x"; print("token \(valor)")"#,
               #"let texto = "dev \("//") x"; print("token \(valor)")"#,
               "la cadena de dentro de la interpolación desincronizó el estado")
        trocea(#"let a = "\(f(g("//")))"; print("z")"#,
               #"let a = "\(f(g("//")))"; print("z")"#,
               "la interpolación necesita un CONTADOR de paréntesis, no un booleano")
        trocea(##"let a = #"x \#("//") y"#; print("z")"##,
               ##"let a = #"x \#("//") y"#; print("z")"##,
               "en una cadena cruda la interpolación lleva los `#` de la cadena")
        trocea(#"let a = "\(UserDefaults.standard.set(x, forKey: k))" // fuga"#,
               #"let a = "\(UserDefaults.standard.set(x, forKey: k))" "#,
               "el interior de las cadenas se CONSERVA: una interpolación puede tener efectos")
    }

    /// **LA CADENA CRUDA CON CONTRABARRA**, que es para lo que uno usa una cadena cruda. Ahí la
    /// contrabarra no escapa nada; tratarla como escape se comía la comilla de cierre y dejaba la
    /// paridad invertida, cortando en un `//` de una cadena **posterior**. Medido con la suite
    /// entera: verde exacto.
    func test_una_cadena_cruda_con_contrabarra_no_desincroniza() {
        trocea(##"let dev = #"\"#; let texto = "dev//x"; print("token \(valor)")"##,
               ##"let dev = #"\"#; let texto = "dev//x"; print("token \(valor)")"##,
               "la contrabarra de una cadena cruda se trató como escape")
    }

    // MARK: los comentarios de BLOQUE (H4: la característica borrada y el texto conservado)

    /// El troceado de las dos versiones anteriores solo conocía `//`. Con el `.overlay` del anillo
    /// del puntero envuelto en `/* */` —**la característica borrada**, el texto conservado— la
    /// suite entera se quedaba en su verde exacto y pasaban las trece comprobaciones de la prueba
    /// del anillo, incluido su guardián de esquema cerrado, porque cuenta **texto**. Y comentar un
    /// bloque mientras se depura y commitearlo es de las regresiones más comunes que existen.
    ///
    /// Los bloques de Swift **anidan**: `/* /* */ */` es uno solo, así que esto exige un contador
    /// de profundidad y no «busca el primer `*/`». Esa diferencia es la que mata la variante
    /// ingenua.
    func test_los_comentarios_de_bloque_se_quitan_y_anidan() {
        trocea("let a = 1 /* fuga */ ; let b = 2",
               "let a = 1  ; let b = 2",
               "los comentarios de bloque no se quitan: el texto sobrevive a la medición")
        trocea("let a = 1 /* x /* y */ z */ ; let b = 2",
               "let a = 1  ; let b = 2",
               "los bloques de Swift ANIDAN: con «el primer `*/`» queda ` z */` suelto")
        trocea("let a = 1\n/* uno\ndos */\nlet b = 2",
               "let a = 1\n\n\nlet b = 2",
               "un bloque multilínea tiene que conservar sus saltos de línea: las aserciones de "
               + "bloque contiguo de la prueba del anillo miden sobre las mismas líneas")
    }

    /// Y el arreglo no se pasa de largo: un `/*` **dentro de una cadena** no abre un comentario.
    /// Sin esto, un quitado de bloques escrito a la ligera se traga el código que haya entre una
    /// cadena con `/*` y otra con `*/` — que es el mismo fallo de G1 con otra forma.
    func test_un_bloque_dentro_de_una_cadena_no_abre_comentario() {
        trocea(#"let a = "/*"; print("token \(valor)"); let b = "*/"; let c = 3 // fuera"#,
               #"let a = "/*"; print("token \(valor)"); let b = "*/"; let c = 3 "#,
               "un `/*` dentro de una cadena abrió comentario y se tragó el `print`")
    }

    // MARK: los literales multilínea, y el hueco que la versión anterior tenía mal declarado

    /// La versión anterior contaba los `"""` por línea con un `Bool`, así que **cualquier** línea
    /// con un número impar de `"""` —incluida una que los llevara dentro de un comentario `//`—
    /// apagaba el quitado de comentarios **en todo el resto del fichero**. El hueco que declaraba
    /// («vivir dentro de un literal multilínea») era más pequeño que el real.
    func test_los_multilinea_y_los_triples_dentro_de_un_comentario() {
        trocea("let a = 1 // \"\"\"\nlet b = 2 // fuga\nlet c = 3",
               "let a = 1 \nlet b = 2 \nlet c = 3",
               "unos `\"\"\"` dentro de un comentario apagaron el troceado del resto del fichero")
        trocea("let a = \"\"\"\nhttps://ejemplo\n\"\"\"\nlet b = 2 // fuga",
               "let a = \"\"\"\nhttps://ejemplo\n\"\"\"\nlet b = 2 ",
               "un literal multilínea de verdad conserva su contenido, y el comentario de después "
               + "se sigue quitando")
    }

    // MARK: el regex extendido, que era un camino de verdad

    /// En un literal de regex **extendido** (`#/…/#`) un `/` suelto es legal, así que un `//`
    /// dentro no es un comentario. Antes de modelarlo, `#/https://x/#` cortaba la línea ahí y
    /// escondía todo lo que fuera detrás: medido, y es el hueco que abrí yo mismo buscando los
    /// que quedaban. (El regex corriente, `/…/`, sigue sin modelarse; el doc-comment dice por qué
    /// no he encontrado forma de usarlo para esconder.)
    func test_el_regex_extendido_no_es_un_comentario() {
        trocea(##"let r = #/https://x/#; print("token \(valor)")"##,
               ##"let r = #/https://x/#; print("token \(valor)")"##,
               "el `//` de un regex extendido se tomó por comentario")
        trocea(##"let r = #/https://x/#; let b = 2 // fuga"##,
               ##"let r = #/https://x/#; let b = 2 "##,
               "y el comentario de esa misma línea sí se quita: el regex no se queda abierto")
    }

    // MARK: la resincronización, que es lo que acota el daño de un lexado roto

    /// No hay dirección segura cuando el troceado se equivoca —cortar de más deja ciegas las
    /// reglas de ausencia, cortar de menos deja ciegas las de presencia— así que lo que se puede
    /// garantizar es **el alcance**: una cadena de una línea sin cerrar es un troceado roto, y el
    /// estropicio se queda en esa línea en vez de apagar el resto del fichero.
    func test_el_dano_de_una_cadena_sin_cerrar_no_pasa_de_su_linea() {
        trocea("let a = \"abierta\nlet b = 2 // fuga\nlet c = 3",
               "let a = \"abierta\nlet b = 2 \nlet c = 3",
               "una cadena sin cerrar apagó el troceado de las líneas siguientes")
    }

    // MARK: y el conjunto de identificadores, que es lo que las cinco redes comparan

    /// La prosa de los comentarios **no** entra en el conjunto (si entrara, las listas blancas
    /// serían inútiles: cientos de palabras permitidas) y el contenido de las cadenas **sí**
    /// entra, a propósito, porque una interpolación puede llevar código con efectos.
    func test_los_identificadores_no_traen_la_prosa_de_los_comentarios() {
        let ids = TroceadoDeFuente.identificadores(de:
            "let a = 1 // palabraDeProsa\n/* otraPalabraDeProsa */\nlet b = \"dentroDeLaCadena\"")
        XCTAssertFalse(ids.contains("palabraDeProsa"),
                       "la prosa de un comentario de línea entra en el conjunto")
        XCTAssertFalse(ids.contains("otraPalabraDeProsa"),
                       "la prosa de un comentario de bloque entra en el conjunto")
        XCTAssertTrue(ids.contains("dentroDeLaCadena"),
                      "el contenido de las cadenas tiene que entrar: una interpolación puede "
                      + "llevar una llamada con efectos")
        XCTAssertTrue(ids.contains("let"), "guarda de vacuidad: el conjunto no está vacío")
    }

    /// Y los identificadores con `ñ` no se parten: `tamañoDeLaVista` es un nombre de este
    /// proyecto, y partirlo daría trozos que no están en ninguna lista blanca.
    func test_los_identificadores_con_letras_unicode_no_se_parten() {
        let ids = TroceadoDeFuente.identificadores(de: "let tamañoDeLaVista = 1")
        XCTAssertTrue(ids.contains("tamañoDeLaVista"),
                      "el troceador partió un identificador con `ñ`")
    }
}
