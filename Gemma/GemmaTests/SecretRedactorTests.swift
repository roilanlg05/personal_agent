import Foundation
import XCTest
@testable import Gemma

final class SecretRedactorTests: XCTestCase {

    private func bóveda(_ secretos: [(String, String)]) -> SecretVault {
        let b = SecretVault(almacen: AlmacenEnMemoria())
        for (n, v) in secretos { XCTAssertTrue(b.guarda(name: n, value: v, etiqueta: n, origen: "x.com")) }
        return b
    }

    func test_sustituye_el_valor_por_su_nombre() {
        let b = bóveda([("gmail_pass", "hunter2")])
        XCTAssertEqual(SecretRedactor.limpia("la clave es hunter2 ok", vault: b), "la clave es [secreto: gmail_pass] ok")
    }

    func test_sustituye_todas_las_apariciones() {
        let b = bóveda([("p", "hunter2")])
        XCTAssertEqual(SecretRedactor.limpia("hunter2 y hunter2, otra vez hunter2", vault: b),
                       "[secreto: p] y [secreto: p], otra vez [secreto: p]")
    }

    func test_el_valor_mas_largo_gana_sobre_uno_contenido() {
        // Guardado el corto primero: si se sustituyera en orden de índice, `abcdef` quedaría `[..]def`.
        let b = bóveda([("corto", "abc"), ("largo", "abcdef")])
        XCTAssertEqual(SecretRedactor.limpia("x abcdef y", vault: b), "x [secreto: largo] y")
        XCTAssertEqual(SecretRedactor.limpia("x abc y", vault: b), "x [secreto: corto] y")
    }

    func test_valor_vacio_no_sustituye_nada() {
        // La bóveda rechaza guardar un valor vacío; se simula uno colado en el almacén.
        let almacen = AlmacenEnMemoria()
        almacen.escribir(#"["v"]"#, cuenta: "indice")
        almacen.escribir(#"{"value":"","etiqueta":"v","origen":"x.com"}"#, cuenta: "secreto.v")
        XCTAssertEqual(SecretRedactor.limpia("texto normal", vault: SecretVault(almacen: almacen)), "texto normal")
    }

    func test_sin_secretos_devuelve_el_texto_intacto() {
        XCTAssertEqual(SecretRedactor.limpia("nada que ocultar", vault: bóveda([])), "nada que ocultar")
    }

    func test_caracteres_especiales_se_tratan_literalmente_no_como_regex() {
        let b = bóveda([("p", "a.b*c$(1)")])
        XCTAssertEqual(SecretRedactor.limpia("a.b*c$(1) y aXbbbc", vault: b), "[secreto: p] y aXbbbc")
    }

    func test_tambien_tacha_la_forma_escapada_en_json() {
        let b = bóveda([("p", #"pa"ss\w"#)])
        let json = #"{"value":"pa\"ss\\w"}"#
        let limpio = SecretRedactor.limpia(json, vault: b)
        XCTAssertFalse(limpio.contains("ss"), "la forma escapada también es el secreto: \(limpio)")
        XCTAssertEqual(limpio, #"{"value":"[secreto: p]"}"#)
    }

    func test_con_el_indice_ilegible_falla_cerrado_y_no_devuelve_el_texto() {
        let almacen = AlmacenEnMemoria()
        almacen.escribir("{{corrupto", cuenta: "indice")
        let limpio = SecretRedactor.limpia("contraseña: hunter2", vault: SecretVault(almacen: almacen))
        XCTAssertEqual(limpio, "[resultado oculto: la bóveda de secretos no se puede leer]")
        XCTAssertFalse(limpio.contains("hunter2"))
    }
}
