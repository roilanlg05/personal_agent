import Foundation
import XCTest
@testable import Gemma

final class FormSpecTests: XCTestCase {
    private func parse(_ fields: String) throws -> FormSpec {
        try FormSpec.parse(title: "T", description: nil, submitLabel: nil, fieldsJSON: fields)
    }

    private func campos(_ n: Int) -> String {
        let items = (0..<n).map { #"{"id":"c\#($0)","label":"C","kind":"text","required":true}"# }
        return "[" + items.joined(separator: ",") + "]"
    }

    func test_acepta_un_formulario_valido_de_campos_mezclados() throws {
        let spec = try FormSpec.parse(
            title: "Crear cuenta", description: "d", submitLabel: "Listo",
            fieldsJSON: """
            [{"id":"user","label":"Usuario","kind":"text","required":true,"placeholder":"yo"},
             {"id":"pass","label":"Clave","kind":"secret","required":true,"secret_name":"gmail_password"},
             {"id":"plan","label":"Plan","kind":"choice","required":false,
              "options":[{"value":"a","label":"A"},{"value":"b","label":"B"}]}]
            """)
        XCTAssertEqual(spec.fields.count, 3)
        XCTAssertEqual(spec.submitLabel, "Listo")
        XCTAssertEqual(spec.fields[1].secretName, "gmail_password")
        XCTAssertEqual(spec.fields[2].options?.count, 2)
        XCTAssertEqual(spec.fields[0].placeholder, "yo")
    }

    func test_rechaza_cero_campos() {
        XCTAssertThrowsError(try parse("[]")) { XCTAssertEqual($0 as? FormSpecError, .sinCampos) }
    }

    func test_rechaza_trece_campos() throws {
        XCTAssertEqual(try parse(campos(12)).fields.count, 12)
        XCTAssertThrowsError(try parse(campos(13))) {
            XCTAssertEqual($0 as? FormSpecError, .demasiadosCampos)
        }
    }

    func test_rechaza_ids_repetidos() {
        let json = #"[{"id":"a","label":"A","kind":"text","required":true},{"id":"a","label":"B","kind":"text","required":true}]"#
        XCTAssertThrowsError(try parse(json)) { XCTAssertEqual($0 as? FormSpecError, .idsRepetidos) }
    }

    func test_rechaza_nombres_de_secreto_fuera_de_la_regex() {
        for nombre in ["Gmail", "a-b", "", String(repeating: "a", count: 41)] {
            let json = #"[{"id":"p","label":"P","kind":"secret","required":true,"secret_name":"\#(nombre)"}]"#
            XCTAssertThrowsError(try parse(json), "nombre: '\(nombre)'") {
                XCTAssertEqual($0 as? FormSpecError, .nombreDeSecretoInvalido(nombre))
            }
        }
        // Límite: 40 caracteres sí vale.
        let ok = #"[{"id":"p","label":"P","kind":"secret","required":true,"secret_name":"\#(String(repeating: "a", count: 40))"}]"#
        XCTAssertNoThrow(try parse(ok))
    }

    func test_choice_sin_opciones_falla_y_text_con_opciones_falla() {
        let sin = #"[{"id":"c","label":"C","kind":"choice","required":true}]"#
        XCTAssertThrowsError(try parse(sin)) { XCTAssertEqual($0 as? FormSpecError, .faltanOpciones("c")) }
        let vacias = #"[{"id":"m","label":"M","kind":"multichoice","required":true,"options":[]}]"#
        XCTAssertThrowsError(try parse(vacias)) { XCTAssertEqual($0 as? FormSpecError, .faltanOpciones("m")) }
        let sobran = #"[{"id":"t","label":"T","kind":"text","required":true,"options":[{"value":"a","label":"A"}]}]"#
        XCTAssertThrowsError(try parse(sobran)) { XCTAssertEqual($0 as? FormSpecError, .opcionesNoPermitidas("t")) }
    }

    func test_secret_sin_secret_name_falla_y_text_con_secret_name_falla() {
        let sin = #"[{"id":"p","label":"P","kind":"secret","required":true}]"#
        XCTAssertThrowsError(try parse(sin)) { XCTAssertEqual($0 as? FormSpecError, .faltaNombreDeSecreto("p")) }
        let sobra = #"[{"id":"t","label":"T","kind":"text","required":true,"secret_name":"x"}]"#
        XCTAssertThrowsError(try parse(sobra)) { XCTAssertEqual($0 as? FormSpecError, .nombreDeSecretoNoPermitido("t")) }
    }

    func test_json_que_no_es_una_lista_falla_con_jsonInvalido() {
        for malo in [#"{"id":"a"}"#, "no es json", #"[{"id":"a","label":"A","kind":"inventado","required":true}]"#] {
            XCTAssertThrowsError(try parse(malo), malo) { XCTAssertEqual($0 as? FormSpecError, .jsonInvalido) }
        }
    }

    func test_la_respuesta_serializa_el_literal_del_secreto() throws {
        XCTAssertEqual(FormResponse.textoDeSecretoGuardado("gmail_password"), "[secreto guardado: gmail_password]")
        let r = FormResponse(status: .submitted, values: ["pass": FormResponse.textoDeSecretoGuardado("gmail_password")])
        let obj = try JSONSerialization.jsonObject(with: Data(r.json.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["status"] as? String, "submitted")
        XCTAssertEqual((obj?["values"] as? [String: String])?["pass"], "[secreto guardado: gmail_password]")
    }

    func test_required_ausente_es_true_y_presente_en_false_es_false() throws {
        let spec = try parse(#"[{"id":"a","label":"A","kind":"secret","secret_name":"x"},{"id":"b","label":"B","kind":"text","required":false}]"#)
        XCTAssertTrue(spec.fields[0].required)
        XCTAssertFalse(spec.fields[1].required)
    }
}
