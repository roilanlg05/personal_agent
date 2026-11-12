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
        guard case .frame(let seq, let bytes, let at) = try XCTUnwrap(BrowserRelayClient.decode(text))
        else { return XCTFail("esperaba .frame") }
        XCTAssertEqual(seq, 41)
        XCTAssertEqual(bytes, jpeg)
        XCTAssertEqual(at.timeIntervalSince1970, 1793996915.607, accuracy: 0.001)
    }

    /// Un servidor sin actualizar sigue mandando `viewport_width`/`viewport_height` en cada
    /// fotograma. El cliente ya no los usa, pero el fotograma tiene que decodificarse igual:
    /// ignorar un campo que sobra es compatibilidad, descartar el fotograma sería un panel negro.
    func test_un_frame_con_viewport_de_un_servidor_viejo_se_decodifica_igual() throws {
        let jpeg = Data([0xFF, 0xD8]).base64EncodedString()
        let texto = #"{"type":"frame","seq":3,"jpeg":"\#(jpeg)","captured_at":1,"viewport_width":1280,"viewport_height":720}"#
        guard case .frame(let seq, let bytes, _) = try XCTUnwrap(BrowserRelayClient.decode(texto))
        else { return XCTFail("no es frame") }
        XCTAssertEqual(seq, 3)
        XCTAssertEqual(bytes, Data([0xFF, 0xD8]))
    }

    /// El relé acepta base64 envuelto en líneas y lo pasa tal cual.
    func test_un_jpeg_en_base64_con_saltos_de_linea_se_acepta() throws {
        let jpeg = Data((0..<200).map { UInt8($0 % 256) })
        let wrapped = jpeg.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let escaped = wrapped.replacingOccurrences(of: "\n", with: "\\n")
        let text = #"{"type":"frame","seq":2,"jpeg":"\#(escaped)","captured_at":5}"#
        guard case .frame(_, let bytes, _) = try XCTUnwrap(BrowserRelayClient.decode(text))
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

    /// Un servidor viejo (o el de otra rama) puede seguir mandando `mando`. El visor ya no sabe de
    /// volantes: el mensaje cae en el `default` del decodificador y se ignora sin romper el panel.
    func test_un_mensaje_de_mando_de_un_servidor_viejo_se_ignora() {
        for viejo in [#"{"type":"mando","quien":"humano"}"#, #"{"type":"mando","quien":"agente"}"#] {
            XCTAssertNil(BrowserRelayClient.decode(viejo), "el visor ya no sabe de volantes: \(viejo)")
        }
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
        guard case .frame(_, let bytes, _) = try XCTUnwrap(BrowserRelayClient.decode(text))
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

    // MARK: lo único que el visor manda es el acuse

    /// Regresión del cambio de socket a protocolo: el acuse de cada frame es lo que mantiene el
    /// ritmo del demonio (sin él deja de mandar fotogramas), y es lo único que el visor manda.
    func test_el_acuse_de_un_frame_sigue_saliendo_por_el_socket() async {
        let socket = SocketDeMentira()
        let (_, _, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()
        socket.llega(#"{"type":"frame","seq":7,"jpeg":"\#(jpeg)","captured_at":1}"#)
        _ = await esperaQue { socket.loQueSalio.count == 1 }
        XCTAssertEqual(socket.loQueSalio, [BrowserRelayClient.ackPayload(seq: 7)])
    }

    /// COMPORTAMIENTO, no forma: se le dan al visor todos los tipos de mensaje que puede recibir
    /// (frames, los otros cinco, basura, JSON desconocido y un mensaje viejo del volante) y se
    /// exige que TODO lo que sale por el socket sea un acuse, uno por frame y con su `seq`. Si
    /// alguien añade cualquier envío —por la vía que sea que pase por el socket— esto se pone rojo.
    func test_todo_lo_que_el_visor_envia_es_un_acuse() async {
        let socket = SocketDeMentira()
        let (_, _, lector) = await montaElCliente(socket)
        defer { lector.cancel() }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()
        let mensajes = [
            #"{"type":"narration","text":"hola"}"#,
            #"{"type":"frame","seq":1,"jpeg":"\#(jpeg)","captured_at":1}"#,
            #"{"type":"host","host":"example.com"}"#,
            #"{"type":"state","live":true,"collapsed":false}"#,
            #"{"type":"frame","seq":2,"jpeg":"\#(jpeg)","captured_at":2,"viewport_width":1280,"viewport_height":720}"#,
            #"{"type":"summary","text":"fin"}"#,
            "esto no es json",
            #"{"type":"algo_desconocido"}"#,
            #"{"type":"frame","seq":3,"jpeg":"\#(jpeg)","captured_at":3}"#,
        ]
        for m in mensajes { socket.llega(m) }
        _ = await esperaQue { socket.loQueSalio.count >= 3 }
        // Margen para que un envío espurio, si lo hubiera, llegara a salir.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(socket.loQueSalio, [1, 2, 3].map { BrowserRelayClient.ackPayload(seq: $0) },
                       "el visor envió algo que no es el acuse de un frame")
    }

    // MARK: retirar el panel libera el cliente del relé

    /// Desde que el volante no existe, el cliente del relé no tiene dueño: `makeRelayStream` solo
    /// devuelve el flujo y es su `onTermination` quien lo cierra. Si esa cadena se rompiera, cada
    /// panel retirado dejaría un WebSocket abierto contra el i3 y un bucle de reconexión vivo,
    /// y ninguna otra prueba lo notaría: el panel nuevo se vería igual.
    ///
    /// Se mide en el único sitio observable, el socket: retirar el panel (cancelar a quien
    /// consume el flujo) tiene que CERRARLO, y el cliente no debe abrir otro después.
    @MainActor func test_retirar_el_panel_cierra_el_socket_del_cliente_y_no_reconecta() async throws {
        let socket = SocketDeMentira()
        let abiertos = Contador()
        let d = UserDefaults(suiteName: "BrowserRelayClientTests.\(UUID().uuidString)")!
        d.set("http://i3.test:8083", forKey: SettingsKeys.browserBaseURL)
        let flujo = try XCTUnwrap(HarnessModel.makeRelayStream(
            defaults: d, almacen: AlmacenEnMemoria()) { _, _ in
            abiertos.suma(); socket.marcaAbierto(); return socket
        })
        let consumidor = Task { for await _ in flujo {} }
        let abrio = await esperaQue { socket.yaSeAbrio }
        XCTAssertTrue(abrio, "precondición: el cliente abrió su socket")
        XCTAssertFalse(socket.estaCerrado, "precondición: con el panel puesto el socket sigue abierto")

        consumidor.cancel()   // retirar el panel

        let cerro = await esperaQue { socket.estaCerrado }
        XCTAssertTrue(cerro, "retirar el panel tiene que cerrar el socket del cliente")
        // Un cliente que siguiera vivo reconectaría tras su retroceso de 1 s.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(abiertos.valor, 1, "y el cliente parado no vuelve a abrir otro socket")
    }
}

// MARK: - andamio para medir el cliente sin red

/// Un socket de mentira: una cola de lo que llega, una lista de lo que sale y un interruptor de
/// muerte. Con él, el camino de salida (el acuse) y el cierre se miden sin red ni relé de verdad.
private final class SocketDeMentira: SocketDelVisor, @unchecked Sendable {
    enum Fallo: Error { case elSocketSeCayo }

    private let candado = NSLock()
    private var cola: [String] = []
    private var salidos: [String] = []
    private var muerto = false
    private var abierto = false
    private var cerrado = false
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

    /// Si el cliente llamó a `cierra()`. Distinto de `muere()`: un fallo simulado también mata el socket.
    var estaCerrado: Bool { candado.withLock { cerrado } }
    func cierra() { candado.withLock { cerrado = true }; muere() }
}

/// Cuenta cuántas veces el cliente abrió un socket.
private final class Contador: @unchecked Sendable {
    private let candado = NSLock()
    private var n = 0
    func suma() { candado.withLock { n += 1 } }
    var valor: Int { candado.withLock { n } }
}

/// Los eventos que salieron del cliente, en orden.
private actor Cesta {
    private(set) var eventos: [BrowserRelayEvent] = []

    func mete(_ evento: BrowserRelayEvent) { eventos.append(evento) }
}

/// Monta un cliente sobre un socket de mentira y empieza a consumir su flujo. La tarea lectora
/// la cancela el llamante al acabar: si no, el bucle del cliente se queda sondeando.
private func montaElCliente(_ socket: SocketDeMentira)
    async -> (BrowserRelayClient, Cesta, Task<Void, Never>) {
    let cliente = BrowserRelayClient(
        baseURL: URL(string: "http://i3.test:8083")!, bearerToken: "t",
        abreElSocket: { _, _ in socket.marcaAbierto(); return socket })
    let cesta = Cesta()
    let flujo = await cliente.events()
    let lector = Task { for await evento in flujo { await cesta.mete(evento) } }
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
