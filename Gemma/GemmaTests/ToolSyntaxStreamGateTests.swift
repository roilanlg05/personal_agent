import XCTest
@testable import Gemma

/// Regresión del chat de YouTube del 2026-11-08: un mensaje que empezaba con prosa en español
/// y seguía con la llamada a una herramienta escrita como texto
/// (`<function name="browser_click"><parameter name="selector">@e816…`) llegó entero a la
/// pantalla, porque «¿esto es una llamada?» se decidía una sola vez, con los primeros
/// caracteres, y después todo se emitía sin mirar. Los tokens salen en vivo: limpiar solo el
/// texto final no podía arreglarlo, hay que retener la cola dudosa hasta que se resuelva.
final class ToolSyntaxStreamGateTests: XCTestCase {
    /// Alimenta la compuerta y devuelve lo que vio el usuario, token a token.
    private func shown(_ pieces: [String], checksStart: Bool = true) -> [String] {
        var g = ToolSyntaxStreamGate(checksStart: checksStart)
        var out = pieces.map { g.feed($0) }
        out.append(g.finish())
        return out.filter { !$0.isEmpty }
    }

    private func joined(_ pieces: [String], checksStart: Bool = true) -> String {
        shown(pieces, checksStart: checksStart).joined()
    }

    func test_la_prosa_sigue_saliendo_token_a_token_sin_retenerse_hasta_el_final() {
        XCTAssertEqual(shown(["Hola", " mundo", ", ¿qué", " tal?"]), ["Hola", " mundo", ", ¿qué", " tal?"])
    }

    func test_el_caso_real_prosa_y_despues_la_llamada_con_las_aperturas_partidas_en_tokens() {
        let pieces = ["Entendido, dame un momento: ", "voy a abrir el más reciente.", "\n\n", "<", "func", "tion", " name=\"browser_click\">", "\n<param", "eter name=\"selector\">@e816</parameter>\n</function>"]
        let v = joined(pieces)
        XCTAssertEqual(v, "Entendido, dame un momento: voy a abrir el más reciente.\n\n")
        XCTAssertFalse(v.contains("browser_click"))
        XCTAssertFalse(v.contains("<"))
    }

    func test_la_llamada_en_un_solo_token_tampoco_se_cuela() {
        let v = joined(["Voy a hacerlo. ", "<function name=\"a\"><parameter name=\"k\">v</parameter></function>"])
        XCTAssertEqual(v, "Voy a hacerlo. ")
    }

    func test_un_menor_que_en_prosa_se_suelta_en_cuanto_se_sabe_que_no_es_una_llamada() {
        XCTAssertEqual(joined(["si a ", "<", " b entonces c"]), "si a < b entonces c")
        XCTAssertEqual(joined(["usa la etiqueta <b", "> para negrita"]), "usa la etiqueta <b> para negrita")
        // `<functions>` no es `<function ...`
        XCTAssertEqual(joined(["mira <functions", "> aquí"]), "mira <functions> aquí")
    }

    func test_cada_apertura_conocida_se_confirma() {
        for opener in ["<function name=\"x\">", "<parameter name=\"x\">", "<execute_tool>x", "<tool_call>x", "<|tool_call>x", "<|tool>x"] {
            XCTAssertEqual(joined(["Antes. ", opener]), "Antes. ", opener)
        }
        // `<|tool_response>` no es una apertura de llamada y cae en prosa/limpieza posterior.
        XCTAssertTrue(joined(["Antes. ", "<|tool_response>x"]).hasPrefix("Antes. "))
    }

    func test_una_cola_retenida_que_nunca_se_resuelve_se_descarta_al_terminar() {
        XCTAssertEqual(joined(["Voy a abrirlo. ", "<func"]), "Voy a abrirlo. ")
        XCTAssertEqual(joined(["Voy a abrirlo. ", "<"]), "Voy a abrirlo. ")
    }

    func test_el_inicio_del_mensaje_conserva_la_regla_historica() {
        XCTAssertEqual(joined(["{\"name\": \"x\"", ", \"arguments\": {}}"]), "")
        XCTAssertEqual(joined(["call:foo", "{\"a\":1}"]), "")
        XCTAssertEqual(joined(["<tool_call>foo{}</tool_call>"]), "")
        XCTAssertEqual(joined(["  \n", "<function name=\"a\"></function>"]), "")
    }

    func test_un_inicio_que_solo_se_parece_a_una_llamada_se_suelta_sin_perder_texto() {
        XCTAssertEqual(shown(["ca", "sa grande"]).joined(), "casa grande")
        XCTAssertEqual(joined(["call", " me maybe"]), "call me maybe")
        XCTAssertEqual(joined(["ca"]), "ca")
    }

    func test_sin_regla_de_inicio_un_mensaje_json_sale_entero_pero_la_sintaxis_en_mitad_no() {
        XCTAssertEqual(joined(["{\"ok\": true}"], checksStart: false), "{\"ok\": true}")
        XCTAssertEqual(joined(["Listo. ", "<function name=\"a\">"], checksStart: false), "Listo. ")
    }

    func test_una_vez_confirmada_la_llamada_se_descarta_el_resto_aunque_haya_prosa_despues() {
        XCTAssertEqual(joined(["Voy. <function name=\"a\"></function> y luego más texto"]), "Voy. ")
    }

    func test_el_resto_limpio_cuando_se_descarto_algo_que_no_era_ejecutable() {
        var g = ToolSyntaxStreamGate(checksStart: true)
        _ = g.feed("Hola. ")
        _ = g.feed("<function name=\"a\">sin cerrar")
        _ = g.finish()
        XCTAssertEqual(g.phase, .suppressing)
        XCTAssertEqual(g.remainder(ofCleanText: "Hola. y el resto"), " y el resto")
        XCTAssertEqual(g.remainder(ofCleanText: "otra cosa distinta"), "", "si no encaja, no se emite nada")
    }
}
