import XCTest
@testable import Gemma

final class BrowserRelayClientTests: XCTestCase {
    func test_la_url_del_socket_sale_del_base_http_con_esquema_ws() {
        let url = BrowserRelayClient.socketURL(baseURL: URL(string: "http://100.91.174.81:8083")!, maxFps: 10)
        XCTAssertEqual(url?.absoluteString, "ws://100.91.174.81:8083/v1/browser/stream?maxFps=10")
    }

    func test_sin_tope_pedido_la_url_no_lleva_maxFps_y_lo_decide_el_servidor() {
        let url = BrowserRelayClient.socketURL(baseURL: URL(string: "http://i3.test:8083")!)
        XCTAssertEqual(url?.absoluteString, "ws://i3.test:8083/v1/browser/stream")
        XCTAssertNil(url?.query)
    }

    func test_con_tope_pedido_la_url_lleva_maxFps() {
        let url = BrowserRelayClient.socketURL(baseURL: URL(string: "http://i3.test:8083")!, maxFps: 4)
        XCTAssertEqual(url?.query, "maxFps=4")
    }

    func test_un_base_https_da_wss() {
        let url = BrowserRelayClient.socketURL(baseURL: URL(string: "https://i3.test")!, maxFps: 10)
        XCTAssertEqual(url?.scheme, "wss")
    }

    func test_decodifica_frame_con_el_jpeg_en_bytes() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let text = #"{"type":"frame","seq":41,"jpeg":"\#(jpeg.base64EncodedString())","captured_at":1793996915.607}"#
        guard case .frame(let seq, let bytes, let at, _) = try XCTUnwrap(BrowserRelayClient.decode(text))
        else { return XCTFail("esperaba .frame") }
        XCTAssertEqual(seq, 41)
        XCTAssertEqual(bytes, jpeg)
        XCTAssertEqual(at.timeIntervalSince1970, 1793996915.607, accuracy: 0.001)
    }

    /// El relé acepta base64 envuelto en líneas y lo pasa tal cual.
    func test_un_jpeg_en_base64_con_saltos_de_linea_se_acepta() throws {
        let jpeg = Data((0..<200).map { UInt8($0 % 256) })
        let wrapped = jpeg.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let escaped = wrapped.replacingOccurrences(of: "\n", with: "\\n")
        let text = #"{"type":"frame","seq":2,"jpeg":"\#(escaped)","captured_at":5}"#
        guard case .frame(_, let bytes, _, _) = try XCTUnwrap(BrowserRelayClient.decode(text))
        else { return XCTFail("esperaba .frame") }
        XCTAssertEqual(bytes, jpeg)
    }

    func test_decodifica_los_otros_cinco_mensajes() throws {
        XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"narration","text":"haciendo clic"}"#)),
                       .narration("haciendo clic"))
        XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"host","host":"amazon.es"}"#)),
                       .host("amazon.es"))
        XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"state","live":true,"collapsed":false}"#)),
                       .state(live: true, collapsed: false))
        XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"summary","text":"navegó en amazon.es · 7 acciones"}"#)),
                       .summary("navegó en amazon.es · 7 acciones"))
        XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"closed","reason":"socket caído"}"#)),
                       .closed(reason: "socket caído"))
    }

    func test_un_mensaje_desconocido_se_ignora_sin_romper() {
        XCTAssertNil(BrowserRelayClient.decode(#"{"type":"loquesea"}"#))
        XCTAssertNil(BrowserRelayClient.decode("no soy json"))
        XCTAssertNil(BrowserRelayClient.decode(#"{"type":"frame","seq":1}"#), "frame sin jpeg es inválido")
    }

    /// El cable no debería traer params nunca, pero si un relé viejo lo trajera,
    /// el cliente no tiene ningún caso donde meterlo. Esta prueba fija esa garantía.
    func test_un_frame_con_campos_de_mas_no_los_transporta() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let text = #"{"type":"frame","seq":1,"jpeg":"\#(jpeg.base64EncodedString())","captured_at":1,"params":{"value":"SECRETO"}}"#
        guard case .frame(_, let bytes, _, _) = try XCTUnwrap(BrowserRelayClient.decode(text))
        else { return XCTFail("esperaba .frame") }
        XCTAssertEqual(bytes, jpeg, "el enum no tiene dónde guardar params")
    }

    func test_el_acuse_tiene_la_forma_exacta() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(BrowserRelayClient.ackPayload(seq: 41).utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "ack")
        XCTAssertEqual(json["seq"] as? Int, 41)
        XCTAssertEqual(json.count, 2)
    }

    // MARK: política de reconexión (pura)

    func test_el_retroceso_crece_y_tiene_tope() {
        let waits = (1...8).map { BrowserRelayClient.reconnectDelay(attempt: $0) }
        XCTAssertEqual(Array(waits.prefix(4)), [1, 2, 4, 8])
        XCTAssertEqual(waits.last, BrowserRelayClient.maxReconnectDelay)
        XCTAssertTrue(zip(waits, waits.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func test_un_frame_reinicia_el_contador_aunque_venga_alto() {
        XCTAssertEqual(BrowserRelayClient.nextFailureCount(current: 7, gotFrame: true), 1)
    }

    func test_sin_frame_el_contador_crece_de_uno_en_uno() {
        XCTAssertEqual(BrowserRelayClient.nextFailureCount(current: 0, gotFrame: false), 1)
        XCTAssertEqual(BrowserRelayClient.nextFailureCount(current: 4, gotFrame: false), 5)
    }

    func test_la_frontera_de_rendicion_es_exacta() {
        XCTAssertFalse(BrowserRelayClient.shouldGiveUp(failures: 8))
        XCTAssertTrue(BrowserRelayClient.shouldGiveUp(failures: 9))
    }

    func test_el_tope_del_retroceso_empieza_a_morder_en_el_intento_6() {
        XCTAssertEqual(BrowserRelayClient.reconnectDelay(attempt: 5), 16)
        XCTAssertEqual(BrowserRelayClient.reconnectDelay(attempt: 6), 30)
    }

    func test_base_con_barra_final_no_duplica_la_barra() {
        let url = BrowserRelayClient.socketURL(baseURL: URL(string: "http://i3.test:8083/")!, maxFps: 5)
        XCTAssertEqual(url?.absoluteString, "ws://i3.test:8083/v1/browser/stream?maxFps=5")
    }

    func test_un_base_ws_se_queda_en_ws() {
        let url = BrowserRelayClient.socketURL(baseURL: URL(string: "ws://i3.test:8083")!, maxFps: 10)
        XCTAssertEqual(url?.scheme, "ws")
    }

    func test_un_esquema_invalido_da_nil() {
        XCTAssertNil(BrowserRelayClient.socketURL(baseURL: URL(string: "file:///tmp/x")!, maxFps: 10))
    }

    /// stop() antes de conectar termina el flujo de verdad, sin dejar tarea viva.
    func test_stop_termina_el_flujo() async {
        let client = BrowserRelayClient(baseURL: URL(string: "http://127.0.0.1:1")!, bearerToken: "t")
        let stream = await client.events()
        await client.stop()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    // MARK: dos envoltorios, porque `XCTAssert*` no sabe esperar

    /// `XCTAssertTrue` con un `Bool` ya calculado. Los argumentos de `XCTAssert*` son
    /// autoclosures NO asíncronos, así que `esCierto(await algo())` no compila; esto recibe
    /// el valor ya evaluado y conserva el fichero y la línea del fallo, que es lo que se pierde
    /// al envolver una aserción.
    private func esCierto(_ valor: Bool, _ porque: String = "",
                          fichero: StaticString = #filePath, linea: UInt = #line) {
        XCTAssertTrue(valor, porque, file: fichero, line: linea)
    }

    private func esFalso(_ valor: Bool, _ porque: String = "",
                         fichero: StaticString = #filePath, linea: UInt = #line) {
        XCTAssertFalse(valor, porque, file: fichero, line: linea)
    }

    // MARK: el mando compartido — la forma de los dos mensajes

    func test_los_dos_mensajes_del_mando_tienen_la_forma_exacta() throws {
        for (payload, tipo) in [(BrowserRelayClient.payloadTomarElMando, "mando_tomar"),
                                (BrowserRelayClient.payloadDevolverElMando, "mando_devolver")] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(json["type"] as? String, tipo)
            XCTAssertEqual(json.count, 1, "ni un campo más: el relé atiende estos dos por su `type` y no reenvía nada")
        }
    }

    // MARK: el mando compartido — decodificar los DOS valores del cable

    func test_el_mando_del_cable_trae_dos_valores_y_el_humano_anonimo_no_es_mio() throws {
        XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"mando","quien":"agente"}"#)),
                       .mando(quien: .agente))
        XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"mando","quien":"humano"}"#)),
                       .mando(quien: .otroVisor),
                       "el mensaje no dice QUÉ visor conduce: por sí solo, un humano es otro visor")
    }

    func test_un_mando_con_un_quien_que_no_entendemos_no_pinta_que_conduces_tu() throws {
        for raro in [#"{"type":"mando","quien":"loquesea"}"#, #"{"type":"mando"}"#,
                     #"{"type":"mando","quien":7}"#, #"{"type":"mando","quien":null}"#] {
            XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(raro)), .mando(quien: .agente),
                           "con un mensaje que no entendemos, la dirección segura es «no conduces tú»: \(raro)")
        }
    }

    // MARK: el mando compartido — la resolución y la caducidad (puras)

    func test_solo_una_peticion_mia_viva_asciende_el_humano_anonimo_a_mio() {
        XCTAssertEqual(BrowserRelayClient.resuelve(.otroVisor, peticionViva: true), .yo)
        XCTAssertEqual(BrowserRelayClient.resuelve(.otroVisor, peticionViva: false), .otroVisor)
        // Que el agente conduzca no depende de lo que yo haya pedido: si el volante está libre,
        // está libre, y una petición mía viva no puede convertir eso en «conduzco yo».
        XCTAssertEqual(BrowserRelayClient.resuelve(.agente, peticionViva: true), .agente)
        XCTAssertEqual(BrowserRelayClient.resuelve(.agente, peticionViva: false), .agente)
    }

    func test_la_peticion_del_volante_caduca_en_el_plazo_exacto() {
        let t = ContinuousClock.now
        XCTAssertTrue(BrowserRelayClient.peticionSigueViva(pedidaEn: t, ahora: t))
        XCTAssertTrue(BrowserRelayClient.peticionSigueViva(
            pedidaEn: t, ahora: t.advanced(by: BrowserRelayClient.caducidadDeLaPeticion)),
                      "el instante justo de la caducidad todavía cuenta como viva")
        XCTAssertFalse(BrowserRelayClient.peticionSigueViva(
            pedidaEn: t, ahora: t.advanced(by: BrowserRelayClient.caducidadDeLaPeticion + .milliseconds(1))))
    }

    func test_el_plazo_es_de_un_viaje_generoso_y_no_de_un_minuto() {
        // No es un adorno ni una eternidad: tiene que aguantar un viaje de ida y vuelta malo y
        // tiene que morir mucho antes de que el usuario se olvide de que pulsó el botón.
        XCTAssertGreaterThanOrEqual(BrowserRelayClient.caducidadDeLaPeticion, .seconds(3))
        XCTAssertLessThan(BrowserRelayClient.caducidadDeLaPeticion, .seconds(30))
    }

    // MARK: el mando compartido — el camino de verdad, sobre un socket de mentira

    func test_tomar_el_mando_manda_exactamente_el_mensaje_de_tomar_y_nada_mas() async {
        let socket = SocketDeMentira()
        let (cliente, _, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        esCierto(await cliente.tomaElMando())
        XCTAssertEqual(socket.loQueSalio, [#"{"type":"mando_tomar"}"#])
    }

    func test_devolver_el_mando_manda_exactamente_el_mensaje_de_devolver() async {
        let socket = SocketDeMentira()
        let (cliente, _, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        esCierto(await cliente.devuelveElMando())
        XCTAssertEqual(socket.loQueSalio, [#"{"type":"mando_devolver"}"#])
    }

    func test_con_mi_peticion_viva_el_humano_del_servidor_soy_yo() async {
        let socket = SocketDeMentira()
        let (cliente, cesta, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        esCierto(await cliente.tomaElMando())
        socket.llega(#"{"type":"mando","quien":"humano"}"#)
        _ = await esperaQue { await cesta.mandos.count == 1 }
        let vistos = await cesta.mandos
        XCTAssertEqual(vistos, [.yo])
    }

    func test_sin_peticion_mia_el_humano_del_servidor_es_otro_visor() async {
        let socket = SocketDeMentira()
        let (_, cesta, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        socket.llega(#"{"type":"mando","quien":"humano"}"#)
        _ = await esperaQue { await cesta.mandos.count == 1 }
        let vistos = await cesta.mandos
        XCTAssertEqual(vistos, [.otroVisor])
    }

    /// El fallo que la tabla de esta tarea existe para cerrar: pido el volante mientras lo tiene
    /// otro visor, el servidor me contesta con silencio, el otro lo devuelve (`"agente"`) y un
    /// tercero lo toma (`"humano"`). Con la petición aún armada, ese último `"humano"` se
    /// pintaría como mío.
    func test_el_agente_al_volante_descarta_mi_peticion_y_el_siguiente_humano_ya_no_es_mio() async {
        let socket = SocketDeMentira()
        let (cliente, cesta, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        esCierto(await cliente.tomaElMando())
        socket.llega(#"{"type":"mando","quien":"agente"}"#)
        _ = await esperaQue { await cesta.mandos.count == 1 }
        let primero = await cesta.mandos
        XCTAssertEqual(primero, [.agente])
        socket.llega(#"{"type":"mando","quien":"humano"}"#)
        _ = await esperaQue { await cesta.mandos.count == 2 }
        let losDos = await cesta.mandos
        XCTAssertEqual(losDos, [.agente, .otroVisor],
                       "la petición ya se consumió: el humano siguiente es de otro")
    }

    func test_una_peticion_sin_contestar_caduca_y_deja_de_reclamar_el_volante() async {
        let reloj = RelojDeMentira()
        let socket = SocketDeMentira()
        let (cliente, cesta, lector) = await montaElCliente(socket, ahora: { reloj.instante })
        defer { lector.cancel() }
        esCierto(await cliente.tomaElMando())
        reloj.avanza(BrowserRelayClient.caducidadDeLaPeticion + .seconds(1))
        socket.llega(#"{"type":"mando","quien":"humano"}"#)
        _ = await esperaQue { await cesta.mandos.count == 1 }
        let vistos = await cesta.mandos
        XCTAssertEqual(vistos, [.otroVisor],
                       "pasada la caducidad, el humano del servidor ya no soy yo")
    }

    func test_dentro_del_plazo_la_misma_peticion_si_reclama_el_volante() async {
        // El lado positivo del mismo reloj: sin esta prueba, una caducidad de cero segundos
        // pasaría la de arriba.
        let reloj = RelojDeMentira()
        let socket = SocketDeMentira()
        let (cliente, cesta, lector) = await montaElCliente(socket, ahora: { reloj.instante })
        defer { lector.cancel() }
        esCierto(await cliente.tomaElMando())
        reloj.avanza(BrowserRelayClient.caducidadDeLaPeticion - .milliseconds(1))
        socket.llega(#"{"type":"mando","quien":"humano"}"#)
        _ = await esperaQue { await cesta.mandos.count == 1 }
        let vistos = await cesta.mandos
        XCTAssertEqual(vistos, [.yo])
    }

    func test_la_peticion_no_sobrevive_al_socket_que_la_mando() async {
        // Dos sockets: el primero muere con la petición armada y el segundo no la hereda. El
        // portador del mando es la CONEXIÓN, así que una conexión nueva empieza sin nada.
        let sockets = ParDeSockets()
        let cliente = BrowserRelayClient(baseURL: URL(string: "http://i3.test:8083")!, bearerToken: "t",
                                         abreElSocket: { _, _ in sockets.siguiente() })
        let cesta = Cesta()
        let flujo = await cliente.events()
        let lector = Task { for await evento in flujo { await cesta.mete(evento) } }
        defer { lector.cancel() }
        esCierto(await esperaQue { sockets.abiertos >= 1 })
        esCierto(await cliente.tomaElMando())
        sockets.primero.muere()
        // El retroceso del primer reintento es de un segundo (`reconnectDelay(attempt: 1)`).
        esCierto(await esperaQue(.seconds(10)) { sockets.abiertos >= 2 },
                      "el cliente tiene que reconectar para que haya una conexión nueva")
        sockets.segundo.llega(#"{"type":"mando","quien":"humano"}"#)
        _ = await esperaQue { await cesta.mandos.count == 1 }
        let vistos = await cesta.mandos
        XCTAssertEqual(vistos, [.otroVisor],
                       "la conexión nueva no hereda la petición de la que murió")
    }

    // MARK: el mando compartido — la entrada del usuario

    func test_la_entrada_no_sale_si_nunca_se_abrio_el_socket() async {
        let socket = SocketDeMentira()
        let cliente = BrowserRelayClient(baseURL: URL(string: "http://i3.test:8083")!, bearerToken: "t",
                                         abreElSocket: { _, _ in socket })
        // Sin `events()` no hay conexión y no hay canal.
        let tecla = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "Q", texto: "Q")
        let salio = await cliente.manda(entrada: tecla)
        XCTAssertFalse(salio)
        XCTAssertEqual(socket.loQueSalio, [], "sin socket no se manda nada")
    }

    func test_con_el_socket_abierto_la_entrada_sale_tal_cual_y_al_caerse_deja_de_salir() async {
        let socket = SocketDeMentira()
        let (cliente, cesta, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        let tecla = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "Q", texto: "Q")
        esCierto(await cliente.manda(entrada: tecla), "con el socket abierto la entrada sale")
        XCTAssertEqual(socket.loQueSalio, [tecla], "sale TAL CUAL: el cliente no sabe de protocolos")
        // Y ahora se cae el socket.
        socket.muere()
        esCierto(await esperaQue { await cesta.huboCierre }, "el cliente tiene que notar el corte")
        let loQueHabia = socket.loQueSalio
        esFalso(await cliente.manda(entrada: tecla), "con el socket caído no se manda")
        XCTAssertEqual(socket.loQueSalio, loQueHabia, "y no se añade nada a lo que salió")
    }

    /// Una petición que no salió del aparato no puede reclamar nada después. Sin esto, pulsar el
    /// botón con el relé caído dejaría la petición armada, y el primer `"humano"` de otro visor
    /// —tras reconectar— se pintaría como mío.
    func test_una_peticion_que_no_salio_del_aparato_no_reclama_el_volante_despues() async {
        let socket = SocketDeMentira()
        let cliente = BrowserRelayClient(baseURL: URL(string: "http://i3.test:8083")!, bearerToken: "t",
                                         abreElSocket: { _, _ in socket.marcaAbierto(); return socket })
        // Sin `events()` no hay canal: la petición no sale.
        esFalso(await cliente.tomaElMando())
        XCTAssertEqual(socket.loQueSalio, [])
        // Y ahora sí se conecta, y el volante se lo lleva otro.
        let cesta = Cesta()
        let flujo = await cliente.events()
        let lector = Task { for await evento in flujo { await cesta.mete(evento) } }
        defer { lector.cancel() }
        _ = await esperaQue { socket.yaSeAbrio }
        socket.llega(#"{"type":"mando","quien":"humano"}"#)
        _ = await esperaQue { await cesta.mandos.count == 1 }
        let vistos = await cesta.mandos
        XCTAssertEqual(vistos, [.otroVisor], "la petición nunca viajó: ese humano no soy yo")
    }

    func test_un_canal_que_ya_fallo_no_se_reintenta() async {
        let socket = SocketDeMentira()
        let (cliente, _, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        let tecla = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "Q", texto: "Q")
        socket.muere()
        esFalso(await cliente.manda(entrada: tecla), "el envío falla y el canal se suelta")
        let intentosTrasElFallo = socket.intentosDeEnvio
        esFalso(await cliente.manda(entrada: tecla))
        XCTAssertEqual(socket.intentosDeEnvio, intentosTrasElFallo,
                       "sin canal no se vuelve a tocar un socket muerto: entre el corte y el `.closed` cabe una contraseña")
    }

    func test_una_entrada_que_pasa_el_tope_del_rele_no_se_manda_porque_el_rele_la_tiraria_en_silencio() async {
        let socket = SocketDeMentira()
        let (cliente, _, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        let enorme = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a",
                                                 texto: String(repeating: "a", count: 5000))
        XCTAssertFalse(BrowserInputEvents.cabeEnElTope(enorme), "guarda del fixture: tiene que pasarse del tope")
        esFalso(await cliente.manda(entrada: enorme))
        XCTAssertEqual(socket.loQueSalio, [], "lo que el relé tiraría en silencio no se manda")
        // Y uno que cabe sí sale, para que la comprobación no sea un «siempre no».
        let justo = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a", texto: "a")
        XCTAssertTrue(BrowserInputEvents.cabeEnElTope(justo))
        esCierto(await cliente.manda(entrada: justo))
        XCTAssertEqual(socket.loQueSalio, [justo])
    }

    /// Regresión del cambio de socket a protocolo: el acuse de cada frame es lo que mantiene el
    /// ritmo del demonio, y ahora sale por el mismo camino que la entrada del usuario.
    func test_el_acuse_de_un_frame_sigue_saliendo_por_el_socket() async {
        let socket = SocketDeMentira()
        let (_, _, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()
        socket.llega(#"{"type":"frame","seq":7,"jpeg":"\#(jpeg)","captured_at":1}"#)
        _ = await esperaQue { socket.loQueSalio.count == 1 }
        XCTAssertEqual(socket.loQueSalio, [BrowserRelayClient.ackPayload(seq: 7)])
    }

    // MARK: la entrada no se registra

    /// Una AUSENCIA, y una ausencia no se puede observar ejecutando código: se lee el fuente,
    /// igual que `BrowserInputEventsTests.test_ninguna_funcion_del_fichero_registra_nada`. Aquí
    /// no se puede pedir el fichero entero sin registro —el bucle de reconexión sí registra, y
    /// debe— así que lo que se afirma es más fino: NINGUNA línea de registro de este fichero
    /// menciona la entrada ni el texto que la transporta.
    ///
    /// Por qué no una prueba en ejecución: `PanelLog` escribe en el log unificado de macOS, que
    /// no se puede leer desde dentro del proceso; y darle un espejo en memoria para poder leerlo
    /// crearía justo lo que esto prohíbe, un sitio más donde una contraseña puede acabar.
    ///
    /// El precio de esta prueba, dicho a propósito: las dos líneas de registro que quedan en el
    /// fichero no pueden usar las palabras «entrada» ni «texto» ni en su prosa. Es un precio
    /// barato y la alternativa (buscar solo interpolaciones) se la salta un `+`.
    func test_ninguna_linea_de_registro_de_este_cliente_lleva_la_entrada_del_usuario() throws {
        let fuente = try fuenteDelCliente()
        // Guarda de vacuidad en dos mitades: que la ruta apunte al fichero de verdad, y que el
        // fichero tenga dentro tanto las funciones que tocan la entrada como al menos una línea
        // de registro. Sin la segunda, un fichero sin un solo rastro pasaría esta prueba sola.
        for ancla in ["func manda(entrada: String)", "func enviaPorElCanal(_ texto: String)",
                      "func tomaElMando()", "PanelLog.note"] {
            XCTAssertTrue(fuente.contains(ancla), "la ruta del fuente ya no apunta al fichero de producción: falta \(ancla)")
        }
        let registradores = ["PanelLog", "print(", "NSLog", "os_log", "Logger", "OSLog", "debugPrint"]
        var lineasDeRegistro = 0
        for linea in fuente.split(separator: "\n", omittingEmptySubsequences: false) {
            let limpia = linea.trimmingCharacters(in: .whitespaces)
            guard !limpia.hasPrefix("//") else { continue }  // la documentación los nombra, y debe
            guard registradores.contains(where: { linea.contains($0) }) else { continue }
            lineasDeRegistro += 1
            for prohibido in ["entrada", "texto"] {
                XCTAssertFalse(linea.contains(prohibido),
                               "una línea de registro no puede llevar lo que el usuario teclea: «\(limpia)»")
            }
        }
        XCTAssertGreaterThan(lineasDeRegistro, 0,
                             "guarda de vacuidad: sin ninguna línea de registro que mirar, esto no afirma nada")
    }

    private func fuenteDelCliente() throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/NativeServices/BrowserRelayClient.swift")
        return try String(contentsOf: fichero, encoding: .utf8)
    }
}

// MARK: - andamio para medir el camino de envío sin red

/// Un socket de mentira: una cola de lo que llega, una lista de lo que sale y un interruptor de
/// muerte. Con él, el camino que lleva la contraseña del usuario se mide entero —desde
/// `manda(entrada:)` hasta el cable— sin red y sin un relé de verdad.
private final class SocketDeMentira: SocketDelVisor, @unchecked Sendable {
    enum Fallo: Error { case elSocketSeCayo }

    private let candado = NSLock()
    private var cola: [String] = []
    private var salidos: [String] = []
    private var muerto = false
    private var abierto = false
    private var intentos = 0

    /// Lo que el cliente mandó por este socket, en orden.
    var loQueSalio: [String] { candado.withLock { salidos } }
    /// Cuántas veces el cliente INTENTÓ mandar, salieran o no. Distingue «no se mandó» de «no
    /// se intentó siquiera», que es la diferencia entre tener canal y no tenerlo.
    var intentosDeEnvio: Int { candado.withLock { intentos } }
    /// Si el cliente ya lo abrió. Lo marca la fábrica inyectada, que es el único sitio donde la
    /// producción abre un socket.
    var yaSeAbrio: Bool { candado.withLock { abierto } }

    func marcaAbierto() { candado.withLock { abierto = true } }
    /// Un mensaje del servidor.
    func llega(_ texto: String) { candado.withLock { cola.append(texto) } }
    /// El socket se cae: `recibeTexto` y `envia` lanzan desde ya.
    func muere() { candado.withLock { muerto = true } }

    func recibeTexto() async throws -> String? {
        while true {
            if let siguiente = candado.withLock({ cola.isEmpty ? nil : cola.removeFirst() }) {
                return siguiente
            }
            if candado.withLock({ muerto }) { throw Fallo.elSocketSeCayo }
            // Sondeo corto en vez de un mecanismo de notificación en el andamio: el bucle del
            // cliente corre en otra tarea y esto es lo que lo mantiene despierto.
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func envia(_ texto: String) async throws {
        candado.withLock { intentos += 1 }
        if candado.withLock({ muerto }) { throw Fallo.elSocketSeCayo }
        candado.withLock { salidos.append(texto) }
    }

    func cierra() { muere() }
}

/// Dos sockets en fila, para la prueba de la reconexión: la fábrica devuelve el primero y, tras
/// su muerte, el segundo.
private final class ParDeSockets: @unchecked Sendable {
    let primero = SocketDeMentira()
    let segundo = SocketDeMentira()
    private let candado = NSLock()
    private var entregados = 0

    var abiertos: Int { candado.withLock { entregados } }

    func siguiente() -> SocketDeMentira {
        let cual = candado.withLock { () -> Int in
            entregados += 1
            return entregados
        }
        let socket = cual <= 1 ? primero : segundo
        socket.marcaAbierto()
        return socket
    }
}

/// Un reloj monótono de mentira, para no esperar la caducidad de verdad.
private final class RelojDeMentira: @unchecked Sendable {
    private let candado = NSLock()
    private var desplazamiento: Duration = .zero
    private let base = ContinuousClock.now

    var instante: ContinuousClock.Instant { base.advanced(by: candado.withLock { desplazamiento }) }
    func avanza(_ cuanto: Duration) { candado.withLock { desplazamiento += cuanto } }
}

/// Los eventos que salieron del cliente, en orden.
private actor Cesta {
    private(set) var eventos: [BrowserRelayEvent] = []

    func mete(_ evento: BrowserRelayEvent) { eventos.append(evento) }

    /// Solo los `mando`, que es lo que mide esta tanda de pruebas.
    var mandos: [QuienConduce] {
        eventos.compactMap {
            if case .mando(let quien) = $0 { return quien }
            return nil
        }
    }

    /// Si el cliente ya notó que la conexión se cortó.
    var huboCierre: Bool {
        eventos.contains {
            if case .closed = $0 { return true }
            return false
        }
    }
}

/// Monta un cliente sobre un socket de mentira y empieza a consumir su flujo. La tarea lectora
/// la cancela el llamante al acabar: si no, el bucle del cliente se queda sondeando.
private func montaElCliente(_ socket: SocketDeMentira,
                            ahora: @escaping @Sendable () -> ContinuousClock.Instant = { .now })
    async -> (BrowserRelayClient, Cesta, Task<Void, Never>) {
    let cliente = BrowserRelayClient(
        baseURL: URL(string: "http://i3.test:8083")!, bearerToken: "t",
        abreElSocket: { _, _ in socket.marcaAbierto(); return socket },
        ahora: ahora)
    let cesta = Cesta()
    let flujo = await cliente.events()
    let lector = Task { for await evento in flujo { await cesta.mete(evento) } }
    // El canal se instala en el mismo paso en que la fábrica devuelve el socket (no hay punto de
    // suspensión entre las dos líneas), así que en cuanto la fábrica ha corrido ya se puede
    // mandar por él.
    _ = await esperaQue { socket.yaSeAbrio }
    return (cliente, cesta, lector)
}

/// Espera acotada. El límite no es cortesía: una mutación puede dejar la condición sin cumplirse
/// nunca, y una espera sin tope colgaría la suite entera en vez de ponerla roja.
private func esperaQue(_ limite: Duration = .seconds(5),
                       _ condicion: @escaping () async -> Bool) async -> Bool {
    let plazo = ContinuousClock.now.advanced(by: limite)
    while ContinuousClock.now < plazo {
        if await condicion() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condicion()
}
