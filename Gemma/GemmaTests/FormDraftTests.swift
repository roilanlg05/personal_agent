import XCTest
@testable import Gemma

final class FormDraftTests: XCTestCase {
    private func spec(_ campos: [FormField]) -> FormSpec {
        FormSpec(title: "t", description: nil, submitLabel: nil, fields: campos)
    }
    private let opciones = [FormField.Option(value: "a", label: "A"), FormField.Option(value: "b", label: "B")]

    func test_requerido_vacio_bloquea_y_al_rellenar_deja_enviar() {
        var d = FormDraft(spec: spec([FormField(id: "n", label: "Nombre", kind: .text)]))
        XCTAssertFalse(d.puedeEnviar)
        XCTAssertNotNil(d.errores["n"])
        d.set("n", "Ana")
        XCTAssertTrue(d.puedeEnviar)
    }

    func test_opcional_vacio_no_bloquea() {
        let d = FormDraft(spec: spec([FormField(id: "n", label: "N", kind: .text, required: false)]))
        XCTAssertTrue(d.puedeEnviar)
    }

    func test_secreto_requerido_vacio_bloquea() {
        var d = FormDraft(spec: spec([FormField(id: "p", label: "P", kind: .secret, secretName: "pw")]))
        XCTAssertFalse(d.puedeEnviar)
        d.set("p", "x")
        XCTAssertTrue(d.puedeEnviar)
    }

    func test_numero_con_texto_no_parsea_y_acepta_coma() {
        var d = FormDraft(spec: spec([FormField(id: "x", label: "X", kind: .number)]))
        d.set("x", "abc")
        XCTAssertNotNil(d.errores["x"])
        d.set("x", "3,5")
        XCTAssertNil(d.errores["x"])
        XCTAssertEqual(d.paraEnviar["x"], "3.5")
        d.set("x", "42")
        XCTAssertEqual(d.paraEnviar["x"], "42")
    }

    func test_choice_fuera_de_opciones_bloquea() {
        var d = FormDraft(spec: spec([FormField(id: "c", label: "C", kind: .choice, options: opciones)]))
        d.set("c", "z")
        XCTAssertFalse(d.puedeEnviar)
        d.set("c", "b")
        XCTAssertTrue(d.puedeEnviar)
    }

    func test_multichoice_valida_cada_elegida() {
        var d = FormDraft(spec: spec([FormField(id: "m", label: "M", kind: .multichoice, options: opciones)]))
        d.set("m", "a\nz")
        XCTAssertFalse(d.puedeEnviar)
        d.set("m", "a\nb")
        XCTAssertTrue(d.puedeEnviar)
    }

    func test_confirm_por_defecto_false_y_solo_true_false() {
        var d = FormDraft(spec: spec([FormField(id: "k", label: "K", kind: .confirm)]))
        XCTAssertEqual(d.values["k"], "false")
        XCTAssertTrue(d.puedeEnviar, "una confirmación sin marcar es un «no» válido")
        d.set("k", "quizá")
        XCTAssertFalse(d.puedeEnviar)
    }

    func test_fecha_formato_estricto() {
        var d = FormDraft(spec: spec([FormField(id: "f", label: "F", kind: .date)]))
        d.set("f", "11/11/2026")
        XCTAssertFalse(d.puedeEnviar)
        d.set("f", "2026-02-30")
        XCTAssertFalse(d.puedeEnviar)
        d.set("f", "2026-11-11")
        XCTAssertTrue(d.puedeEnviar)
        XCTAssertEqual(FormDraft.textoDeFecha(FormDraft.fecha("2026-11-11")!), "2026-11-11")
    }

    func test_paraEnviar_incluye_todos_los_ids_y_set_ignora_ajenos() {
        var d = FormDraft(spec: spec([FormField(id: "a", label: "A", kind: .text, required: false),
                                      FormField(id: "k", label: "K", kind: .confirm)]))
        d.set("fantasma", "x")
        XCTAssertEqual(Set(d.paraEnviar.keys), ["a", "k"])
        XCTAssertEqual(d.paraEnviar["a"], "")
    }
}

/// Cableado de la tarjeta del chat en `HarnessModel`.
@MainActor
final class FormChatWiringTests: XCTestCase {
    private func modelo() -> HarnessModel { HarnessModel(almacen: AlmacenEnMemoria()) }
    private let spec = FormSpec(title: "Datos", description: nil, submitLabel: nil,
                                fields: [FormField(id: "p", label: "Clave", kind: .secret, secretName: "pw")])

    private func esperaPendiente(_ m: HarnessModel) async {
        for _ in 0..<200 where m.formularios.pendiente == nil { await Task.yield() }
        // El observador salta al ciclo siguiente.
        for _ in 0..<50 where !m.agentLog.contains(where: { $0.role == "form" }) { await Task.yield() }
    }

    func test_un_formulario_abierto_crea_una_sola_tarjeta_pendiente() async {
        let m = modelo()
        let t = Task { try? await m.formularios.presenta(spec) }
        await esperaPendiente(m)
        m.sincronizaFormularios(); m.sincronizaFormularios()
        let filas = m.agentLog.filter { $0.role == "form" }
        XCTAssertEqual(filas.count, 1)
        XCTAssertEqual(filas.first?.formEstado, "pendiente")
        XCTAssertEqual(filas.first?.formID, m.formularios.pendiente?.id)
        XCTAssertEqual(m.especificacionDeFormulario(filas[0]), spec)
        m.cierraFormularioAbierto(); _ = await t.value
    }

    func test_enviar_deja_la_tarjeta_enviada_sin_valores_y_responde_al_broker() async {
        let m = modelo()
        let t = Task { try? await m.formularios.presenta(spec) }
        await esperaPendiente(m)
        let fila = m.agentLog.first { $0.role == "form" }!
        m.enviaFormulario(fila, valores: ["p": "hunter2"])
        let r = await t.value
        XCTAssertEqual(r?.status, .submitted)
        let tras = m.agentLog.first { $0.role == "form" }!
        XCTAssertEqual(tras.formEstado, "enviado")
        XCTAssertTrue(m.especificacionDeFormulario(tras).fields.isEmpty, "resuelta: sin campos que pintar")
        XCTAssertFalse(String(describing: tras).contains("hunter2"))
    }

    func test_dos_formularios_seguidos_son_dos_tarjetas_con_su_propio_estado() async {
        let m = modelo()
        let t1 = Task { try? await m.formularios.presenta(spec) }
        await esperaPendiente(m)
        m.enviaFormulario(m.agentLog.first { $0.role == "form" }!, valores: ["p": "x"])
        _ = await t1.value
        let t2 = Task { try? await m.formularios.presenta(spec) }
        for _ in 0..<200 where m.agentLog.filter({ $0.role == "form" }).count < 2 { await Task.yield() }
        let filas = m.agentLog.filter { $0.role == "form" }
        XCTAssertEqual(filas.map(\.formEstado), ["enviado", "pendiente"])
        XCTAssertNotEqual(filas[0].formID, filas[1].formID)
        m.cierraFormularioAbierto(); _ = await t2.value
    }

    func test_fin_de_turno_o_detener_deja_la_tarjeta_cancelada() async {
        let m = modelo()
        let t = Task { try? await m.formularios.presenta(spec) }
        await esperaPendiente(m)
        m.cancelAgentTurn()
        let r = await t.value
        XCTAssertEqual(r?.status, .cancelled)
        XCTAssertEqual(m.agentLog.first { $0.role == "form" }?.formEstado, "cancelado")
    }

    func test_cierre_externo_del_broker_deja_la_tarjeta_cancelada_y_un_envio_tardio_no_hace_nada() async {
        let m = modelo()
        let fila: ChatLogEntry
        let broker = m.formularios
        let t = Task { try? await broker.presenta(spec) }
        await esperaPendiente(m)
        fila = m.agentLog.first { $0.role == "form" }!
        // Caduca por fuera de la tarjeta (el broker lo resuelve) y luego llega el sincronizador.
        broker.cancelaTodo(); _ = await t.value
        m.sincronizaFormularios()
        XCTAssertEqual(m.agentLog.first { $0.role == "form" }?.formEstado, "cancelado")
        m.enviaFormulario(fila, valores: ["p": "tarde"])  // la tarjeta ya no es «pendiente»
        XCTAssertEqual(m.agentLog.first { $0.role == "form" }?.formEstado, "cancelado")
    }

    /// Ata el hallazgo de la Task 3: sin bóveda en el Agent de producción el redactor es código muerto.
    func test_el_agent_de_produccion_recibe_la_boveda() {
        let m = modelo()
        let agent = m.construyeAgent(registry: ToolRegistry(), recallTail: "", wakeContext: "")
        XCTAssertNotNil(agent.bóveda)
        XCTAssertTrue(agent.bóveda === m.boveda)
    }

    func test_la_boveda_de_un_modelo_con_almacen_inyectado_usa_ese_almacen() {
        let almacen = AlmacenEnMemoria()
        let m = HarnessModel(almacen: almacen)
        XCTAssertTrue(m.boveda.guarda(name: "pw", value: "v", etiqueta: "Pw", origen: "a.test"))
        XCTAssertEqual(m.boveda.lista().map(\.name), ["pw"])
    }
}
