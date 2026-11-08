import XCTest
@testable import Gemma

final class ToolLogRowTests: XCTestCase {
    func test_snapshot_cuenta_los_objetos_y_no_los_enseña() {
        let json = #"{"status":"success","snapshot":"- generic [ref=e1]\n- link [ref=e2]\n- text [ref=e3]"}"#
        XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_snapshot", resultJSON: json),
                       .count(3, "objetos"))
    }

    func test_get_enseña_el_dato_porque_es_la_respuesta() {
        let json = #"{"status":"success","value":"59,99 €"}"#
        XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_get", resultJSON: json),
                       .value("59,99 €"))
    }

    func test_open_enseña_el_host_no_la_url_entera() {
        let json = #"{"status":"success","url":"https://www.amazon.es/s?k=raquetas+ping+pong"}"#
        XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_open", resultJSON: json),
                       .value("www.amazon.es"))
    }

    func test_una_accion_sin_dato_solo_dice_que_salio_bien() {
        for tool in ["browser_click", "browser_fill", "browser_press", "browser_wait", "browser_close"] {
            XCTAssertEqual(ToolLogRow.summarize(toolName: tool, resultJSON: #"{"status":"success"}"#),
                           .ok, "\(tool) no devuelve ningún dato que merezca una línea")
        }
    }

    func test_un_fallo_enseña_su_motivo_sin_tener_que_abrir_la_fila() {
        let json = #"{"status":"error","message":"No se pudo lanzar el navegador: timeout"}"#
        XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_open", resultJSON: json),
                       .failure("No se pudo lanzar el navegador: timeout"))
    }

    func test_lo_que_no_es_json_no_rompe_la_fila_ni_la_deja_en_blanco() {
        for basura in ["", "Fatal error: índice fuera de rango", "{roto"] {
            let r = ToolLogRow.summarize(toolName: "browser_get", resultJSON: basura)
            if case .failure(let motivo) = r { XCTAssertFalse(motivo.isEmpty) }
            else { XCTFail("un resultado ilegible es un fallo, no un éxito: \(r)") }
        }
    }

    func test_el_detalle_se_recorta_para_que_abrir_la_fila_no_cuelgue_la_interfaz() {
        let enorme = String(repeating: "x", count: 500_000)
        XCTAssertLessThanOrEqual(ToolLogRow.detail(resultJSON: enorme).count, ToolLogRow.detailLimit)
        XCTAssertTrue(ToolLogRow.detail(resultJSON: enorme).hasSuffix("…"))
    }

    func test_read_webpage_cuenta_caracteres() {
        let json = #"{"status":"success","content":"Hola mundo"}"#
        XCTAssertEqual(ToolLogRow.summarize(toolName: "read_webpage", resultJSON: json),
                       .count(10, "caracteres"))
    }

    func test_web_search_cuenta_resultados() {
        let json = #"{"status":"success","count":3,"results":[]}"#
        XCTAssertEqual(ToolLogRow.summarize(toolName: "web_search", resultJSON: json),
                       .count(3, "resultados"))
    }
}
