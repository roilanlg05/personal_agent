import XCTest
@testable import Gemma

/// Las cinco herramientas con las que el agente consulta la memoria —`list_topics`,
/// `recall_by_topic`, `why`, `search_memory` y `load_messages`— no tenían ni una prueba
/// ni contrato `status`. Devolvían prosa en inglés (`"memory unavailable"`,
/// `"no topics yet"`) que el modelo tenía que interpretar.
///
/// Lo que se encontró al escribir estas pruebas, y que estas pruebas fijan:
///
/// 1. **`load_messages` presentaba un fallo del servidor como «no hay mensajes».** Su
///    `catch` devolvía literalmente `"no messages found for chat \(chatId)"`. Si el
///    servicio de memoria estaba caído o el endpoint fallaba, el modelo le decía al
///    usuario que esa conversación no existía, cuando la verdad era «no se pudo
///    consultar». Es exactamente «no se pudo saber» disfrazado de «no hay nada».
/// 2. **`search_memory` tenía el mismo agujero, y peor escondido.**
///    `MemoryClient.recall` se traga los 5xx y los `URLError` y devuelve un paquete
///    *vacío* a propósito, para que el agente siga conversando si la memoria se cae. La
///    herramienta no podía distinguirlo de un «no hay nada», así que con el servicio
///    caído contestaba «No specific memories found matching X»: el usuario oía que Gemma
///    no recordaba nada de él. Se arregla con un camino estricto que sí propaga el fallo.
/// 3. **`recall_by_topic` prometía TODO y recortaba en silencio.** Su descripción le dice
///    al modelo que devuelve «EVERYTHING you remember about one topic», y el resultado
///    se cortaba con `.prefix(4000)` sin decirlo. Lo mismo `list_topics` (`.prefix(2000)`),
///    `load_messages` (`.prefix(4000)`) y `search_memory`, que además se quedaba con los
///    primeros 4 turnos de chat sin avisar. Una enumeración que se presenta como completa
///    y no lo es miente sobre lo que el usuario tiene guardado.
/// 4. **`why` no distinguía los tres casos que importan.** «No encontré esa creencia»,
///    «la tengo pero sin fuentes» y «no pude consultar» caían en frases suyas que el
///    modelo podía resumir como un «porque sí». Ahora son `not_found`, `no_sources` y
///    `failed`, y el mensaje de `no_sources` le prohíbe explícitamente inventarse la
///    justificación.
@MainActor
final class MemoryRecallToolsContractTests: XCTestCase {

    // MARK: - Andamiaje

    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let path = (request.url?.path ?? "") + (request.url?.query.map { "?\($0)" } ?? "")
            let key = Self.routes.keys.first { path.hasPrefix($0) } ?? path
            let (status, body) = Self.routes[key] ?? (404, "{}")
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.routes = [:]
        MemoryToolbox.shared.memory = nil
    }

    override func tearDown() {
        StubURLProtocol.routes = [:]
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    private func installMemory() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        MemoryToolbox.shared.memory = MemoryClient(
            baseURL: URL(string: "http://test.local:8081")!,
            bearerToken: "t",
            session: URLSession(configuration: cfg)
        )
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "No es JSON: \(out)")
    }

    // MARK: - Contrato: salida legible por el modelo

    func test_las_cinco_herramientas_de_memoria_devuelven_json_con_status() async throws {
        let outputs = [
            await ListTopicsTool().run(argsJSON: "{}"),
            await RecallByTopicTool().run(argsJSON: #"{"topic":"finanzas"}"#),
            await WhyTool().run(argsJSON: #"{"claim":"el usuario opera opciones"}"#),
            await SearchMemoryTool().run(argsJSON: #"{"query":"banco"}"#),
            await LoadMessagesTool().run(argsJSON: #"{"chat_id":"g7y","from":1,"to":4}"#)
        ]
        for out in outputs {
            let parsed = try json(out)
            XCTAssertNotNil(parsed["status"], "Sin 'status': \(out)")
        }
    }

    func test_sin_memoria_las_cinco_dicen_memory_unavailable() async throws {
        let outputs = [
            await ListTopicsTool().run(argsJSON: "{}"),
            await RecallByTopicTool().run(argsJSON: #"{"topic":"finanzas"}"#),
            await WhyTool().run(argsJSON: #"{"claim":"x"}"#),
            await SearchMemoryTool().run(argsJSON: #"{"query":"banco"}"#),
            await LoadMessagesTool().run(argsJSON: #"{"chat_id":"g7y","from":1}"#)
        ]
        for out in outputs {
            let parsed = try json(out)
            XCTAssertEqual(parsed["status"] as? String, "memory_unavailable", "Salida: \(out)")
        }
    }

    // MARK: - Defecto 1: load_messages disfrazaba un fallo de "no hay mensajes"

    func test_load_messages_no_dice_que_no_hay_mensajes_cuando_fallo_la_consulta() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/transcript/range": (500, #"{"error":"boom"}"#)]
        let result = try json(await LoadMessagesTool().run(
            argsJSON: #"{"chat_id":"g7y","from":1,"to":4}"#))

        XCTAssertEqual(result["status"] as? String, "failed")
        XCTAssertNotEqual(result["status"] as? String, "empty",
                          "Un fallo del servidor no es una conversación vacía.")
        XCTAssertNotEqual(result["status"] as? String, "not_found")
    }

    func test_load_messages_dice_vacio_cuando_de_verdad_no_hay_nada_en_ese_rango() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/transcript/range": (200, #"{"messages":[],"truncated":false}"#)]
        let result = try json(await LoadMessagesTool().run(
            argsJSON: #"{"chat_id":"g7y","from":1,"to":4}"#))
        XCTAssertEqual(result["status"] as? String, "empty")
    }

    func test_load_messages_devuelve_los_mensajes_del_rango() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/transcript/range": (200, """
        {"messages":[{"seq":1,"role":"user","text":"¿vamos a Cuba?"},{"seq":2,"role":"assistant","text":"sí, el 15"}],"truncated":false}
        """)]
        let result = try json(await LoadMessagesTool().run(
            argsJSON: #"{"chat_id":"g7y","from":1,"to":2}"#))
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual((result["messages"] as? [Any])?.count, 2)
        XCTAssertEqual(result["count"] as? Int, 2)
    }

    func test_load_messages_avisa_cuando_el_rango_venia_recortado() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/transcript/range": (200, """
        {"messages":[{"seq":1,"role":"user","text":"a"}],"truncated":true}
        """)]
        let result = try json(await LoadMessagesTool().run(
            argsJSON: #"{"chat_id":"g7y","from":1,"to":900}"#))
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertNotNil(result["warnings"], "Un recorte silencioso hace que el modelo crea que vio todo.")
    }

    func test_load_messages_exige_el_chat_y_el_inicio() async throws {
        let sinChat = try json(await LoadMessagesTool().run(argsJSON: #"{"from":1}"#))
        XCTAssertEqual(sinChat["status"] as? String, "missing_fields")
        XCTAssertNotNil(sinChat["required"])

        let sinFrom = try json(await LoadMessagesTool().run(argsJSON: #"{"chat_id":"g7y"}"#))
        XCTAssertEqual(sinFrom["status"] as? String, "missing_fields")
    }

    // MARK: - Defecto 2: search_memory heredaba el "degradado silencioso" de recall

    func test_search_memory_no_dice_que_no_recuerda_nada_cuando_la_memoria_falla() async throws {
        installMemory()
        // `MemoryClient.recall` devuelve un paquete vacío a propósito ante un 5xx, para
        // que el agente siga conversando. La herramienta de BÚSQUEDA no puede heredar eso:
        // si lo hace, el usuario oye "no recuerdo nada de ti" por una caída del servidor.
        StubURLProtocol.routes = ["/v1/memory/recall": (500, #"{"error":"boom"}"#)]
        let result = try json(await SearchMemoryTool().run(argsJSON: #"{"query":"banco"}"#))

        XCTAssertNotEqual(result["status"] as? String, "empty",
                          "Un 5xx no es una memoria vacía.")
        XCTAssertEqual(result["status"] as? String, "memory_unavailable")
    }

    func test_search_memory_dice_vacio_cuando_de_verdad_no_encontro_nada() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/recall": (200, """
        {"core":[],"recall":[],"summaries":[],"recentTurns":[]}
        """)]
        let result = try json(await SearchMemoryTool().run(argsJSON: #"{"query":"banco"}"#))
        XCTAssertEqual(result["status"] as? String, "empty")
    }

    func test_search_memory_devuelve_los_hechos_que_encontro() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/recall": (200, """
        {"core":[],"recall":[{"kind":"fact","label":"banco","body":"usa Chase","extra":null}],
         "summaries":[],"recentTurns":[]}
        """)]
        let result = try json(await SearchMemoryTool().run(argsJSON: #"{"query":"banco"}"#))
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual((result["facts"] as? [Any])?.count, 1)
    }

    func test_search_memory_no_recorta_los_turnos_sin_avisar() async throws {
        installMemory()
        // Antes se quedaba con `.prefix(4)` en silencio.
        let turns = (1...9).map { #"{"role":"user","text":"turno \#($0)"}"# }.joined(separator: ",")
        StubURLProtocol.routes = ["/v1/memory/recall": (200, """
        {"core":[],"recall":[],"summaries":[],"recentTurns":[\(turns)]}
        """)]
        let result = try json(await SearchMemoryTool().run(argsJSON: #"{"query":"banco"}"#))
        let shown = (result["recent_turns"] as? [Any])?.count ?? 0
        if shown < 9 {
            XCTAssertNotNil(result["warnings"], "Si recorta, lo dice. Salida: \(result)")
        }
    }

    func test_search_memory_exige_la_consulta() async throws {
        let result = try json(await SearchMemoryTool().run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "missing_fields")
    }

    // MARK: - Defecto 3: enumeraciones "completas" recortadas en silencio

    func test_recall_by_topic_distingue_el_fallo_del_tema_vacio() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/by_topic": (500, #"{"error":"boom"}"#)]
        let failed = try json(await RecallByTopicTool().run(argsJSON: #"{"topic":"finanzas"}"#))
        XCTAssertEqual(failed["status"] as? String, "failed")
        XCTAssertNotEqual(failed["status"] as? String, "empty")

        StubURLProtocol.routes = ["/v1/memory/by_topic": (200, #"{"tag":"finanzas","nodes":[]}"#)]
        let empty = try json(await RecallByTopicTool().run(argsJSON: #"{"topic":"finanzas"}"#))
        XCTAssertEqual(empty["status"] as? String, "empty")
    }

    func test_recall_by_topic_dice_cuando_el_tema_no_existe() async throws {
        installMemory()
        // El servidor no supo resolver el tema a ninguna etiqueta: no es que el tema esté
        // vacío, es que ese tema no está en la memoria. El modelo debería ofrecer
        // list_topics en vez de afirmar que no sabe nada del asunto.
        StubURLProtocol.routes = ["/v1/memory/by_topic": (200, #"{"tag":"","nodes":[]}"#)]
        let result = try json(await RecallByTopicTool().run(argsJSON: #"{"topic":"astrofísica"}"#))
        XCTAssertEqual(result["status"] as? String, "unknown_topic")
    }

    func test_recall_by_topic_no_recorta_en_silencio_lo_que_promete_completo() async throws {
        installMemory()
        // 300 nodos: la descripción promete TODO lo que se recuerda del tema, así que o
        // vienen todos, o el recorte se declara.
        let nodes = (1...300).map {
            #"{"kind":"fact","label":"dato \#($0)","body":"cuerpo bastante largo del dato número \#($0)"}"#
        }.joined(separator: ",")
        StubURLProtocol.routes = ["/v1/memory/by_topic": (200, #"{"tag":"finanzas","nodes":[\#(nodes)]}"#)]
        let result = try json(await RecallByTopicTool().run(argsJSON: #"{"topic":"finanzas"}"#))

        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["total"] as? Int, 300, "El total real se declara siempre.")
        let shown = (result["memories"] as? [Any])?.count ?? 0
        if shown < 300 {
            XCTAssertEqual(result["truncated"] as? Bool, true, "Salida: \(result)")
            XCTAssertNotNil(result["warnings"])
        }
    }

    func test_list_topics_distingue_el_fallo_de_no_tener_temas() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/tags": (500, #"{"error":"boom"}"#)]
        let failed = try json(await ListTopicsTool().run(argsJSON: "{}"))
        XCTAssertEqual(failed["status"] as? String, "failed")
        XCTAssertNotEqual(failed["status"] as? String, "empty",
                          "No haber podido mirar no es no tener temas.")

        StubURLProtocol.routes = ["/v1/memory/tags": (200, #"{"tags":[]}"#)]
        let empty = try json(await ListTopicsTool().run(argsJSON: "{}"))
        XCTAssertEqual(empty["status"] as? String, "empty")
    }

    func test_list_topics_devuelve_los_temas_como_lista() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/tags": (200, #"{"tags":["finanzas","trabajo","salud"]}"#)]
        let result = try json(await ListTopicsTool().run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual((result["topics"] as? [String])?.count, 3)
        XCTAssertEqual(result["count"] as? Int, 3)
    }

    // MARK: - Defecto 4: why confundía "no lo sé" con "no tengo fuentes"

    func test_why_dice_que_no_encontro_la_creencia() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/why": (200, #"{"insight":"","sources":[]}"#)]
        let result = try json(await WhyTool().run(argsJSON: #"{"claim":"el usuario odia el café"}"#))
        XCTAssertEqual(result["status"] as? String, "not_found")
    }

    func test_why_admite_tener_la_creencia_sin_fuentes_y_prohibe_inventarlas() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/why": (200, """
        {"insight":"el usuario opera opciones","sources":[]}
        """)]
        let result = try json(await WhyTool().run(argsJSON: #"{"claim":"el usuario opera opciones"}"#))
        XCTAssertEqual(result["status"] as? String, "no_sources")
        let message = (result["message"] as? String ?? "").lowercased()
        XCTAssertTrue(message.contains("no te invent") || message.contains("no inventes"),
                      "El mensaje tiene que prohibir inventarse la justificación: \(message)")
    }

    func test_why_devuelve_las_fuentes_para_que_el_modelo_las_cite() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/why": (200, """
        {"insight":"el usuario opera opciones","sources":[
          {"kind":"memory","label":"compró calls de AAPL","body":"en marzo"},
          {"kind":"memory","label":"habla de theta","body":"varias veces"}]}
        """)]
        let result = try json(await WhyTool().run(argsJSON: #"{"claim":"el usuario opera opciones"}"#))
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual((result["sources"] as? [Any])?.count, 2)
        XCTAssertEqual(result["claim"] as? String, "el usuario opera opciones")
    }

    func test_why_distingue_el_fallo_de_no_encontrar_la_creencia() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/memory/why": (500, #"{"error":"boom"}"#)]
        let result = try json(await WhyTool().run(argsJSON: #"{"claim":"x"}"#))
        XCTAssertEqual(result["status"] as? String, "failed")
        XCTAssertNotEqual(result["status"] as? String, "not_found")
    }

    func test_why_y_recall_by_topic_exigen_su_argumento() async throws {
        let sinClaim = try json(await WhyTool().run(argsJSON: "{}"))
        XCTAssertEqual(sinClaim["status"] as? String, "missing_fields")

        let sinTopic = try json(await RecallByTopicTool().run(argsJSON: "{}"))
        XCTAssertEqual(sinTopic["status"] as? String, "missing_fields")
    }

    // MARK: - Lo que el modelo lee en las descripciones

    func test_las_cinco_descripciones_declaran_su_contrato_de_status() {
        for description in [ListTopicsTool.description, RecallByTopicTool.description,
                            WhyTool.description, SearchMemoryTool.description,
                            LoadMessagesTool.description] {
            XCTAssertTrue(description.lowercased().contains("status"),
                          "El contrato se declara en la descripción: \(description)")
            XCTAssertTrue(description.contains("memory_unavailable"),
                          "El modelo tiene que saber qué significa 'no se pudo saber'.")
        }
    }

    func test_why_le_dice_al_modelo_que_no_invente_la_justificacion() {
        let description = WhyTool.description.lowercased()
        XCTAssertTrue(description.contains("no_sources"))
        XCTAssertTrue(description.contains("invent"),
                      "La prohibición de inventarse la razón va en la descripción, no solo en el mensaje.")
    }

    func test_search_memory_avisa_de_que_vacio_no_es_no_se_pudo() {
        let description = SearchMemoryTool.description
        XCTAssertTrue(description.contains("empty"))
        XCTAssertTrue(description.contains("memory_unavailable"))
    }
}
