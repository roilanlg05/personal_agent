import XCTest
@testable import Gemma

/// LAS HERRAMIENTAS QUE CONTESTABAN EN PROSA AHORA HABLAN EL CONTRATO `status`.
///
/// EL DEFECTO QUE ARREGLA, Y SON DOS MENTIRAS EN DIRECCIONES OPUESTAS. Ocho de las ochenta
/// herramientas registradas devolvían su resultado en PROSA, no en un objeto JSON con `status`.
/// De ahí salían dos textos falsos en la pantalla del usuario y un parche en el bucle:
///
///  1. **Un éxito salía con CRUZ ROJA.** `ToolLogRow.summarize` empieza por parsear el
///     resultado; lo que no es un objeto JSON cae en la rama de fallo. `forget` contestaba
///     «Forgot 3 item(s) matching 'x'.» —tres recuerdos olvidados de verdad— y la fila lo
///     pintaba en rojo. Igual `save_memory`, `reflect`, `get_current_time`, `update_event` y las
///     tres de A to Z.
///  2. **Un error salía con TILDE VERDE y «listo».** `ToolJSONOutput.error(_:)` emitía
///     `{"error": …}`: un objeto JSON **sin** `status`, así que no entraba en la rama de fallo,
///     caía en `case nil` y se resumía como «listo». Es el camino de las guardas de argumentos
///     de media app y lo dispara el modelo llamando con los argumentos mal. Era la peor de las
///     dos: un error pintado como éxito hace que el usuario crea que algo pasó.
///  3. **Y el presupuesto de fallos tuvo que aceptar la prosa como éxito** para no matar turnos
///     en los que `forget` había funcionado — con el precio, declarado en su día, de que un
///     FALLO en prosa («memory unavailable») también reiniciaba. Con las ocho hablando `status`
///     ese precio deja de hacer falta: ver
///     `test_el_presupuesto_ya_no_reinicia_con_prosa_porque_no_queda_ninguna_que_la_hable`.
///
/// Las tres las arregla el mismo cambio, y esta clase lo mide por el sitio por el que el usuario
/// lo nota: lo que `ToolLogRow.summarize` pinta y lo que `Agent` cuenta.
@MainActor
final class HerramientasHablanStatusTests: XCTestCase {

    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        MemoryToolbox.shared.reflectionRequest = nil
        super.tearDown()
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "la salida tiene que ser un objeto JSON. got: \(out)")
    }

    private func estado(_ out: String) throws -> String {
        try XCTUnwrap(try json(out)["status"] as? String, "sin `status` legible. got: \(out)")
    }

    // MARK: - El censo, recorrido por los dos caminos que cualquiera puede alcanzar

    /// LAS OCHO DEL CENSO DEVUELVEN UN OBJETO JSON CON `status` LEGIBLE.
    ///
    /// Se recorren por el camino que no necesita ni red ni permisos del sistema: la guarda de
    /// argumentos y el «el servicio no está». Son los dos caminos que el modelo alcanza a diario
    /// (llamar con los argumentos mal, y el servicio de memoria del i3 al otro lado de
    /// Tailscale), así que no son un caso de laboratorio.
    ///
    /// `get_current_time` y `reflect` no tienen guarda ninguna: su único camino es el bueno.
    func test_las_ocho_que_hablaban_prosa_devuelven_json_con_status_legible() async throws {
        var salidas: [(String, String)] = []

        // Guardas de argumentos (sin cliente de memoria, sin red).
        salidas.append(("forget", await ForgetTool().run(argsJSON: #"{"query":""}"#)))
        salidas.append(("save_memory", await SaveMemoryTool().run(argsJSON: #"{"entity":"   "}"#)))
        salidas.append(("add_shift", await AddShiftTool().run(argsJSON: #"{}"#)))
        salidas.append(("drop_shift", await DropShiftTool().run(argsJSON: #"{}"#)))
        salidas.append(("update_event", await UpdateEventTool().run(argsJSON: #"{}"#)))
        // La memoria no responde.
        salidas.append(("forget", await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)))
        salidas.append(("save_memory", await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi"}"#)))
        salidas.append(("update_event", await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00"}"#)))
        // Sin guarda: el camino bueno es el único.
        salidas.append(("reflect", await ReflectTool().run(argsJSON: "{}")))
        salidas.append(("get_current_time", await CurrentTimeTool().run(argsJSON: "{}")))

        for (nombre, out) in salidas {
            let estado = try self.estado(out)
            XCTAssertFalse(estado.isEmpty, "\(nombre): `status` vacío. got: \(out)")
            // Y lo que el usuario lee de esa fila nunca es la rama de «ilegible», que es la que
            // pintaba un éxito en rojo con el texto de la herramienta dentro.
            let fila = ToolLogRow.summarize(toolName: nombre, resultJSON: out)
            if case .failure(let texto) = fila {
                XCTAssertEqual(texto, ToolLogRow.fraseDeFallo(status: estado),
                               "\(nombre): la fila pinta texto de la herramienta y no la frase de la app. got: \(out)")
            }
        }
    }

    /// UN ÉXITO DE LAS QUE HABLABAN PROSA YA NO SALE CON CRUZ ROJA.
    ///
    /// Es el defecto 1 medido por el sitio por el que el usuario lo ve. `reflect` y
    /// `get_current_time` no necesitan nada para tener éxito, y `forget` llega a su éxito con un
    /// doble del servicio de memoria, así que las tres se miden de verdad y no por su forma.
    func test_un_exito_de_las_que_hablaban_prosa_ya_no_sale_con_cruz_roja() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            if req.url?.path == "/v1/nodes" { return (200, Data(#"{"nodes":[],"total":0}"#.utf8)) }
            return (200, Data(#"{"removed":3}"#.utf8))
        }
        let exitos: [(String, String)] = [
            ("reflect", await ReflectTool().run(argsJSON: "{}")),
            ("get_current_time", await CurrentTimeTool().run(argsJSON: "{}")),
            ("forget", await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)),
        ]
        for (nombre, out) in exitos {
            XCTAssertEqual(try estado(out), "success", "\(nombre) got: \(out)")
            let fila = ToolLogRow.summarize(toolName: nombre, resultJSON: out)
            if case .failure = fila { XCTFail("\(nombre): un éxito con cruz roja. \(fila) <- \(out)") }
            // Y reinicia el presupuesto por el CONTRATO, no por ser ilegible.
            XCTAssertTrue(Agent.esExito(resultado: out), "\(nombre): su éxito no se declara. got: \(out)")
        }
    }

    /// LO QUE `forget` LE DICE AL USUARIO SIGUE SIENDO CUÁNTOS OLVIDÓ.
    ///
    /// La prueba vieja (`ForgetToolTests.test_forget_calls_endpoint_and_returns_count`) protegía
    /// esto afirmando la cadena «Forgot 3 item(s)» con un `contains("3")`. La propiedad no era la
    /// cadena: era que el número viaje. Ahora viaja en una clave que el modelo puede leer sin
    /// interpretar prosa.
    func test_forget_dice_cuantos_olvido_en_una_clave_y_no_en_una_frase() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            if req.url?.path == "/v1/nodes" { return (200, Data(#"{"nodes":[],"total":0}"#.utf8)) }
            XCTAssertEqual(req.url?.path, "/v1/memory/forget")
            return (200, Data(#"{"removed":3}"#.utf8))
        }
        let out = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertEqual(try json(out)["forgotten_count"] as? Int, 3, "got: \(out)")
        XCTAssertEqual(try estado(out), "success", "got: \(out)")
    }

    /// Y CUANDO NO OLVIDÓ NADA NO DICE «LISTO». Es la mitad que sostiene la de arriba: una
    /// implementación que contestara `success` a todo pasaría la anterior y moriría aquí. El
    /// usuario pidió olvidar algo que no estaba: lo honesto es que la fila NO diga que se hizo.
    func test_forget_que_no_encuentra_nada_no_se_pinta_como_hecho() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            if req.url?.path == "/v1/nodes" { return (200, Data(#"{"nodes":[],"total":0}"#.utf8)) }
            return (200, Data(#"{"removed":0}"#.utf8))
        }
        let out = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertEqual(try estado(out), "not_found", "got: \(out)")
        XCTAssertTrue(ToolLogRow.failureStatuses.contains("not_found"))
    }

    // MARK: - Defecto 2: la guarda de argumentos salía en verde

    /// `ToolJSONOutput.error(_:)` DECLARA SU ESTADO.
    ///
    /// Es el camino de las guardas de argumentos de medio registro (53 sitios de llamada). Sin
    /// `status`, `summarize` caía en `case nil` y pintaba «listo» con su tilde verde sobre un
    /// error: la mentira que hace que el usuario crea que algo pasó.
    ///
    /// LA CLAVE `error` SE QUEDA. Una veintena de pruebas de todo el registro la leen para
    /// comprobar que el motivo viajó entero, y `status` no la sustituye: dicen cosas distintas.
    func test_la_guarda_de_argumentos_declara_error_y_ya_no_sale_en_verde() throws {
        let out = ToolJSONOutput.error("Se requiere 'name' con el nombre del atajo.")
        XCTAssertEqual(try estado(out), "error", "got: \(out)")
        XCTAssertEqual(try json(out)["error"] as? String, "Se requiere 'name' con el nombre del atajo.",
                       "el motivo entero se queda donde el resto del registro lo lee: \(out)")

        let fila = ToolLogRow.summarize(toolName: "forget_shortcut", resultJSON: out)
        guard case .failure(let texto) = fila else {
            return XCTFail("un error de argumentos no puede salir con tilde verde: \(fila)")
        }
        XCTAssertEqual(texto, ToolLogRow.fraseDeFallo(status: "error"),
                       "y lo que se pinta es la frase de la app, no el texto escrito para el modelo")
        XCTAssertFalse(texto.contains("Se requiere"), "ni el texto del modelo en la pantalla: \(texto)")

        // Y el bucle ya puede contarlo: antes era el tercer estado («no se supo leer»).
        XCTAssertTrue(Agent.esFallo(resultado: out), "got: \(out)")
    }

    // MARK: - A to Z: la traducción pura de sus cinco resultados

    /// LAS CINCO FORMAS DE `add_shift`/`drop_shift` TIENEN SU ESTADO, Y UNA SIMULACIÓN NO ES UN
    /// ÉXITO.
    ///
    /// El modo simulado es OPT-IN: viene DESACTIVADO por omisión (`AtoZSettings.load` lo lee
    /// como `?? false`, `SettingsView` lo declara `= false`), así que el camino normal de una
    /// aceptación de turno es el REAL y la petición sí llega a Amazon. `.dryRun` es el camino
    /// del usuario que ENCENDIÓ la simulación en Ajustes: se validó todo y **no se envió nada a
    /// Amazon**. Pintar eso como «listo» es exactamente la queja del usuario —que el agente le
    /// cuente que hizo cosas que no hizo— sobre la herramienta que más le importa, la que le
    /// coge turnos de trabajo. Va con cruz roja y su frase propia. La premisa del valor por
    /// omisión la clava `TresCorreccionesDelStatusTests
    /// .test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica`.
    func test_los_cinco_resultados_de_a_to_z_declaran_su_estado() throws {
        let turno = "sábado 8 de noviembre de 2026, 09:00–13:00"
        let casos: [(AtoZToolOutput.Outcome, String)] = [
            (.confirmationRequired("¿Confirmas…?"), "confirmation_required"),
            (.dryRun("Modo simulado (dry-run): se validó la confirmación."), "dry_run"),
            (.confirmed(turno), "success"),
            (.unknownOutcome(turno, "la verificación no respondió"), "unknown"),
            (.failed(.notConfigured), "failed"),
        ]
        for (outcome, esperado) in casos {
            for accion in [AtoZToolOutput.Action.add, .drop] {
                let out = AtoZToolOutput.json(outcome, action: accion)
                XCTAssertEqual(try estado(out), esperado, "\(outcome) / \(accion) -> \(out)")
            }
        }

        // UNA SIMULACIÓN NO SE PINTA COMO HECHA, y su frase no es la genérica.
        let simulado = AtoZToolOutput.json(.dryRun("Modo simulado (dry-run)."), action: .add)
        let fila = ToolLogRow.summarize(toolName: "add_shift", resultJSON: simulado)
        guard case .failure(let texto) = fila else {
            return XCTFail("un turno que NO se pidió a Amazon no puede salir en verde: \(fila)")
        }
        XCTAssertEqual(texto, ToolLogRow.fraseDeFallo(status: "dry_run"))
        XCTAssertNotEqual(texto, "falló", "la simulación tiene su propia frase: no se rompió nada")
        XCTAssertTrue(ToolLogRow.failureStatuses.contains("dry_run"),
                      "si no está en el censo, la fila sale en verde")
        // Pero NO mata el turno: no pudo hacerse, pero tampoco es una avería que haya que
        // dejar de intentar. Es el criterio escrito en `Agent.estadosDeFallo`.
        XCTAssertFalse(Agent.estadosDeFallo.contains("dry_run"),
                       "el conjunto que mata turnos es más estrecho a propósito")

        // Y un turno aceptado DE VERDAD sí sale en verde y reinicia el presupuesto.
        let hecho = AtoZToolOutput.json(.confirmed(turno), action: .add)
        if case .failure = ToolLogRow.summarize(toolName: "add_shift", resultJSON: hecho) {
            XCTFail("un turno aceptado y verificado es un éxito: \(hecho)")
        }
        XCTAssertTrue(Agent.esExito(resultado: hecho), "got: \(hecho)")
        XCTAssertTrue(hecho.contains(turno), "el turno sigue nombrado para el modelo: \(hecho)")
    }

    /// `list_available_shifts` cuenta los turnos, y una lista vacía es un éxito sin nada que
    /// contar (`no_content`), no un fallo: la consulta funcionó.
    func test_list_available_shifts_cuenta_los_turnos_y_el_vacio_no_es_un_fallo() throws {
        let inicio = Date(timeIntervalSince1970: 1_800_000_000)
        let turno = AtoZShiftOpportunity(id: "amzn.ls.op1", type: "VOLUNTARY_EXTRA_TIME",
                                        start: inicio, end: inicio.addingTimeInterval(4 * 3600),
                                        isEligible: true, unclaimableReasonCodes: [])
        let conTurnos = AtoZToolOutput.listJSON([turno])
        XCTAssertEqual(try estado(conTurnos), "success", "got: \(conTurnos)")
        XCTAssertEqual(try json(conTurnos)["count"] as? Int, 1, "got: \(conTurnos)")
        XCTAssertTrue(conTurnos.contains("amzn.ls.op1"),
                      "el id tiene que seguir ahí: es lo que `add_shift` necesita. got: \(conTurnos)")

        let vacio = AtoZToolOutput.listJSON([])
        XCTAssertEqual(try estado(vacio), "no_content", "got: \(vacio)")
        XCTAssertTrue(Agent.esExito(resultado: vacio), "una consulta que funcionó no gasta presupuesto")
        if case .failure = ToolLogRow.summarize(toolName: "list_available_shifts", resultJSON: vacio) {
            XCTFail("«no hay turnos» no es un fallo: \(vacio)")
        }
    }

    // MARK: - `update_event`, la que el censo heredado no vio

    /// `update_event` ERA LA SÉPTIMA, Y ES UNA MUTACIÓN DE LA AGENDA.
    ///
    /// SP1 (`ScheduleToolSupport`) se escribió justo para que estas herramientas hablaran
    /// `status` —su defecto 6 dice literalmente «Nada de esto tenía `status`. Devolvían prosa en
    /// inglés que el modelo tenía que interpretar»— y `update_event` se quedó fuera. Sus cuatro
    /// hermanas (`check_schedule`, `create_event`, `query_schedule`, `cancel_events`) viven en
    /// el mismo fichero y todas lo hablan.
    ///
    /// Los cuatro resultados que el servidor distingue, cada uno con el estado que ya usan sus
    /// hermanas: no encontrado, ambiguo, choque y hecho.
    func test_update_event_declara_sus_cuatro_resultados() async throws {
        func corre(_ respuesta: String, _ args: String = #"{"start":"2099-06-09T15:00","title":"meeting"}"#) async -> String {
            MemoryToolbox.shared.memory = makeStubMemoryClient { _ in (200, Data(respuesta.utf8)) }
            return await UpdateEventTool().run(argsJSON: args)
        }

        let noEsta = await corre(#"{"updated":false,"notFound":true}"#)
        XCTAssertEqual(try estado(noEsta), "not_found", "got: \(noEsta)")

        let varios = await corre(#"{"updated":false,"ambiguous":[{"id":"a","title":"meeting","start":3000,"end":3600,"allDay":false,"status":"scheduled"},{"id":"b","title":"meeting","start":3000,"end":3600,"allDay":false,"status":"scheduled"}]}"#)
        XCTAssertEqual(try estado(varios), "ambiguous", "got: \(varios)")

        let choca = await corre(#"{"updated":false,"conflicts":[{"id":"d","title":"dentist","start":3000,"end":3600,"allDay":false,"status":"scheduled"}]}"#)
        XCTAssertEqual(try estado(choca), "conflict", "got: \(choca)")
        XCTAssertTrue(choca.contains("dentist"),
                      "con qué choca sigue viajando al modelo: sin eso no puede preguntar. got: \(choca)")

        let hecho = await corre(#"{"updated":true,"event":{"id":"x","title":"meeting","start":9000,"end":9600,"allDay":false,"location":"Miami","status":"scheduled"}}"#)
        XCTAssertEqual(try estado(hecho), "success", "got: \(hecho)")
        XCTAssertTrue(hecho.contains("Miami"), "el evento cambiado se devuelve entero: \(hecho)")
        XCTAssertTrue(Agent.esExito(resultado: hecho), "una mutación que salió bien reinicia el presupuesto")
    }

    /// Y la guarda: sin `start` no se adivina ningún evento. Se distingue «no lo mandaste» de
    /// «no se entiende», igual que hacen sus hermanas con `ScheduleRange`.
    func test_update_event_distingue_el_argumento_que_falta_del_que_no_se_entiende() async throws {
        let falta = await UpdateEventTool().run(argsJSON: #"{}"#)
        XCTAssertEqual(try estado(falta), "missing_fields", "got: \(falta)")

        let ilegible = await UpdateEventTool().run(argsJSON: #"{"start":"el martes por la tarde"}"#)
        XCTAssertEqual(try estado(ilegible), "invalid_datetime", "got: \(ilegible)")
        XCTAssertEqual(try json(ilegible)["received"] as? String, "el martes por la tarde",
                       "un fallo de formato tiene que ser diagnosticable: \(ilegible)")
    }

    // MARK: - Defecto 3: el precio que el presupuesto pagaba

    /// EL PRESUPUESTO YA NO REINICIA CON PROSA, PORQUE NO QUEDA NINGUNA HERRAMIENTA QUE LA HABLE.
    ///
    /// `reiniciaElPresupuesto` aceptaba «no es un objeto JSON» como éxito para no matar turnos en
    /// los que `forget` había funcionado de verdad. El precio, declarado entonces en el código:
    /// un FALLO en prosa («memory unavailable», que es lo que `forget` contestaba cuando el
    /// servicio no estaba) también reiniciaba, y el presupuesto se quedaba sin dientes justo
    /// contra el turno que de verdad no avanza.
    ///
    /// Con las ocho hablando `status` la prosa ya no es la voz de ninguna herramienta registrada,
    /// así que el reinicio vuelve a ser el contrato y nada más. LAS DOS MITADES EN LA MISMA
    /// FUNCIÓN: el fallo en prosa ya no reinicia, y el éxito de `forget` —el caso que obligó al
    /// parche— sigue reiniciando, ahora por la puerta buena.
    func test_el_presupuesto_ya_no_reinicia_con_prosa_porque_no_queda_ninguna_que_la_hable() async throws {
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: "memory unavailable"),
                       "un fallo en prosa no puede reiniciar el presupuesto")
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: "Forgot 3 item(s) matching 'x'."),
                       "ni la prosa que ninguna herramienta registrada habla ya")

        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            if req.url?.path == "/v1/nodes" { return (200, Data(#"{"nodes":[],"total":0}"#.utf8)) }
            return (200, Data(#"{"removed":3}"#.utf8))
        }
        let exito = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: exito),
                      "el caso que obligó al parche sigue cubierto, por el contrato: \(exito)")

        // Y la memoria caída, que es el caso cotidiano del i3 al otro lado de Tailscale, ahora
        // se cuenta como lo que es.
        MemoryToolbox.shared.memory = nil
        let caida = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertEqual(try estado(caida), "memory_unavailable", "got: \(caida)")
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: caida), "got: \(caida)")
        XCTAssertTrue(Agent.esFallo(resultado: caida), "got: \(caida)")
    }
}
