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

    private func isFailure(_ r: ToolRowSummary) -> Bool { if case .failure = r { return true }; return false }

    func test_el_estado_ok_no_es_un_fallo() {
        let r = ToolLogRow.summarize(toolName: "search_memory", resultJSON: #"{"status":"ok","items":[]}"#)
        XCTAssertFalse(isFailure(r), "\(r)")
    }

    func test_los_estados_de_exito_del_repositorio_no_son_fallo() {
        for st in ["ok","created","deleted","updated","found","saved","done","remembered","empty","no_results"] {
            let r = ToolLogRow.summarize(toolName: "x", resultJSON: #"{"status":"\#(st)"}"#)
            XCTAssertFalse(isFailure(r), "\(st) -> \(r)")
        }
    }

    func test_sin_estado_no_es_un_fallo() {
        XCTAssertFalse(isFailure(ToolLogRow.summarize(toolName: "x", resultJSON: #"{"count":3}"#)))
    }

    func test_los_estados_de_fallo_son_fallo() {
        for st in ["failed","error","timeout","not_found","invalid_date","invalid_coordinates"] {
            let r = ToolLogRow.summarize(toolName: "x", resultJSON: #"{"status":"\#(st)"}"#)
            XCTAssertTrue(isFailure(r), "\(st) -> \(r)")
        }
    }

    func test_web_search_sin_resultados_cuenta_cero_y_no_falla() {
        XCTAssertEqual(ToolLogRow.summarize(toolName: "web_search", resultJSON: #"{"status":"no_results","count":0}"#),
                       .count(0, "resultados"))
    }

    func test_json_ilegible_sigue_siendo_fallo() {
        XCTAssertTrue(isFailure(ToolLogRow.summarize(toolName: "x", resultJSON: "{roto")))
    }

    func test_browser_get_con_count_cuenta_elementos() {
        XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_get", resultJSON: #"{"status":"success","count":7}"#),
                       .count(7, "elementos"))
    }

    func test_browser_open_con_url_sin_host() {
        XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_open", resultJSON: #"{"status":"success","url":"notaurl"}"#), .ok)
    }

    func test_un_mensaje_largo_de_estado_no_fallo_se_recorta() {
        let largo = String(repeating: "m", count: 300)
        let r = ToolLogRow.summarize(toolName: "x", resultJSON: #"{"status":"no_content","message":"\#(largo)"}"#)
        guard case .value(let v) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(v.count, ToolLogRow.messageLimit + 1)
        XCTAssertTrue(v.hasSuffix("…"))
        let corto = ToolLogRow.summarize(toolName: "x", resultJSON: #"{"status":"no_content","message":"sin texto"}"#)
        XCTAssertEqual(corto, .value("sin texto"))
    }

    func test_cerrar_una_herramienta_rellena_su_fila_abierta_y_no_añade_otra() {
        var log = [ChatLogEntry(role: "tool", text: "", toolName: "a"),
                   ChatLogEntry(role: "tool", text: "", toolName: "a")]
        ToolLogRow.closeRow(in: &log, toolName: "a", result: "R")
        XCTAssertEqual(log.count, 2)
        XCTAssertNil(log[0].toolDetail)
        XCTAssertEqual(log[1].toolDetail, "R", "se cierra la última abierta")
        ToolLogRow.closeRow(in: &log, toolName: "b", result: "S")
        XCTAssertEqual(log.count, 3, "un finished sin started no pierde el resultado")
    }
}
