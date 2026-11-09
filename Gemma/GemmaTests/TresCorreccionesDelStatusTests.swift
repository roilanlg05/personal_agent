import XCTest
@testable import Gemma

/// TRES CORRECCIONES SOBRE «LAS HERRAMIENTAS HABLAN `status`».
///
/// El cambio anterior (ver `HerramientasHablanStatusTests` y
/// `docs/superpowers/notes/2026-11-08-las-herramientas-hablan-status.md`) puso a las ocho
/// herramientas que contestaban en prosa a hablar el contrato `status`. Dejó tres cosas:
///
///  1. **Dos comentarios que afirmaban algo falso.** Justificaban el estado `dry_run` diciendo
///     que «`AtoZConfig` trae el modo simulado activado de fábrica, así que este es el camino
///     NORMAL». Es al revés: el modo simulado es **opt-in**, y por omisión los turnos SÍ se
///     envían a Amazon. El estado se queda —cuando el usuario lo enciende, el único texto
///     honesto es «no se hizo de verdad»— pero la justificación escrita estaba al revés, y un
///     comentario que afirma algo falso es exactamente el defecto que ese trabajo existía para
///     quitar. Esta clase pone la premisa a prueba en
///     `test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica`, para que nadie vuelva a
///     escribirla de memoria.
///  2. **`create_event` y `cancel_events` declaraban un éxito que el bucle no contaba.**
///     Devuelven `created` / `created_with_warnings` / `cancelled`, y `Agent.estadosDeExito`
///     solo tenía `success` y `no_content`: un evento creado correctamente NO reiniciaba el
///     presupuesto de fallos, así que cinco fallos repartidos alrededor de aciertos reales
///     mataban el turno aunque la agenda se hubiera escrito bien. Es el mismo defecto que el
///     trabajo anterior quitó por otra puerta (la prosa), entrando por esta. Se arregló por los
///     dos caminos a la vez, y qué camino le toca a cada estado lo decidió una medida y no el
///     gusto: ver `test_los_exitos_de_create_event_y_cancel_events_reinician_el_presupuesto`.
///  3. **Preguntar la hora pintaba «listo».** `get_current_time` ya hablaba `status`, pero la
///     fila plegada no leía su dato, así que el usuario preguntaba qué hora es y veía «listo».
@MainActor
final class TresCorreccionesDelStatusTests: XCTestCase {

    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "la salida tiene que ser un objeto JSON. got: \(out)")
    }

    private func estado(_ out: String) throws -> String {
        try XCTUnwrap(try json(out)["status"] as? String, "sin `status` legible. got: \(out)")
    }

    private func esFalloEnLaFila(_ out: String, herramienta: String) -> Bool {
        if case .failure = ToolLogRow.summarize(toolName: herramienta, resultJSON: out) { return true }
        return false
    }

    // MARK: - 1. La premisa de `dry_run`, medida en vez de recordada

    /// EL MODO SIMULADO DE A TO Z VIENE **DESACTIVADO** DE FÁBRICA.
    ///
    /// POR QUÉ ESTA PRUEBA EXISTE. El estado `dry_run` se justificó por escrito, en dos sitios
    /// de producción y en el comentario de otra prueba, diciendo que el modo simulado viene
    /// ACTIVADO de fábrica y que por tanto la simulación es el camino normal. Es falso en los
    /// dos únicos sitios que fijan el valor por omisión:
    ///
    ///   - `AtoZSettings.load` lee `d.object(forKey:) as? Bool ?? false`;
    ///   - `SettingsView` declara `@AppStorage(AtoZSettingsKeys.dryRun) private var
    ///     atozDryRun = false`.
    ///
    /// O sea que el camino NORMAL es el REAL: por omisión, una aceptación de turno se envía a
    /// Amazon de verdad. La simulación es opt-in. El estado `dry_run` sigue siendo necesario
    /// —cuando el usuario la enciende, pintar «listo» sería mentirle sobre la herramienta que
    /// le coge turnos de trabajo— pero por la razón correcta.
    ///
    /// UN COMENTARIO NO SE PUEDE EJECUTAR, así que lo que se clava aquí es su PREMISA: el valor
    /// por omisión. Si alguien cambia el valor por omisión, esta prueba se pone roja y el
    /// comentario que depende de ella se revisa.
    func test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica() throws {
        let suite = "TresCorreccionesDelStatusTests.atoz"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }

        // Sin que nadie haya tocado el ajuste: es el estado de fábrica.
        XCTAssertNil(d.object(forKey: AtoZSettingsKeys.dryRun), "la premisa: la clave no está escrita")
        XCTAssertFalse(AtoZSettings.load(d).dryRun,
                       "el modo simulado es OPT-IN: por omisión los turnos se envían a Amazon de verdad")

        // Y cuando el usuario lo enciende, se enciende. La simulación existe, solo no es el
        // camino por omisión.
        d.set(true, forKey: AtoZSettingsKeys.dryRun)
        XCTAssertTrue(AtoZSettings.load(d).dryRun, "encenderlo tiene que encenderlo")

        // Y entonces —y solo entonces— `dry_run` es lo que el usuario lee, porque es la verdad:
        // no se envió nada. Esta mitad es la que justifica que el estado se quede.
        let simulado = AtoZToolOutput.json(.dryRun("Modo simulado (dry-run)."), action: .add)
        XCTAssertEqual(try estado(simulado), "dry_run", "got: \(simulado)")
        XCTAssertTrue(esFalloEnLaFila(simulado, herramienta: "add_shift"),
                      "un turno que NO se pidió a Amazon no puede salir en verde: \(simulado)")
    }

    // MARK: - 2. El éxito de `create_event` y `cancel_events` reinicia el presupuesto

    /// UN EVENTO CREADO Y UNOS EVENTOS CANCELADOS SON ÉXITOS, Y REINICIAN EL PRESUPUESTO.
    ///
    /// EL DEFECTO QUE ARREGLA. `Agent.estadosDeExito` era `["success", "no_content"]`, y las dos
    /// mutaciones de agenda declaraban su éxito con el verbo que su propia descripción le enseña
    /// al modelo a leer: `created`, `created_with_warnings` y `cancelled`. Ninguno estaba en el
    /// conjunto, así que el acierto no borraba la cuenta de fallos anteriores: cinco fallos
    /// repartidos alrededor de eventos creados DE VERDAD mataban el turno.
    ///
    /// SE ARREGLA POR LOS DOS CAMINOS A LA VEZ, Y NO ES INCOHERENCIA: LA MEDIDA DECIDE.
    ///
    /// **`created` y `created_with_warnings` ENTRAN en `estadosDeExito`** porque renombrarlos a
    /// `success` sería un cambio por otro:
    ///   - viajan al MODELO por la descripción de `create_event`, y las DOS ramas tienen que
    ///     seguir distinguiéndose: «'created' = creado y comprobado, ya se lo puedes confirmar»
    ///     frente a «'created_with_warnings' = creado, pero mira 'warnings' … nunca [digas] que
    ///     no choca con nada». Fundirlas en `success` le quita al modelo justo la pieza que le
    ///     impide afirmar que no hay choques;
    ///   - `created` lo emiten otras cinco herramientas (`create_calendar_event`,
    ///     `create_alarm`, `create_note`, `create_reminder`, `add_task`) **con el mismo
    ///     significado** —lo que se pidió crear quedó creado—, así que ampliar el conjunto las
    ///     arregla a las seis de una vez y renombrar solo la de agenda la dejaría hablando
    ///     distinto que sus hermanas;
    ///   - y está afirmado literalmente en una decena de pruebas del repositorio
    ///     (`ScheduleToolsContractTests`, `DateParsingTests`, `PendingDefectsTests`,
    ///     `HybridReminderTests`, `ToolJSONEscapingTests`, `NotesServiceTests`…).
    ///
    /// **`cancelled` NO entra, y `cancel_events` pasa a declarar `success`**, porque el conjunto
    /// se indexa por NOMBRE DE ESTADO y `cancelled` está sobrecargado con el significado
    /// OPUESTO en otras dos herramientas:
    ///   - `cancel_events` y `cancel_alarm`: se canceló lo que se pidió cancelar — un éxito;
    ///   - `run_shortcut` (`RunShortcutTool.swift:93`) y `send_message`
    ///     (`SendMessageTool.swift:115`), los dos por `ShortcutRunOutcome.cancelled`: el USUARIO
    ///     lo descartó, el atajo NO corrió y el mensaje NO se envió. El repositorio lo tiene
    ///     escrito en el nombre de sus pruebas:
    ///     `RunShortcutToolTests.test_run_cancelled_isReportedAsCancelledNotSuccess` y
    ///     `SendMessageToolTests.test_cancelled_isNotReportedAsSent`.
    ///
    /// Meter `cancelled` en el conjunto para arreglar la agenda habría hecho que **un mensaje
    /// que el usuario descartó reiniciara el presupuesto de fallos**: un modelo alternando fallo
    /// y envío descartado nunca agotaría el turno. Y las dos pruebas de arriba habrían seguido
    /// VERDES —afirman la cadena del estado, no el presupuesto—, o sea que el agujero no se
    /// vería. Así que el nombre ambiguo se retira de la herramienta de agenda en vez de
    /// enseñárselo al conjunto. No se pierde nada: `cancelled_count` ya dice cuántos.
    ///
    /// LO QUE NO ENTRA POR NINGÚN CAMINO: `nothing_to_cancel`. Significa «contesté, y no había
    /// nada», que es la categoría que `Agent.estadosDeFallo` deja fuera a propósito y que el
    /// proyecto trata como tercer estado (igual que `not_found`). Ante la duda el estado se
    /// queda fuera, que es la dirección segura escrita en ese conjunto.
    func test_los_exitos_de_create_event_y_cancel_events_reinician_el_presupuesto() async throws {
        // (a) LA FUNCIÓN PURA, que es donde la línea está escrita.
        for estado in ["created", "created_with_warnings", "success"] {
            let resultado = "{\"status\":\"\(estado)\"}"
            XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: resultado),
                          "\(estado) es un éxito y tiene que reiniciar el presupuesto")
            XCTAssertFalse(Agent.esFallo(resultado: resultado), "\(estado) no es un fallo")
            XCTAssertFalse(esFalloEnLaFila(resultado, herramienta: "create_event"),
                           "y la fila no lo pinta en rojo: \(estado)")
        }

        // Y EL NOMBRE AMBIGUO SIGUE FUERA, que es la otra mitad de la decisión. Si alguien lo
        // mete «por simetría» con `created`, un mensaje que el usuario descartó
        // (`send_message` → `ShortcutRunOutcome.cancelled`) empezaría a reiniciar el
        // presupuesto de fallos del turno.
        XCTAssertFalse(Agent.estadosDeExito.contains("cancelled"),
                       "`cancelled` significa «el usuario lo descartó» en run_shortcut y send_message")
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: #"{"status":"cancelled","shortcut":"X"}"#),
                       "un atajo que el usuario descartó no es un acierto del agente")

        // (b) LAS DOS HERRAMIENTAS DE VERDAD, por su camino bueno. No es un estado inventado en
        // la prueba: es lo que `CreateEventTool` y `CancelEventsTool` devuelven hoy.
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            switch req.url?.path {
            case "/v1/nodes": return (200, Data(#"{"nodes":[],"total":0}"#.utf8))
            case "/v1/schedule/create": return (200, Data(#"{"created":true,"id":"e1","conflicts":[]}"#.utf8))
            case "/v1/schedule/cancel": return (200, Data(#"{"cancelled":2}"#.utf8))
            default: return (500, Data("{}".utf8))
            }
        }

        let creado = await CreateEventTool().run(
            argsJSON: #"{"title":"dentista","start":"2099-11-10T08:00","end":"2099-11-10T09:00"}"#)
        XCTAssertEqual(try estado(creado), "created", "got: \(creado)")
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: creado),
                      "un evento creado de verdad borra la cuenta de fallos anteriores: \(creado)")

        let cancelado = await CancelEventsTool().run(
            argsJSON: #"{"from":"2099-11-10T00:00","to":"2099-11-10T23:59"}"#)
        XCTAssertEqual(try estado(cancelado), "success", "got: \(cancelado)")
        XCTAssertEqual(try json(cancelado)["cancelled_count"] as? Int, 2, "got: \(cancelado)")
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: cancelado),
                      "dos eventos cancelados de verdad borran la cuenta de fallos: \(cancelado)")

        // Y la rama de aviso: el evento SÍ se creó aunque la comprobación de choques quedara a
        // medias, así que también reinicia.
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            switch req.url?.path {
            case "/v1/nodes": return (500, Data(#"{"error":"boom"}"#.utf8))
            case "/v1/schedule/create": return (200, Data(#"{"created":true,"id":"e1","conflicts":[]}"#.utf8))
            default: return (500, Data("{}".utf8))
            }
        }
        let conAvisos = await CreateEventTool().run(
            argsJSON: #"{"title":"dentista","start":"2099-11-10T08:00","end":"2099-11-10T09:00"}"#)
        XCTAssertEqual(try estado(conAvisos), "created_with_warnings", "got: \(conAvisos)")
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: conAvisos),
                      "el evento se creó: que la comprobación quedara a medias no lo deshace: \(conAvisos)")

        // (c) LO QUE SIGUE FUERA, declarado aquí para que la ampliación no se lea como «todo
        // verbo cuenta». `nothing_to_cancel` es «contesté, y no había nada»: ni gasta ni
        // reinicia, igual que `not_found`.
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            req.url?.path == "/v1/schedule/cancel" ? (200, Data(#"{"cancelled":0}"#.utf8)) : (500, Data("{}".utf8))
        }
        let nada = await CancelEventsTool().run(
            argsJSON: #"{"from":"2099-11-10T00:00","to":"2099-11-10T23:59"}"#)
        XCTAssertEqual(try estado(nada), "nothing_to_cancel", "got: \(nada)")
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: nada),
                       "no se canceló nada: no es un acierto que borre fallos. got: \(nada)")
        XCTAssertFalse(Agent.esFallo(resultado: nada), "pero tampoco es un fallo: got: \(nada)")

        // (d) Y LOS DOS INVARIANTES DEL CONJUNTO siguen en pie tras la ampliación: ningún
        // estado gasta y reinicia a la vez, y nada que reinicie sale con cruz roja en el chat.
        XCTAssertTrue(Agent.estadosDeFallo.isDisjoint(with: Agent.estadosDeExito))
        for estado in Agent.estadosDeExito {
            XCTAssertFalse(esFalloEnLaFila("{\"status\":\"\(estado)\"}", herramienta: "create_event"),
                           "reinicia el presupuesto y la fila lo pinta como fallo: \(estado)")
        }
    }

    // MARK: - 3. La hora se ve

    /// PREGUNTAR LA HORA ENSEÑA LA HORA, NO «LISTO».
    ///
    /// EL DEFECTO QUE ARREGLA. `get_current_time` empezó a hablar `status` con el cambio
    /// anterior —antes devolvía la fecha a pelo y la fila la pintaba con CRUZ ROJA—, pero
    /// `ToolLogRow.table` no tenía entrada para ella, así que caía en `case nil` y se resumía
    /// como «listo». El usuario pregunta qué hora es y lee «listo».
    ///
    /// POR QUÉ ESTE DATO SÍ SE PINTA, Y NO ES UNA GRIETA EN LA REGLA DE LA TABLA. La regla que
    /// protege esa tabla es que **ningún texto escrito para el modelo llega a la pantalla del
    /// usuario**, y `local_time` no es texto para el modelo: es el dato que el usuario pidió,
    /// formateado por `DateFormatter` con el idioma y el formato del sistema, y no cabe duda
    /// sobre qué significa. El `message` de la herramienta («Ahora son las …») sí está escrito
    /// para el modelo y sigue sin pintarse.
    func test_la_hora_se_ve_en_la_fila_y_no_un_listo() async throws {
        let out = await CurrentTimeTool().run(argsJSON: "{}")
        let hora = try XCTUnwrap(try json(out)["local_time"] as? String, "got: \(out)")
        XCTAssertFalse(hora.isEmpty, "la premisa: la herramienta devuelve la hora. got: \(out)")

        let fila = ToolLogRow.summarize(toolName: CurrentTimeTool.name, resultJSON: out)
        XCTAssertEqual(fila, .value(hora),
                       "la fila tiene que enseñar la hora que el usuario pidió, no «listo». got: \(fila)")

        // Y NO EL TEXTO DEL MODELO. El `message` dice «Ahora son las …»: es una instrucción
        // redactada para el modelo y no puede ser lo que se lee de un vistazo.
        guard case .value(let pintado) = fila else {
            return XCTFail("got: \(fila)")
        }
        XCTAssertFalse(pintado.contains("Ahora son"),
                       "el texto escrito para el modelo no llega a la pantalla: \(pintado)")

        // Si un día la herramienta deja de mandar el dato, la fila no puede romperse ni mentir:
        // vuelve a «listo», que dice menos pero no afirma nada falso.
        let sinDato = #"{"status":"success"}"#
        XCTAssertEqual(ToolLogRow.summarize(toolName: CurrentTimeTool.name, resultJSON: sinDato), .ok,
                       "sin el dato, la fila no inventa ninguna hora")
    }
}
