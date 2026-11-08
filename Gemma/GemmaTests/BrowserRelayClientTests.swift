import XCTest
@testable import Gemma

final class BrowserRelayClientTests: XCTestCase {
    func test_la_url_del_socket_sale_del_base_http_con_esquema_ws() {
        let url = BrowserRelayClient.socketURL(baseURL: URL(string: "http://100.91.174.81:8083")!, maxFps: 10)
        XCTAssertEqual(url?.absoluteString, "ws://100.91.174.81:8083/v1/browser/stream?maxFps=10")
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
}
