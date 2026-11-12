import Foundation
import XCTest
@testable import Gemma

/// Almacén que rechaza TODA escritura, como un llavero mal firmado. `AlmacenEnMemoria` ya tiene
/// `rechazaEscrituras`, pero aquí hace falta uno que acepte la primera escritura y rechace la
/// segunda (el índice), para probar que la bóveda no deja un secreto huérfano.
private final class AlmacenQueRechazaDesde: AlmacenDeSecretos, @unchecked Sendable {
    private var secretos: [String: String] = [:]
    private var escrituras = 0
    private let aceptadas: Int
    init(aceptadas: Int) { self.aceptadas = aceptadas }
    func leer(cuenta: String) -> String? { secretos[cuenta] }
    func escribir(_ valor: String, cuenta: String) -> Bool {
        escrituras += 1
        guard escrituras <= aceptadas else { return false }
        secretos[cuenta] = valor
        return true
    }
    func borrar(cuenta: String) { secretos[cuenta] = nil }
    var cuentas: [String] { Array(secretos.keys) }
}

final class SecretVaultTests: XCTestCase {

    func test_guarda_y_lee_el_valor() {
        let b = SecretVault(almacen: AlmacenEnMemoria())
        XCTAssertTrue(b.guarda(name: "gmail_pass", value: "s3cr3to!", etiqueta: "Gmail", origen: "google.com"))
        XCTAssertEqual(b.valor(de: "gmail_pass"), "s3cr3to!")
        XCTAssertEqual(b.origen(de: "gmail_pass"), "google.com")
        XCTAssertNil(b.valor(de: "otro"))
    }

    func test_lista_no_contiene_valores() throws {
        let b = SecretVault(almacen: AlmacenEnMemoria())
        b.guarda(name: "a", value: "VALOR-ULTRA-SECRETO", etiqueta: "A", origen: "x.com")
        let json = String(data: try JSONEncoder().encode(b.lista()), encoding: .utf8)!
        XCTAssertFalse(json.contains("VALOR-ULTRA-SECRETO"))
        XCTAssertEqual(b.lista(), [SecretoGuardado(name: "a", etiqueta: "A", origen: "x.com")])
    }

    func test_guardar_dos_veces_el_mismo_nombre_reemplaza_y_no_duplica_el_indice() {
        let b = SecretVault(almacen: AlmacenEnMemoria())
        b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com")
        b.guarda(name: "a", value: "dos", etiqueta: "A2", origen: "y.com")
        XCTAssertEqual(b.lista().count, 1)
        XCTAssertEqual(b.valor(de: "a"), "dos")
        XCTAssertEqual(b.origen(de: "a"), "y.com")
        XCTAssertEqual(b.lista().first?.etiqueta, "A2")
    }

    func test_borra_quita_valor_e_indice() {
        let almacen = AlmacenEnMemoria()
        let b = SecretVault(almacen: almacen)
        b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com")
        b.guarda(name: "b", value: "dos", etiqueta: "B", origen: "x.com")
        b.borra(name: "a")
        XCTAssertNil(b.valor(de: "a"))
        XCTAssertNil(almacen.leer(cuenta: "secreto.a"))
        XCTAssertEqual(b.lista().map(\.name), ["b"])
        XCTAssertEqual(b.valoresActuales(), ["dos"])
    }

    func test_guarda_devuelve_false_si_el_almacen_rechaza() {
        let almacen = AlmacenEnMemoria()
        almacen.rechazaEscrituras = true
        let b = SecretVault(almacen: almacen)
        XCTAssertFalse(b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com"))
        XCTAssertNil(b.valor(de: "a"))
        XCTAssertTrue(b.lista().isEmpty)
    }

    func test_si_falla_la_escritura_del_indice_no_queda_un_secreto_huerfano() {
        // 1ª escritura (el secreto) pasa; la 2ª (el índice) se rechaza.
        let almacen = AlmacenQueRechazaDesde(aceptadas: 1)
        let b = SecretVault(almacen: almacen)
        XCTAssertFalse(b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com"))
        XCTAssertTrue(almacen.cuentas.isEmpty, "quedó \(almacen.cuentas)")
    }

    func test_nombre_invalido_se_rechaza() {
        let almacen = AlmacenEnMemoria()
        let b = SecretVault(almacen: almacen)
        for malo in ["", "Mayus", "con espacio", "a.b", "../x", String(repeating: "a", count: 41), "a\nb"] {
            XCTAssertFalse(b.guarda(name: malo, value: "v", etiqueta: "E", origen: "x.com"), malo)
            XCTAssertNil(b.valor(de: malo), malo)
        }
        XCTAssertTrue(b.guarda(name: String(repeating: "a", count: 40), value: "v", etiqueta: "E", origen: "x.com"))
        XCTAssertTrue(b.guarda(name: "a_1", value: "v", etiqueta: "E", origen: "x.com"))
    }

    func test_indiceLegible_es_true_sin_indice_y_con_indice_bueno() {
        let b = SecretVault(almacen: AlmacenEnMemoria())
        XCTAssertTrue(b.indiceLegible, "bóveda vacía: no hay índice y eso es legítimo")
        b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com")
        XCTAssertTrue(b.indiceLegible)
    }

    func test_indiceLegible_es_false_con_el_indice_corrupto() {
        let b = SecretVault(almacen: AlmacenEnMemoria(["indice": "{{no es json"]))
        XCTAssertFalse(b.indiceLegible)
    }

    func test_indice_corrupto_sin_secretos_no_rompe_y_guarda_se_niega() {
        let almacen = AlmacenEnMemoria(["indice": "{{no es json"])
        let b = SecretVault(almacen: almacen)
        XCTAssertTrue(b.lista().isEmpty)
        XCTAssertFalse(b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com"))
    }

    func test_indice_corrupto_con_secretos_ya_guardados_no_se_pisa() {
        let almacen = AlmacenEnMemoria()
        let b = SecretVault(almacen: almacen)
        b.guarda(name: "viejo", value: "CLAVE-VIEJA", etiqueta: "V", origen: "x.com")
        XCTAssertEqual(b.valoresActuales(), ["CLAVE-VIEJA"])
        almacen.escribir("{{corrupto", cuenta: "indice")

        XCTAssertFalse(b.guarda(name: "nuevo", value: "otra", etiqueta: "N", origen: "x.com"))
        // No se reescribió el índice con solo el nombre nuevo, y el secreto viejo sigue intacto.
        XCTAssertEqual(almacen.leer(cuenta: "indice"), "{{corrupto")
        XCTAssertNil(almacen.leer(cuenta: "secreto.nuevo"))
        XCTAssertEqual(b.valor(de: "viejo"), "CLAVE-VIEJA")
        // Arreglado el índice a mano, el secreto vuelve a verse en lista y en el redactor.
        almacen.escribir(#"["viejo"]"#, cuenta: "indice")
        XCTAssertEqual(b.valoresActuales(), ["CLAVE-VIEJA"])
        XCTAssertTrue(b.guarda(name: "nuevo", value: "otra", etiqueta: "N", origen: "x.com"))
        XCTAssertEqual(b.lista().map(\.name), ["viejo", "nuevo"])
    }

    func test_borra_con_indice_corrupto_borra_el_valor_y_no_toca_el_indice() {
        let almacen = AlmacenEnMemoria()
        let b = SecretVault(almacen: almacen)
        b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com")
        almacen.escribir("{{corrupto", cuenta: "indice")
        b.borra(name: "a")
        XCTAssertNil(b.valor(de: "a"))
        XCTAssertEqual(almacen.leer(cuenta: "indice"), "{{corrupto")
    }

    func test_origenPermite_rechaza_hosts_con_caracteres_que_no_son_de_host() {
        let g = "google.com"
        for malo in ["evil.com/.google.com", "evil.com#.google.com", "evil.com?.google.com",
                     "evil.com\\.google.com", "evil.com\n.google.com", "evil.com .google.com",
                     "user@evil.com.google.com", "a..google.com", ".google.com", "ev\u{0131}l.google.com",
                     "evil.com:google.com"] {
            XCTAssertFalse(SecretVault.origenPermite(guardado: g, paginaActual: malo), malo)
        }
        // El mismo juego de caracteres se exige al origen guardado.
        XCTAssertFalse(SecretVault.origenPermite(guardado: "google.com/x", paginaActual: "google.com/x"))
        XCTAssertFalse(SecretVault.origenPermite(guardado: "a b", paginaActual: "a b"))
        // Punycode y guiones siguen valiendo.
        XCTAssertTrue(SecretVault.origenPermite(guardado: "xn--bcher-kva.example", paginaActual: "www.xn--bcher-kva.example"))
        XCTAssertTrue(SecretVault.origenPermite(guardado: "my-site.com", paginaActual: "a-b.my-site.com"))
    }

    func test_entrada_corrupta_se_omite_de_lista_y_valores() {
        let almacen = AlmacenEnMemoria(["indice": "[\"roto\"]", "secreto.roto": "basura"])
        let b = SecretVault(almacen: almacen)
        XCTAssertTrue(b.lista().isEmpty)
        XCTAssertTrue(b.valoresActuales().isEmpty)
        XCTAssertNil(b.valor(de: "roto"))
    }

    func test_origenPermite_exacto_subdominio_y_rechazos() {
        XCTAssertTrue(SecretVault.origenPermite(guardado: "google.com", paginaActual: "google.com"))
        XCTAssertTrue(SecretVault.origenPermite(guardado: "google.com", paginaActual: "mail.google.com"))
        XCTAssertFalse(SecretVault.origenPermite(guardado: "google.com", paginaActual: "evilgoogle.com"))
        XCTAssertFalse(SecretVault.origenPermite(guardado: "google.com", paginaActual: "google.com.evil.com"))
    }

    func test_origenPermite_normaliza_mayusculas_punto_final_y_puerto() {
        XCTAssertTrue(SecretVault.origenPermite(guardado: "Google.COM", paginaActual: "MAIL.google.com."))
        XCTAssertTrue(SecretVault.origenPermite(guardado: "google.com", paginaActual: "google.com:8443"))
        XCTAssertFalse(SecretVault.origenPermite(guardado: "google.com", paginaActual: "evil.com:google.com"))
        // Un origen vacío o una página vacía nunca autorizan nada.
        XCTAssertFalse(SecretVault.origenPermite(guardado: "", paginaActual: ""))
        XCTAssertFalse(SecretVault.origenPermite(guardado: "", paginaActual: "google.com"))
        XCTAssertFalse(SecretVault.origenPermite(guardado: "google.com", paginaActual: ""))
        // El padre no hereda de su hijo.
        XCTAssertFalse(SecretVault.origenPermite(guardado: "mail.google.com", paginaActual: "google.com"))
    }

    func test_valoresActuales_omite_vacios() {
        let almacen = AlmacenEnMemoria()
        let b = SecretVault(almacen: almacen)
        b.guarda(name: "a", value: "uno", etiqueta: "A", origen: "x.com")
        // Un valor vacío no puede entrar por la API; se fuerza escribiendo directo para probar el filtro.
        almacen.escribir(#"{"value":"","etiqueta":"B","origen":"x.com"}"#, cuenta: "secreto.b")
        almacen.escribir(#"["a","b"]"#, cuenta: "indice")
        XCTAssertEqual(b.valoresActuales(), ["uno"])
        XCTAssertFalse(b.guarda(name: "c", value: "", etiqueta: "C", origen: "x.com"))
    }
}
