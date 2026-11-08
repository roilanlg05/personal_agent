import XCTest
@testable import Gemma

/// Pruebas del formato `<function name="x"><parameter name="k">v</parameter></function>`.
///
/// Origen: en el chat de YouTube del 2026-11-08 el modelo emitió así una llamada a
/// `browser_click` como TEXTO. El parser no conocía el formato, `pendingToolCalls` quedó
/// vacío y el bucle del agente terminó el turno en la primera vuelta: el agente anunciaba
/// la acción y no la hacía. Los tres formatos anteriores se fijan abajo para comprobar que
/// añadir este (que se evalúa primero) no cambió su comportamiento.
final class GemmaToolCallParserTests: XCTestCase {
    private func args(_ call: GemmaToolCallParser.ExtractedToolCall) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(call.args.utf8))
        return try XCTUnwrap(obj as? [String: Any], "args debe ser un objeto JSON: \(call.args)")
    }

    func test_un_parametro() throws {
        let r = GemmaToolCallParser.parseToolCalls(from: #"<function name="browser_click"><parameter name="selector">@e816</parameter></function>"#)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "browser_click")
        XCTAssertEqual(try args(r.toolCalls[0]) as? [String: String], ["selector": "@e816"])
        XCTAssertEqual(r.cleanText, "")
    }

    func test_varios_parametros_y_saltos_de_linea_entre_etiquetas() throws {
        let t = """
        <function name="browser_fill">
        <parameter name="selector">@e3</parameter>
        <parameter name="text">hola mundo</parameter>
        </function>
        """
        let r = GemmaToolCallParser.parseToolCalls(from: t)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(try args(r.toolCalls[0]) as? [String: String], ["selector": "@e3", "text": "hola mundo"])
        XCTAssertEqual(r.cleanText, "")
    }

    func test_cero_parametros() throws {
        for t in [#"<function name="browser_snapshot"></function>"#,
                  "<function name=\"browser_snapshot\">\n</function>",
                  #"<function name="browser_snapshot"/>"#] {
            let r = GemmaToolCallParser.parseToolCalls(from: t)
            XCTAssertEqual(r.toolCalls.count, 1, t)
            XCTAssertEqual(r.toolCalls.first?.name, "browser_snapshot", t)
            XCTAssertEqual(try args(r.toolCalls[0]).count, 0, t)
            XCTAssertEqual(r.cleanText, "", t)
        }
    }

    func test_el_valor_conserva_menor_mayor_comillas_saltos_de_linea_y_json() throws {
        let valor = "a < b && c > d, dijo \"hola\" y 'adiós'\nsegunda línea\t{\"k\": [1, 2]} \\ /"
        let r = GemmaToolCallParser.parseToolCalls(from: "<function name=\"browser_fill\"><parameter name=\"text\">\(valor)</parameter></function>")
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(try args(r.toolCalls[0])["text"] as? String, valor)
        XCTAssertEqual(r.cleanText, "")
    }

    func test_un_valor_que_es_json_valido_se_incrusta_estructurado() throws {
        let r = GemmaToolCallParser.parseToolCalls(from: #"<function name="x"><parameter name="opts">{"a": 1, "b": [true]}</parameter><parameter name="n">5</parameter></function>"#)
        let a = try args(r.toolCalls[0])
        XCTAssertEqual((a["opts"] as? [String: Any])?["a"] as? Int, 1)
        // Los números se quedan como cadena: los lectores de args de las herramientas aceptan "5".
        XCTAssertEqual(a["n"] as? String, "5")
    }

    func test_un_valor_muy_largo_no_se_trunca() throws {
        let largo = String(repeating: "abc<>\"\n", count: 20_000)
        let r = GemmaToolCallParser.parseToolCalls(from: "<function name=\"browser_fill\"><parameter name=\"text\">\(largo)</parameter></function>")
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual((try args(r.toolCalls[0])["text"] as? String)?.count, largo.count)
    }

    func test_varias_llamadas_en_un_mensaje_en_orden_y_la_prosa_se_conserva() throws {
        let t = #"Voy a hacerlo. <function name="a"><parameter name="k">1</parameter></function> luego <function name="b"></function> listo"#
        let r = GemmaToolCallParser.parseToolCalls(from: t)
        XCTAssertEqual(r.toolCalls.map(\.name), ["a", "b"])
        XCTAssertEqual(try args(r.toolCalls[0]) as? [String: String], ["k": "1"])
        XCTAssertEqual(r.cleanText, "Voy a hacerlo.  luego  listo")
    }

    func test_una_llamada_sin_cerrar_no_produce_llamada_ni_deja_fragmentos() {
        for t in [#"Voy a abrirlo. <function name="browser_click"><parameter name="selector">@e816"#,
                  #"Voy a abrirlo. <function name="browser_click"><parameter name="selector">@e816</parameter>"#,
                  #"Voy a abrirlo. <function name="browser_click">"#] {
            let r = GemmaToolCallParser.parseToolCalls(from: t)
            XCTAssertTrue(r.toolCalls.isEmpty, "no debe inventar una llamada: \(t)")
            XCTAssertEqual(r.cleanText, "Voy a abrirlo.", t)
        }
    }

    func test_la_prosa_que_menciona_la_etiqueta_sin_nombre_no_es_una_llamada() {
        let r = GemmaToolCallParser.parseToolCalls(from: "La etiqueta function en HTML no existe.")
        XCTAssertTrue(r.toolCalls.isEmpty)
        XCTAssertEqual(r.cleanText, "La etiqueta function en HTML no existe.")
    }

    func test_lo_que_ve_el_usuario_cuando_el_filtro_ya_se_comio_las_aperturas() {
        // Texto crudo del chat real: sin `<function` ni `<parameter`. No se puede ejecutar
        // (no hay forma fiable de saber que era una llamada), pero la sintaxis no debe quedar.
        // Ese retiro lo hace la contención del stream (ServerRuntime), no este parser.
        let r = GemmaToolCallParser.parseToolCalls(from: "Entendido.\n\n\n name=\"browser_click\">\n name=\"selector\">@e816")
        XCTAssertTrue(r.toolCalls.isEmpty)
    }

    // MARK: los tres formatos de antes siguen igual

    func test_formato_call_sigue_igual() throws {
        let r = GemmaToolCallParser.parseToolCalls(from: #"call:web_search{"query":"gatos"}"#)
        XCTAssertEqual(r.toolCalls.map(\.name), ["web_search"])
        XCTAssertEqual(r.toolCalls.first?.args, #"{"query":"gatos"}"#)
        XCTAssertEqual(r.cleanText, "")
    }

    func test_formato_execute_tool_sigue_igual() {
        let r = GemmaToolCallParser.parseToolCalls(from: #"<tool_call>web_search{"query":"x"}</tool_call>"#)
        XCTAssertEqual(r.toolCalls.map(\.name), ["web_search"])
        XCTAssertEqual(r.toolCalls.first?.args, #"{"query":"x"}"#)
    }

    func test_formato_json_sigue_igual() {
        let r = GemmaToolCallParser.parseToolCalls(from: #"{"name": "web_search", "arguments": {"query": "x"}}"#)
        XCTAssertEqual(r.toolCalls.map(\.name), ["web_search"])
        XCTAssertEqual(r.toolCalls.first?.args, #"{"query": "x"}"#)
    }
}
