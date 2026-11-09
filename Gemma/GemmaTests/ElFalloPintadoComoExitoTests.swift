import XCTest
@testable import Gemma

/// EL FALLO PINTADO COMO ÉXITO, QUE ES LA PEOR DE LAS DOS MENTIRAS DE LA FILA.
///
/// La queja número uno del usuario es que el agente le cuenta que hizo cosas que no hizo. De las
/// dos direcciones en las que la fila del chat puede mentir —un éxito con cruz roja, y un fallo
/// con tilde verde— esta clase persigue la segunda: la que le hace **creer que algo pasó**.
///
/// Dos defectos, encontrados por un censo sobre las ochenta herramientas del registro
/// (`docs/superpowers/notes/2026-11-08-tres-correcciones-del-status.md`):
///
///  1. **`play_music`**. Su `status` NO es un literal: sale del `rawValue` de
///     `MusicPlaybackOutcome` (`MusicService.swift`), así que **ningún censo de literales lo
///     ve** —ni el grep plano ni el recorrido por el cuerpo de `run`—. Leído a mano, el enum
///     tiene cinco casos, y tres estaban mal contados por la fila:
///     `app_unavailable` («la app de música no está instalada») caía en `case nil` y se resumía
///     **«listo» con tilde verde**; y `search_opened` / `launching` —«se abrió, pero no está
///     sonando»— también decían **«listo»**, justo lo que la descripción de la herramienta le
///     PROHÍBE afirmar al modelo («no afirmes que la música suena si es 'search_opened'»). O
///     sea: el modelo estaba advertido y el usuario no.
///  2. **`get_device_status`**. La única de las ochenta cuyo `run` no emitía NINGÚN `status`.
///     Mentía por omisión —su fila caía en `case nil` y decía «listo»— y, peor, su éxito
///     **nunca reiniciaba el presupuesto de fallos** del turno, porque
///     `Agent.reiniciaElPresupuesto` exige un `status` de `Agent.estadosDeExito`: preguntar por
///     la batería no borraba los fallos anteriores y acercaba el turno a morir.
///
/// LO QUE ESTA CLASE **NO** TOCA, Y ES DELIBERADO. Los veintidós estados de éxito huérfanos del
/// censo (`ok` en veintiuna herramientas, `empty`, `deleted`, `updated`, `playing`…) siguen
/// fuera de `Agent.estadosDeExito`. La razón está medida en el informe anterior: el NOMBRE del
/// estado no basta para decidir. `cancelled` significa «éxito» en `cancel_events` y
/// `cancel_alarm` y significa «el usuario lo descartó y NO se envió» en `run_shortcut` y
/// `send_message`, así que meterlo por nombre haría que **un mensaje descartado reiniciara el
/// presupuesto**. Eso pide una decisión por PAR (herramienta, estado), que es un cambio de
/// diseño y no de este arreglo.
@MainActor
final class ElFalloPintadoComoExitoTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "la salida tiene que ser un objeto JSON. got: \(out)")
    }

    private func estado(_ out: String) throws -> String {
        try XCTUnwrap(try json(out)["status"] as? String, "sin `status` legible. got: \(out)")
    }

    private func esFallo(_ r: ToolRowSummary) -> Bool {
        if case .failure = r { return true }
        return false
    }

    /// `play_music` con la app de música ausente, por su camino REAL.
    /// `MockAppURLOpener(supportedSchemes: ["music"])` + `platform: spotify` = el esquema de
    /// Spotify no se reconoce, o sea la app no está instalada (`MusicService.swift`, rama
    /// `outcome: .appUnavailable`).
    private func salidaDeAppAusente() async -> String {
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let tool = PlayMusicTool(musicService: MusicService(
            urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0))
        return await tool.run(argsJSON: #"{"query": "reggaeton", "type": "genre", "platform": "spotify"}"#)
    }

    /// `play_music` que solo consigue abrir el BUSCADOR: el usuario tiene que elegir y nada
    /// suena. Un artista en texto libre no es un recurso reproducible.
    private func salidaDeBuscadorAbierto() async -> String {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let tool = PlayMusicTool(musicService: MusicService(
            urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0))
        return await tool.run(argsJSON: #"{"query": "Bad Bunny", "type": "artist", "platform": "spotify"}"#)
    }

    /// `play_music` que abrió el recurso en la app pero NO pudo comprobar que esté sonando
    /// (sin controlador de la app no hay verificación posible: solo esquema URL).
    private func salidaDeAberturaSinVerificar() async -> String {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let tool = PlayMusicTool(musicService: MusicService(
            urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0))
        return await tool.run(argsJSON: #"{"query": "reggaeton", "type": "genre", "platform": "spotify"}"#)
    }

    // MARK: - 1 — `app_unavailable` es un FALLO y sale con cruz roja

    /// EL DEFECTO, MEDIDO POR DONDE EL USUARIO LO VE. `ToolLogRow.failureStatuses` tenía
    /// `not_available` y **no** `app_unavailable`, que es otro estado y de otra familia (lo
    /// construye `MusicPlaybackOutcome`, no `ShortcutRunOutcome`). «La app de música no está
    /// instalada» salía con tilde verde y «listo»: nada sonó y el usuario leyó que sí.
    ///
    /// LAS TRES MITADES, en la misma función, para que ninguna se cumpla sola:
    ///  (a) la herramienta de verdad, por su camino real, declara `app_unavailable`;
    ///  (b) la fila lo pinta como FALLO;
    ///  (c) y lo que pinta es la frase de la APP, no el `message` de la herramienta —que está
    ///      redactado para el modelo— ni el `status` repetido en crudo.
    func test_la_app_de_musica_que_no_esta_sale_con_cruz_roja_y_no_con_un_listo() async throws {
        let out = await salidaDeAppAusente()
        XCTAssertEqual(try estado(out), "app_unavailable", "got: \(out)")

        let fila = ToolLogRow.summarize(toolName: PlayMusicTool.name, resultJSON: out)
        XCTAssertTrue(esFallo(fila),
                      "nada sonó: la fila no puede decir «listo» con tilde verde. got: \(fila)")
        guard case .failure(let texto) = fila else { return }

        XCTAssertEqual(texto, ToolLogRow.fraseDeFallo(status: "app_unavailable"),
                       "lo que se pinta es la frase fija del estado")
        XCTAssertNotEqual(texto, "falló",
                          "no cae en el genérico: este estado tiene un motivo concreto que decirle")
        XCTAssertFalse(texto.contains("app_unavailable"), "ni el estado en crudo: \(texto)")
        let mensajeParaElModelo = try XCTUnwrap(try json(out)["message"] as? String, "got: \(out)")
        XCTAssertNotEqual(texto, mensajeParaElModelo,
                          "el `message` está escrito para el MODELO y no llega a la pantalla")

        // Y el censo lo contiene de verdad, no solo esta llamada: añadirlo a mano aquí sin
        // tocar el conjunto dejaría al resto de la app (y a `ToolLogRowTests`) sin verlo.
        XCTAssertTrue(ToolLogRow.failureStatuses.contains("app_unavailable"),
                      "el estado entra en el censo que pinta la cruz roja")
    }

    // MARK: - 2 — «se abrió, pero no está sonando» no es ni fallo ni «listo»

    /// EL DEFECTO: `search_opened` y `launching` decían **«listo»**. Y la descripción de la
    /// propia herramienta le dice al modelo «no afirmes que la música suena si es
    /// 'search_opened'» — o sea que el modelo estaba advertido y el usuario leía lo contrario.
    ///
    /// NO SON UN FALLO: la herramienta hizo lo que pudo, y pintarlos en rojo le diría que algo
    /// se rompió. Lo honesto es el tercer texto, el que ya existe para `browser_close` +
    /// `refused` (`cierreRechazadoText`): un `.value` con una frase de la app que dice
    /// exactamente qué pasó.
    func test_la_musica_que_se_abrio_pero_no_suena_no_dice_ni_listo_ni_que_fallo() async throws {
        let casos: [(String, String)] = [
            ("search_opened", await salidaDeBuscadorAbierto()),
            ("launching", await salidaDeAberturaSinVerificar()),
        ]
        for (esperado, out) in casos {
            XCTAssertEqual(try estado(out), esperado, "got: \(out)")

            let fila = ToolLogRow.summarize(toolName: PlayMusicTool.name, resultJSON: out)
            XCTAssertFalse(esFallo(fila), "\(esperado): no se rompió nada. got: \(fila)")
            XCTAssertNotEqual(fila, .ok,
                              "\(esperado): «listo» afirma que la música suena, y no suena")
            guard case .value(let texto) = fila else {
                return XCTFail("\(esperado): se espera la frase de la app. got: \(fila)")
            }
            XCTAssertEqual(texto,
                           ToolLogRow.fraseDeEstadoAMedias(toolName: PlayMusicTool.name, status: esperado),
                           "\(esperado): lo que se pinta es la frase fija del par")
            XCTAssertTrue(texto.contains("no está sonando"),
                          "\(esperado): la frase tiene que decir que no suena. got: \(texto)")
            let mensajeParaElModelo = try XCTUnwrap(try json(out)["message"] as? String, "got: \(out)")
            XCTAssertNotEqual(texto, mensajeParaElModelo,
                              "\(esperado): el `message` está escrito para el modelo")
            XCTAssertLessThanOrEqual(texto.count, ToolLogRow.messageLimit, texto)
        }
    }

    /// LA MITAD QUE SOSTIENE LA DE ARRIBA, Y ES LA LECCIÓN DE `cancelled`. La frase se decide
    /// por el PAR (herramienta, estado) y no por el nombre del estado suelto, que es lo que
    /// convirtió `cancelled` en una trampa. Hoy los tres estados de `MusicPlaybackOutcome` son
    /// exclusivos de `play_music` —medido con un grep sobre todo el árbol—, pero el día en que
    /// otra herramienta estrene un `launching` que signifique otra cosa, esta tabla no se lo
    /// aplicará por el nombre.
    func test_la_frase_es_del_par_y_no_del_nombre_del_estado_suelto() {
        XCTAssertNotNil(ToolLogRow.fraseDeEstadoAMedias(toolName: PlayMusicTool.name, status: "launching"))
        XCTAssertNil(ToolLogRow.fraseDeEstadoAMedias(toolName: "browser_open", status: "launching"),
                     "otra herramienta con el mismo nombre de estado no hereda la frase")
        XCTAssertNil(ToolLogRow.fraseDeEstadoAMedias(toolName: PlayMusicTool.name, status: "playing"),
                     "la música que SÍ suena no es un estado a medias")
        XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_open",
                                            resultJSON: #"{"status":"launching","url":"https://x.test/a"}"#),
                       .value("x.test"),
                       "y la fila de esa otra herramienta sigue por su propio camino")
    }

    // MARK: - 3 — `get_device_status` habla el contrato

    /// EL DEFECTO: era la ÚNICA de las ochenta herramientas del registro cuyo `run` no emitía
    /// `status`. La consecuencia que no se ve en la pantalla es la peor: su éxito no reiniciaba
    /// el presupuesto de fallos consecutivos del turno, así que preguntar por la batería no
    /// borraba los fallos anteriores y acercaba el turno a morir.
    ///
    /// Declara `success`, que es el estado del contrato que `Agent.estadosDeExito` ya conoce.
    /// **No** un verbo propio (`ok`): `ok` es hoy un éxito HUÉRFANO en veintiuna herramientas y
    /// meterlo en el conjunto es justo el cambio por nombre que el hallazgo de `cancelled`
    /// prohíbe.
    func test_get_device_status_declara_su_exito_y_reinicia_el_presupuesto() async throws {
        let provider = MockDeviceStatusProvider(deviceType: "iPhone", batteryPercent: 73, isCharging: false)
        let out = await GetDeviceStatusTool(service: DeviceStatusService(provider: provider)).run(argsJSON: "{}")

        XCTAssertEqual(try estado(out), "success", "got: \(out)")
        XCTAssertTrue(Agent.esExito(resultado: out),
                      "su éxito tiene que declararse donde el bucle lo lee. got: \(out)")
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: out),
                      "preguntar por la batería borra los fallos anteriores del turno. got: \(out)")
        XCTAssertFalse(Agent.esFallo(resultado: out), "y no gasta presupuesto. got: \(out)")

        // Y el dato que ya emitía sigue intacto: el contrato se añade, no sustituye.
        XCTAssertEqual(try json(out)["battery_percent"] as? Int, 73, "got: \(out)")
        XCTAssertEqual(try json(out)["battery_level_known"] as? Bool, true, "got: \(out)")
    }

    /// LA BATERÍA SE VE. Un porcentaje de batería es un dato que el usuario pidió y sobre cuyo
    /// significado no cabe duda, que es la regla escrita encima de `ToolLogRow.table`. Lo que
    /// **no** entra es el `summary` («Tu iPhone tiene 73% de batería (…)»), que está redactado
    /// para el modelo.
    ///
    /// LAS TRES MITADES: se pinta el dato; no se pinta el texto del modelo; y sin el dato se
    /// cae a «listo» sin inventar ninguna cifra —que es el defecto 9 que `DeviceStatusHonesty
    /// Tests` ya protege en la salida de la herramienta, aquí extendido a la fila—.
    func test_la_bateria_se_ve_en_la_fila_y_no_un_listo() async throws {
        let conDato = MockDeviceStatusProvider(deviceType: "iPhone", batteryPercent: 73, isCharging: false)
        let out = await GetDeviceStatusTool(service: DeviceStatusService(provider: conDato)).run(argsJSON: "{}")
        let fila = ToolLogRow.summarize(toolName: GetDeviceStatusTool.name, resultJSON: out)

        XCTAssertEqual(fila, .value("73%"),
                       "el usuario preguntó cuánta batería le queda y tiene que leerla. got: \(fila)")
        let textoParaElModelo = try XCTUnwrap(try json(out)["summary"] as? String, "got: \(out)")
        XCTAssertNotEqual(fila, .value(textoParaElModelo),
                          "el `summary` está redactado para el modelo y no llega a la pantalla")

        let sinDato = MockDeviceStatusProvider(deviceType: "iPhone", batteryPercent: nil, isCharging: true)
        let aCiegas = await GetDeviceStatusTool(service: DeviceStatusService(provider: sinDato)).run(argsJSON: "{}")
        XCTAssertEqual(ToolLogRow.summarize(toolName: GetDeviceStatusTool.name, resultJSON: aCiegas), .ok,
                       "sin medición la fila dice menos, pero no inventa un porcentaje. got: \(aCiegas)")
    }

    // MARK: - El guardia de lo que NO se tocó

    /// LOS VEINTIDÓS ÉXITOS HUÉRFANOS SIGUEN FUERA, y esta prueba existe para que el siguiente
    /// que los mire tenga que leer la razón antes de meterlos. No es una prueba de un arreglo:
    /// es el candado de una decisión medida.
    ///
    /// `cancelled` es la prueba de que el nombre no basta: `cancel_alarm` lo emite como éxito y
    /// `run_shortcut` / `send_message` lo emiten cuando **el usuario descartó la acción y no se
    /// ejecutó**. Meterlo por nombre haría que un mensaje descartado reiniciara el presupuesto,
    /// y las dos pruebas que deberían cazarlo
    /// (`RunShortcutToolTests.test_run_cancelled_isReportedAsCancelledNotSuccess`,
    /// `SendMessageToolTests.test_cancelled_isNotReportedAsSent`) **seguirían verdes**, porque
    /// afirman la cadena del estado y no el presupuesto.
    func test_los_exitos_huerfanos_del_censo_siguen_fuera_del_presupuesto() {
        for huerfano in ["ok", "empty", "deleted", "updated", "cancelled", "playing", "done", "found"] {
            XCTAssertFalse(Agent.estadosDeExito.contains(huerfano),
                           "\(huerfano) necesita una decisión por (herramienta, estado), no por nombre")
        }
        // Y el conjunto sigue siendo exactamente el que esta rama dejó: `success`, `no_content` y
        // los dos verbos de `create_event`.
        XCTAssertEqual(Agent.estadosDeExito,
                       ["success", "no_content", "created", "created_with_warnings"])
        // Los dos invariantes del par de conjuntos, que una ampliación descuidada rompería.
        XCTAssertTrue(Agent.estadosDeExito.isDisjoint(with: Agent.estadosDeFallo))
        XCTAssertTrue(Agent.estadosDeFallo.isSubset(of: ToolLogRow.failureStatuses),
                      "todo lo que mata un turno se pinta en rojo en el chat")
    }
}
