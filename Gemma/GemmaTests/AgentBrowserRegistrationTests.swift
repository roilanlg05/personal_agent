import XCTest
@testable import Gemma

#if os(macOS)

/// Comprueba que las herramientas del navegador quedan registradas y que el prompt
/// del sistema enseña al modelo a usarlas. `browserToolRegistry()` y `runAgentTurn` comparten
/// la lista de herramientas (`registerBrowserTools(into:)`), pero que `runAgentTurn` llame a ese
/// método no lo prueba un registro: lo fija `test_run_agent_turn_calls_registerBrowserTools`
/// leyendo el código fuente.
@MainActor
final class AgentBrowserRegistrationTests: XCTestCase {

    /// El inventario esperado se DERIVA, no se escribe a mano. Son dos cosas distintas y la
    /// diferencia importa, así que se nombra en vez de borrarse: las herramientas que CONDUCEN
    /// una página son `Agent.browserToolNames`, y `read_webpage` se registra por este mismo
    /// camino (comparte el `AgentBrowserService`) sin ser una de ellas — es de una sola llamada
    /// y el bucle la trata como cualquier otra herramienta del registro.
    ///
    /// Escrito a mano, el día que aparezca una herramienta nueva este test se pone rojo sin
    /// decir por qué: la lista literal se queda vieja y el fallo que se lee es «9 != 10», que
    /// no nombra nada. Derivado, la herramienta nueva entra sola en cuanto se añada a
    /// `browserToolNames`, y si alguien la registra SIN añadirla ahí el fallo dice exactamente
    /// qué nombre sobra o falta.
    ///
    /// Con broker y bóveda (producción, y `browserToolRegistry`) se suman las tres herramientas de
    /// formularios que NO conducen la página (`browser_fill_secret` sí, y ya está en
    /// `browserToolNames`).
    private let deFormularios: Set<String> = ["present_form", "list_secrets", "forget_secret"]
    private var sinFormularios: Set<String> { Agent.browserToolNames.subtracting(["browser_fill_secret"]).union(["read_webpage"]) }
    private var esperadas: Set<String> { Agent.browserToolNames.union(["read_webpage"]).union(deFormularios) }

    private func nombresRegistrados(_ registry: ToolRegistry) -> Set<String> {
        Set(registry.tools.map { type(of: $0).name })
    }

    func test_the_browser_tools_are_registered() {
        let registry = HarnessModel.browserToolRegistry(almacen: AlmacenEnMemoria())
        XCTAssertEqual(nombresRegistrados(registry), esperadas)
        // Un `Set` oculta los duplicados: el registro tiene que traer una instancia por nombre.
        XCTAssertEqual(registry.tools.count, esperadas.count)
        for name in esperadas {
            XCTAssertNotNil(registry.tool(named: name), "falta \(name)")
        }
        // La distinción que no hay que borrar: `read_webpage` está registrada y NO es del
        // navegador. Si algún día lo fuera, esta línea es la que lo dice en voz alta.
        XCTAssertFalse(Agent.browserToolNames.contains("read_webpage"))
        XCTAssertEqual(esperadas.count, Agent.browserToolNames.count + 1 + deFormularios.count)
        XCTAssertTrue(Agent.browserToolNames.contains("browser_fill_secret"))
        for f in deFormularios { XCTAssertFalse(Agent.browserToolNames.contains(f), f) }
    }

    func test_every_browser_tool_has_a_valid_function_spec() {
        for tool in HarnessModel.browserToolRegistry(almacen: AlmacenEnMemoria()).tools {
            let t = type(of: tool)
            XCTAssertFalse(t.name.isEmpty)
            XCTAssertFalse(t.description.isEmpty, "\(t.name) sin descripción")
            XCTAssertEqual(t.jsonSchema["type"] as? String, "object", "\(t.name) con esquema inválido")
        }
    }

    func test_registering_into_an_existing_registry_adds_the_browser_tools() {
        let registry = ToolRegistry()
        registry.register(WebSearchTool())
        HarnessModel.registerBrowserTools(into: registry, almacen: AlmacenEnMemoria())
        // Sin broker ni bóveda no se registra NINGUNA de las cuatro de formularios/secretos.
        XCTAssertEqual(nombresRegistrados(registry), sinFormularios.union(["web_search"]))
        XCTAssertEqual(registry.tools.count, sinFormularios.count + 1)
        XCTAssertNotNil(registry.tool(named: "web_search"))
    }

    func test_run_agent_turn_calls_registerBrowserTools() throws {
        // Fija la llamada en runAgentTurn leyendo el fuente: construir un turno real exige
        // un runtime y un servicio de memoria. Frágil a propósito ante renombrados.
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Harness/HarnessModel.swift")
        // SOBRE EL FUENTE **TROCEADO**, no sobre el crudo, y es la diferencia entre medir y no
        // medir. Las dos aserciones de abajo son de PRESENCIA, y una presencia sobre el texto
        // crudo **se cumple con la característica borrada**: basta envolver la llamada en
        // `/* */` para que el código desaparezca y el texto se conserve. Medido con la suite
        // ENTERA el 2026-11-10: con esta línea y la de `ClaveDeProveedor.migrarTodas()` de
        // `GemmaApp` envueltas en `/* */`, la suite se quedaba en su VERDE EXACTO con dos
        // características de producción borradas —el registro de las herramientas del navegador
        // y la migración de las API keys de pago—; borrarlas de verdad ponía rojas estas dos
        // pruebas. Es decir: las dos redes existían, funcionaban, y un comentario de bloque las
        // cegaba. El troceado compartido es el único sitio donde esto se arregla una vez; una
        // copia a mano aquí sería un bypass por construcción.
        //
        // Y SOBRE EL CÓDIGO **INCONDICIONAL** (`codigoIncondicional`), no solo sin comentarios
        // (H1 de la revisión de rama, medido con la suite entera: m7). Con la llamada envuelta en
        // `#if os(iOS) … #endif` el texto seguía en el fichero, esta presencia se cumplía, y el
        // registro entero del navegador estaba fuera del binario de macOS con la suite en su
        // verde exacto. Un `#if os(macOS)` lo dejaría fuera del teléfono, que es el cliente real.
        let text = TroceadoDeFuente.codigoIncondicional(try String(contentsOf: source, encoding: .utf8))
        XCTAssertTrue(text.contains("Self.registerBrowserTools(into: registry,"),
                      "runAgentTurn ya no llama a registerBrowserTools: un turno real no registraría ninguna herramienta de navegador")
        // La propiedad que de verdad hay que clavar: el permiso para cerrar sale del MENSAJE
        // DEL USUARIO de este turno, y de ningún otro sitio. Si alguien lo cablea a un `true`
        // constante, o lo lee de una preferencia, vuelve el defecto que costó tres rondas (el
        // agente cerrándole la página que el usuario había pedido para leer) y este test es lo
        // único que lo vería.
        XCTAssertTrue(text.contains("userAskedToClose: BrowserCloseIntent.userAskedToClose(prompt)"),
                      "el permiso para cerrar el navegador debe salir del mensaje del usuario de este turno")
    }

    /// El cuerpo de `runAgentTurn` como código INCONDICIONAL y sin comentarios, con los blancos
    /// colapsados. Construir un turno real exige runtime y servicio de memoria, así que el cableado
    /// de producción de los formularios se ata sobre el fuente (presencia sobre el troceado, para
    /// que un `/* */` o un `#if` no la dejen en el texto con la característica borrada).
    private func cuerpoDeRunAgentTurn() throws -> String {
        let fuente = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Harness/HarnessModel.swift")
        let codigo = TroceadoDeFuente.codigoIncondicional(try String(contentsOf: fuente, encoding: .utf8))
        let desde = try XCTUnwrap(codigo.range(of: "func runAgentTurn(_ prompt: String) async {"),
                                  "ya no existe runAgentTurn")
        let cuerpo = String(codigo[desde.lowerBound...])
        return cuerpo.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Sin la bóveda en el `Agent` de producción el redactor es código muerto (hallazgo de la Task 3).
    func test_run_agent_turn_construye_el_agent_con_la_boveda() throws {
        let cuerpo = try cuerpoDeRunAgentTurn()
        XCTAssertTrue(cuerpo.contains("prepared.run(runtime: runtime, bóveda: boveda)"),
                      "El turno nativo debe pasar la bóveda al coordinador de memoria")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Harness/BrainConversationCoordinator.swift")
        let coordinator = TroceadoDeFuente.codigoIncondicional(try String(contentsOf: source, encoding: .utf8))
        XCTAssertTrue(coordinator.contains("barePrompt: barePrompt, bóveda: bóveda"),
                      "El coordinador debe pasar la bóveda al agente que ejecuta las herramientas")
    }

    /// Sin estos argumentos las cuatro herramientas de formularios/secretos no existen en producción
    /// y `browserToolRegistry` (que sí las pasa) no lo delata.
    func test_run_agent_turn_registra_las_herramientas_de_formularios() throws {
        let cuerpo = try cuerpoDeRunAgentTurn()
        XCTAssertTrue(cuerpo.contains("formBroker: formularios, boveda: boveda,"),
                      "runAgentTurn no pasa formBroker/boveda a registerBrowserTools: present_form, list_secrets, forget_secret y browser_fill_secret no se registrarían")
    }

    /// Un formulario abierto al acabar el turno no tiene a nadie esperando: debe cerrarse DESPUÉS
    /// de consumir los eventos (antes cancelaría el formulario que el turno acaba de pedir).
    /// Y solo el formulario de ESTE turno (I3 de la revisión final): un turno viejo cancelado que
    /// acaba tarde cerraba con `cierraFormularioAbierto()` el formulario del turno nuevo.
    func test_run_agent_turn_cierra_el_formulario_abierto_al_acabar_el_turno() throws {
        let cuerpo = try cuerpoDeRunAgentTurn()
        let consumo = try XCTUnwrap(cuerpo.range(of: "await consumeAgentEvents("), "falta consumeAgentEvents")
        let cierre = try XCTUnwrap(cuerpo.range(of: "cierraFormularioAbierto(delTurno: turno)", range: consumo.upperBound..<cuerpo.endIndex),
                                   "runAgentTurn no cierra SU formulario (cierraFormularioAbierto(delTurno: turno)) tras consumeAgentEvents")
        XCTAssertLessThan(consumo.lowerBound, cierre.lowerBound)
    }

    /// El turno se identifica, se declara vigente ANTES de registrar herramientas, y present_form
    /// recibe ese mismo id: sin esto el cierre por dueño no tiene dueño con que comparar.
    func test_run_agent_turn_declara_su_turno_y_se_lo_pasa_a_present_form() throws {
        let cuerpo = try cuerpoDeRunAgentTurn()
        let vigente = try XCTUnwrap(cuerpo.range(of: "formularios.turnoVigente = turno"),
                                    "runAgentTurn no se declara turno vigente del broker")
        let registro = try XCTUnwrap(cuerpo.range(of: "formBroker: formularios, boveda: boveda, turno: turno)"),
                                     "runAgentTurn no pasa su turno a registerBrowserTools")
        XCTAssertLessThan(vigente.lowerBound, registro.lowerBound)
    }

    /// Ausencia sobre el fuente CRUDO del cuerpo de runAgentTurn: ni siquiera comentado debe volver
    /// el cierre sin dueño, que es exactamente el defecto I3.
    func test_run_agent_turn_no_cierra_formularios_ajenos() throws {
        let fuente = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Harness/HarnessModel.swift")
        let crudo = try String(contentsOf: fuente, encoding: .utf8)
        let desde = try XCTUnwrap(crudo.range(of: "func runAgentTurn(_ prompt: String) async {"))
        let resto = crudo[desde.upperBound...]
        let hasta = resto.range(of: #"\n    (public |private |static |nonisolated |@MainActor )*func "#, options: .regularExpression)?.lowerBound
            ?? resto.endIndex
        let cuerpoCrudo = resto[..<hasta]
        XCTAssertFalse(cuerpoCrudo.contains("cierraFormularioAbierto()"),
                       "runAgentTurn vuelve a cerrar cualquier formulario abierto, también el del turno nuevo")
        XCTAssertFalse(cuerpoCrudo.contains("cancelaTodo()"))
    }

    func test_system_prompt_teaches_reading_pages_and_the_interactive_loop() throws {
        let prompt = Agent.systemPromptText
        for phrase in ["`read_webpage(url)` reads the WHOLE page",
                       "call `read_webpage` on the best result BEFORE answering",
                       "`@eN` reference",
                       "`browser_snapshot` again to see the new state",
                       "NEVER reuse an old one"] {
            XCTAssertTrue(prompt.contains(phrase), "al prompt le falta: \(phrase)")
        }
        let open = try XCTUnwrap(prompt.range(of: "`browser_open(url)`"), "falta browser_open(url)")
        let snap = try XCTUnwrap(prompt.range(of: "`browser_snapshot`", range: open.upperBound..<prompt.endIndex),
                                 "browser_snapshot no aparece después de browser_open")
        XCTAssertLessThan(open.lowerBound, snap.lowerBound)
    }
}

#endif
