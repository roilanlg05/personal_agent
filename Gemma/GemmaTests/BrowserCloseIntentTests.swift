import XCTest
@testable import Gemma

/// El candado que impide que el modelo destruya la página que el usuario está mirando.
/// Ver `BrowserCloseIntent` para por qué se leen aquí las palabras del usuario cuando en la
/// puerta de compra se decidió que nunca se harían coincidir palabras clave: el valor por
/// defecto aquí es NO CERRAR, así que el texto solo puede levantar un candado, nunca autorizar
/// algo que cueste.
final class BrowserCloseIntentTests: XCTestCase {

    // MARK: lo que NO debe cerrar

    /// El defecto en sus palabras exactas (2026-11-08): «ábreme la Wikipedia con la página de
    /// anatomía para leerla». Pidió una página PARA LEER y el modelo la cerró.
    func test_pedir_una_pagina_para_leerla_no_es_pedir_que_se_cierre() {
        XCTAssertFalse(BrowserCloseIntent.userAskedToClose(
            "ábreme la Wikipedia con la página de anatomía para leerla"))
    }

    func test_pedir_un_video_no_es_pedir_que_se_cierre() {
        XCTAssertFalse(BrowserCloseIntent.userAskedToClose(
            "reprodúceme un video de AuronPlay en YouTube"))
    }

    /// LA NEGACIÓN GANA. La primera frase es la del usuario, palabra por palabra: la dijo y el
    /// agente cerró igual.
    ///
    /// Las dos siguientes están aquí por una mutación. Al neutralizar la regla de negación, la
    /// frase del usuario SEGUÍA EN VERDE: «no cierres» no contiene ninguna de las formas
    /// afirmativas de la lista («cierres» no es «cierra el navegador»), así que pasaba por
    /// ausencia, no por el candado. Era la misma prueba decorativa que esta rama ya ha producido
    /// cinco veces. Las dos frases nuevas SÍ contienen una forma afirmativa dentro de una
    /// prohibición, que es el único caso en que la regla de negación decide algo.
    func test_prohibir_el_cierre_no_lo_autoriza_aunque_nombre_el_verbo() {
        XCTAssertFalse(BrowserCloseIntent.userAskedToClose(
            "no cierres el navegador hasta que no termine el video o yo te aviso"))
        XCTAssertFalse(BrowserCloseIntent.userAskedToClose(
            "no cierres el navegador: déjalo abierto"))
        XCTAssertFalse(BrowserCloseIntent.userAskedToClose(
            "don't close the browser until the video ends"))
    }

    func test_otras_formas_de_prohibirlo() {
        for frase in ["no lo cierres", "déjalo abierto", "deja el navegador abierto",
                      "mantenlo abierto", "don't close the browser", "keep it open",
                      "leave the browser open", "no me lo cierres todavía"] {
            XCTAssertFalse(BrowserCloseIntent.userAskedToClose(frase), "no debía autorizar: \(frase)")
        }
    }

    /// Una frase que prohíbe y pide a la vez se lee del lado seguro: la página se queda.
    func test_ante_una_frase_que_dice_las_dos_cosas_la_pagina_se_queda() {
        XCTAssertFalse(BrowserCloseIntent.userAskedToClose(
            "cierra el navegador cuando acabe, pero no lo cierres ahora"))
    }

    func test_un_mensaje_vacio_o_cualquier_otra_cosa_no_cierra() {
        for frase in ["", "   ", "hola", "qué hora es", "¿cuánto cuesta el envío?",
                      "la tienda está cerrada", "the shop is closed",
                      "pon el video de AuronPlay", "abre la wikipedia"] {
            XCTAssertFalse(BrowserCloseIntent.userAskedToClose(frase), "no debía autorizar: \(frase)")
        }
    }

    /// El precio que se paga a sabiendas por la regla de verbo, escrito como prueba para que
    /// nadie lo «arregle» sin leer el razonamiento. «Cierra el trato» cerrará el navegador.
    ///
    /// Se acepta porque de los dos errores posibles solo este se arregla solo: el usuario reabre
    /// la página. El error contrario —rechazar un cierre que el usuario sí pidió— deja al agente
    /// diciéndole que no pidió lo que acaba de pedir, y eso no se arregla, se sufre. Pasó en la
    /// primera prueba real del candado, con una lista de frases hechas que no contenía su manera
    /// de decirlo.
    ///
    /// Si algún día cerrar llega a costar algo real (perder una sesión autenticada, que es lo que
    /// traerá el perfil persistente), este intercambio deja de valer y hay que volver a un acto
    /// explícito en la interfaz, no a una lista de frases más larga.
    func test_el_precio_asumido_de_la_regla_de_verbo() {
        XCTAssertTrue(BrowserCloseIntent.userAskedToClose("cierra el trato con ese proveedor"),
                      "el verbo cerrar autoriza, aunque hable de otra cosa: es el precio asumido")
    }

    /// Las maneras sueltas de pedirlo que una lista de frases hechas no cubría. Esta es la
    /// regresión del 2026-11-08: el candado rechazó varias veces un cierre que el usuario pidió.
    func test_maneras_sueltas_de_pedirlo_que_la_lista_de_frases_no_cubria() {
        for frase in ["bueno ya cierra", "cierra eso", "puedes cerrarlo ya",
                      "venga, a cerrar", "ciérramelo", "cerrá el navegador",
                      "apaga el navegador", "quita esa pestaña", "close it",
                      "ya está, cierra"] {
            XCTAssertTrue(BrowserCloseIntent.userAskedToClose(frase), "debía autorizar: \(frase)")
        }
    }

    // MARK: lo que SÍ debe cerrar

    func test_pedirlo_explicitamente_lo_autoriza() {
        for frase in ["cierra el navegador", "ciérralo", "ciérrala ya",
                      "cierra la página", "cierra la pestaña", "ya puedes cerrar el navegador",
                      "close the browser", "you can close it now", "close the tab"] {
            XCTAssertTrue(BrowserCloseIntent.userAskedToClose(frase), "debía autorizar: \(frase)")
        }
    }

    /// Los acentos no deciden si se destruye lo que el usuario está mirando: «ciérralo» y
    /// «cierralo» son la misma orden, y las mayúsculas tampoco cambian nada.
    func test_los_acentos_y_las_mayusculas_no_cambian_la_lectura() {
        XCTAssertTrue(BrowserCloseIntent.userAskedToClose("cierralo"))
        XCTAssertTrue(BrowserCloseIntent.userAskedToClose("CIÉRRALO"))
        XCTAssertTrue(BrowserCloseIntent.userAskedToClose("Cierra El Navegador"))
        XCTAssertFalse(BrowserCloseIntent.userAskedToClose("NO CIERRES EL NAVEGADOR"))
    }

    func test_la_peticion_dentro_de_una_frase_mas_larga_cuenta() {
        XCTAssertTrue(BrowserCloseIntent.userAskedToClose(
            "gracias, ya leí lo que necesitaba, cierra el navegador y apunta esto en una nota"))
    }
}
