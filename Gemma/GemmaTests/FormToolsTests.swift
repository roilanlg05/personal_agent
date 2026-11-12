import Foundation
import XCTest
@testable import Gemma

/// Red de seguridad: por defecto el plazo del broker vence al instante, así que una herramienta
/// que presenta un formulario que NO debía presentarse devuelve `timeout` y la prueba falla en
/// ROJO en vez de colgarse 10 minutos. Las pruebas que simulan a un usuario lo apagan.
final class RelojDePrueba: @unchecked Sendable {
    var esperaDeVerdad = false
}

@MainActor
final class FormToolsTests: XCTestCase {
    private let urlGoogle = #"{"success":true,"data":{"url":"https://Accounts.Google.com:8443/signin/v2?continue=x#frag"},"error":null}"#
    private let sinPagina = #"{"success":false,"data":null,"error":"No page open"}"#

    private let reloj = RelojDePrueba()

    private struct Montaje {
        let tool: PresentFormTool
        let broker: FormBroker
        let vault: SecretVault
        let almacen: AlmacenEnMemoria
        let mock: MockAgentBrowserInvoker
    }

    private func monta(stdout: String? = nil, conServicio: Bool = true, almacen: AlmacenEnMemoria = AlmacenEnMemoria()) -> Montaje {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: stdout ?? urlGoogle)
        let vault = SecretVault(almacen: almacen)
        let reloj = self.reloj
        let broker = FormBroker(dormir: { _ in if reloj.esperaDeVerdad { try await Task.sleep(for: .seconds(3600)) } })
        let service = conServicio ? AgentBrowserService(invoker: mock, sessionName: "gemma") : nil
        return Montaje(tool: PresentFormTool(broker: broker, vault: vault, service: service),
                       broker: broker, vault: vault, almacen: almacen, mock: mock)
    }

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }

    private func args(fields: String, title: String = "Entrar") -> String {
        let obj: [String: Any] = ["title": title, "fields": fields]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private let campoSecreto = #"{"id":"pw","label":"Contraseña","kind":"secret","secret_name":"gmail_password"}"#

    /// Lanza la herramienta, espera a que el formulario esté abierto y lo envía (o cancela).
    private func ejecuta(_ m: Montaje, fields: String, enviar: [String: String]?) async throws -> String {
        reloj.esperaDeVerdad = true
        let t = Task { await m.tool.run(argsJSON: args(fields: fields)) }
        var id: String?
        for _ in 0..<500 {
            if let p = m.broker.pendiente { id = p.id; break }
            await Task.yield()
        }
        let abierto = try XCTUnwrap(id, "el formulario nunca se abrió")
        if let enviar { m.broker.envia(id: abierto, valores: enviar) } else { m.broker.cancela(id: abierto) }
        return await t.value
    }

    // MARK: present_form

    func test_present_form_con_un_secreto_lo_guarda_con_el_origen_de_la_pagina_y_el_resultado_no_lleva_el_valor() async throws {
        let m = monta()
        let out = try await ejecuta(m, fields: "[\(campoSecreto)]", enviar: ["pw": "hunter2-super"])
        XCTAssertFalse(out.contains("hunter2-super"))
        XCTAssertTrue(out.contains("[secreto guardado: gmail_password]"), out)
        XCTAssertEqual(try parse(out)["status"] as? String, "submitted")
        XCTAssertEqual(m.vault.origen(de: "gmail_password"), "accounts.google.com")
        XCTAssertEqual(m.vault.valor(de: "gmail_password"), "hunter2-super")
    }

    func test_el_origen_guardado_es_un_host_limpio_sin_puerto_ruta_ni_query() async throws {
        let m = monta(stdout: #"{"success":true,"data":{"url":"https://Login.Example.COM:8443/a/b?x=1#h"},"error":null}"#)
        _ = try await ejecuta(m, fields: "[\(campoSecreto)]", enviar: ["pw": "x1"])
        XCTAssertEqual(m.vault.origen(de: "gmail_password"), "login.example.com")
    }

    func test_una_url_basura_da_error_y_no_presenta_nada() async throws {
        for basura in ["", "no es una url", "about:blank"] {
            let stdout = #"{"success":true,"data":{"url":"\#(basura)"},"error":null}"#
            let m = monta(stdout: stdout)
            let out = await m.tool.run(argsJSON: args(fields: "[\(campoSecreto)]"))
            XCTAssertEqual(try parse(out)["status"] as? String, "error", "url: \(basura)")
            XCTAssertNil(m.broker.pendiente)
            XCTAssertTrue(m.vault.lista().isEmpty)
        }
    }

    func test_present_form_con_secreto_y_sin_pagina_abierta_devuelve_error() async throws {
        let m = monta(stdout: sinPagina)
        let out = await m.tool.run(argsJSON: args(fields: "[\(campoSecreto)]"))
        let j = try parse(out)
        XCTAssertEqual(j["status"] as? String, "error")
        XCTAssertTrue((j["message"] as? String ?? "").contains("abre primero la página"), out)
        XCTAssertNil(m.broker.pendiente)
    }

    func test_present_form_con_secreto_y_sin_servicio_de_navegador_devuelve_error() async throws {
        let m = monta(conServicio: false)
        let out = await m.tool.run(argsJSON: args(fields: "[\(campoSecreto)]"))
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertNil(m.broker.pendiente)
    }

    func test_present_form_con_campos_invalidos_devuelve_el_error_de_validacion() async throws {
        let m = monta()
        for malo in ["no json", "[]", #"[{"id":"a","label":"A","kind":"text"},{"id":"a","label":"B","kind":"text"}]"#,
                     #"[{"id":"s","label":"S","kind":"secret"}]"#] {
            let out = await m.tool.run(argsJSON: args(fields: malo))
            XCTAssertEqual(try parse(out)["status"] as? String, "error", malo)
        }
        XCTAssertNil(m.broker.pendiente)
        XCTAssertTrue(m.mock.receivedArguments.isEmpty)
    }

    func test_present_form_sin_titulo_o_sin_campos_devuelve_error() async throws {
        let m = monta()
        let a = await m.tool.run(argsJSON: #"{"fields":"[]"}"#)
        let b = await m.tool.run(argsJSON: #"{"title":"T"}"#)
        XCTAssertEqual(try parse(a)["status"] as? String, "error")
        XCTAssertEqual(try parse(b)["status"] as? String, "error")
    }

    func test_dos_secretos_con_el_mismo_secret_name_se_rechazan_antes_de_presentar() async throws {
        let m = monta()
        let dup = #"[{"id":"a","label":"A","kind":"secret","secret_name":"clave"},{"id":"b","label":"B","kind":"secret","secret_name":"clave"}]"#
        let out = await m.tool.run(argsJSON: args(fields: dup))
        let j = try parse(out)
        XCTAssertEqual(j["status"] as? String, "error")
        XCTAssertTrue((j["message"] as? String ?? "").contains("clave"))
        XCTAssertNil(m.broker.pendiente)
        XCTAssertTrue(m.mock.receivedArguments.isEmpty)
    }

    func test_present_form_cancelado_no_guarda_nada() async throws {
        let m = monta()
        let out = try await ejecuta(m, fields: "[\(campoSecreto)]", enviar: nil)
        XCTAssertEqual(try parse(out)["status"] as? String, "cancelled")
        XCTAssertTrue(m.vault.lista().isEmpty)
    }

    func test_present_form_sin_secretos_no_consulta_la_pagina() async throws {
        let m = monta()
        let out = try await ejecuta(m, fields: #"[{"id":"n","label":"Nombre","kind":"text"}]"#, enviar: ["n": "Ana"])
        let j = try parse(out)
        XCTAssertEqual(j["status"] as? String, "submitted")
        XCTAssertEqual((j["values"] as? [String: String])?["n"], "Ana")
        XCTAssertTrue(m.mock.receivedArguments.isEmpty)
    }

    func test_present_form_con_otro_formulario_abierto_devuelve_error() async throws {
        let m = monta()
        reloj.esperaDeVerdad = true
        let primero = Task { await m.tool.run(argsJSON: args(fields: #"[{"id":"n","label":"N","kind":"text"}]"#)) }
        for _ in 0..<500 where m.broker.pendiente == nil { await Task.yield() }
        let out = await m.tool.run(argsJSON: args(fields: #"[{"id":"n","label":"N","kind":"text"}]"#))
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        m.broker.cancelaTodo()
        _ = await primero.value
    }

    func test_si_la_boveda_rechaza_guardar_el_resultado_es_error_y_no_dice_guardado() async throws {
        let almacen = AlmacenEnMemoria()
        let m = monta(almacen: almacen)
        reloj.esperaDeVerdad = true
        let t = Task { await m.tool.run(argsJSON: args(fields: "[\(campoSecreto)]")) }
        for _ in 0..<500 where m.broker.pendiente == nil { await Task.yield() }
        almacen.rechazaEscrituras = true
        m.broker.envia(id: m.broker.pendiente!.id, valores: ["pw": "hunter2-super"])
        let out = await t.value
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertFalse(out.contains("[secreto guardado"))
        XCTAssertFalse(out.contains("hunter2-super"))
    }

    func test_si_el_segundo_secreto_falla_se_deshace_el_primero() async throws {
        let m = monta()
        let dos = #"[{"id":"a","label":"A","kind":"secret","secret_name":"uno"},{"id":"b","label":"B","kind":"secret","secret_name":"dos"}]"#
        // El segundo valor llega vacío siendo obligatorio: la bóveda lo rechaza.
        let out = try await ejecuta(m, fields: dos, enviar: ["a": "valor-a", "b": ""])
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertNil(m.vault.valor(de: "uno"), "no debe quedar guardado a medias")
        XCTAssertFalse(out.contains("valor-a"))
    }

    func test_secreto_opcional_vacio_no_se_guarda_y_no_dice_guardado() async throws {
        let m = monta()
        let f = #"[{"id":"pw","label":"P","kind":"secret","secret_name":"opc","required":false}]"#
        let out = try await ejecuta(m, fields: f, enviar: ["pw": ""])
        let j = try parse(out)
        XCTAssertEqual(j["status"] as? String, "submitted")
        XCTAssertEqual((j["values"] as? [String: String])?["pw"], "")
        XCTAssertNil(m.vault.valor(de: "opc"))
    }

    func test_con_el_indice_ilegible_present_form_con_secreto_falla_cerrado() async throws {
        let m = monta(almacen: AlmacenEnMemoria(["indice": "{basura"]))
        let out = await m.tool.run(argsJSON: args(fields: "[\(campoSecreto)]"))
        let j = try parse(out)
        XCTAssertEqual(j["status"] as? String, "error")
        XCTAssertTrue((j["message"] as? String ?? "").contains("la bóveda de secretos no se puede leer"))
        XCTAssertNil(m.broker.pendiente)
    }

    func test_con_el_indice_ilegible_un_formulario_sin_secretos_sigue_funcionando() async throws {
        let m = monta(almacen: AlmacenEnMemoria(["indice": "{basura"]))
        let out = try await ejecuta(m, fields: #"[{"id":"n","label":"N","kind":"text"}]"#, enviar: ["n": "x"])
        XCTAssertEqual(try parse(out)["status"] as? String, "submitted")
    }

    // MARK: ronda de arreglo 1

    func test_un_secret_name_existente_con_otro_origen_se_rechaza_antes_de_presentar() async throws {
        let m = monta()   // la página actual es accounts.google.com
        m.vault.guarda(name: "gmail_password", value: "original", etiqueta: "Gmail", origen: "evil.com")
        let out = await m.tool.run(argsJSON: args(fields: "[\(campoSecreto)]"))
        let j = try parse(out)
        XCTAssertEqual(j["status"] as? String, "error")
        XCTAssertTrue((j["message"] as? String ?? "").contains("forget_secret"), out)
        XCTAssertNil(m.broker.pendiente)
        XCTAssertEqual(m.vault.origen(de: "gmail_password"), "evil.com")
        XCTAssertEqual(m.vault.valor(de: "gmail_password"), "original")
    }

    func test_un_secret_name_existente_con_el_mismo_origen_se_reemplaza() async throws {
        let m = monta()
        m.vault.guarda(name: "gmail_password", value: "vieja", etiqueta: "Gmail", origen: "accounts.google.com")
        let out = try await ejecuta(m, fields: "[\(campoSecreto)]", enviar: ["pw": "nueva"])
        XCTAssertEqual(try parse(out)["status"] as? String, "submitted")
        XCTAssertEqual(m.vault.valor(de: "gmail_password"), "nueva")
        XCTAssertEqual(m.vault.origen(de: "gmail_password"), "accounts.google.com")
    }

    func test_el_deshacer_restaura_un_secreto_preexistente_con_valor_etiqueta_y_origen() async throws {
        let m = monta()
        m.vault.guarda(name: "uno", value: "valor-viejo", etiqueta: "Etiqueta vieja", origen: "accounts.google.com")
        let dos = #"[{"id":"a","label":"A","kind":"secret","secret_name":"uno"},{"id":"b","label":"B","kind":"secret","secret_name":"dos"}]"#
        let out = try await ejecuta(m, fields: dos, enviar: ["a": "valor-nuevo", "b": ""])
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertEqual(m.vault.valor(de: "uno"), "valor-viejo")
        XCTAssertEqual(m.vault.origen(de: "uno"), "accounts.google.com")
        XCTAssertEqual(m.vault.lista().first { $0.name == "uno" }?.etiqueta, "Etiqueta vieja")
        XCTAssertNil(m.vault.valor(de: "dos"))
        XCTAssertFalse(out.contains("valor-viejo") || out.contains("valor-nuevo"))
    }

    // MARK: list_secrets / forget_secret

    func test_list_secrets_no_contiene_valores() async throws {
        let v = SecretVault(almacen: AlmacenEnMemoria())
        v.guarda(name: "gmail_password", value: "hunter2-super", etiqueta: "Gmail", origen: "google.com")
        let out = await ListSecretsTool(vault: v).run(argsJSON: "{}")
        XCTAssertFalse(out.contains("hunter2-super"))
        let j = try parse(out)
        let lista = try XCTUnwrap(j["secrets"] as? [[String: String]])
        XCTAssertEqual(lista, [["name": "gmail_password", "etiqueta": "Gmail", "origen": "google.com"]])
    }

    func test_list_secrets_con_indice_ilegible_es_error_no_lista_vacia() async throws {
        let v = SecretVault(almacen: AlmacenEnMemoria(["indice": "{basura"]))
        let out = await ListSecretsTool(vault: v).run(argsJSON: "{}")
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
    }

    func test_forget_secret_borra() async throws {
        let v = SecretVault(almacen: AlmacenEnMemoria())
        v.guarda(name: "k", value: "v1", etiqueta: "K", origen: "a.com")
        let out = await ForgetSecretTool(vault: v).run(argsJSON: #"{"name":"k"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "success")
        XCTAssertNil(v.valor(de: "k"))
        XCTAssertTrue(v.lista().isEmpty)
    }

    func test_forget_secret_sin_nombre_o_inexistente_es_error() async throws {
        let v = SecretVault(almacen: AlmacenEnMemoria())
        let a = await ForgetSecretTool(vault: v).run(argsJSON: "{}")
        let b = await ForgetSecretTool(vault: v).run(argsJSON: #"{"name":"nada"}"#)
        XCTAssertEqual(try parse(a)["status"] as? String, "error")
        XCTAssertEqual(try parse(b)["status"] as? String, "error")
    }

    func test_forget_secret_con_indice_ilegible_falla_cerrado_y_no_borra() async throws {
        let almacen = AlmacenEnMemoria(["indice": "{basura", "secreto.k": #"{"value":"v1","etiqueta":"K","origen":"a.com"}"#])
        let v = SecretVault(almacen: almacen)
        let out = await ForgetSecretTool(vault: v).run(argsJSON: #"{"name":"k"}"#)
        let j = try parse(out)
        XCTAssertEqual(j["status"] as? String, "error")
        XCTAssertTrue((j["message"] as? String ?? "").contains("la bóveda de secretos no se puede leer"))
        XCTAssertEqual(v.valor(de: "k"), "v1")
    }
}
