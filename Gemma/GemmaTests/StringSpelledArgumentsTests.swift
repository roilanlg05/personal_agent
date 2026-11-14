import XCTest
import CoreLocation
@testable import Gemma

/// Argumentos escritos como cadena ("true", "25.76") en lugar de su tipo JSON nativo.
///
/// Origen: el formato `<parameter name="k">v</parameter>` que el parser acepta desde el
/// 2026-11-08 entrega TODOS los valores como cadena (el parser no conoce el esquema de cada
/// herramienta y convertir `"123"` a número corrompería cadenas reales). Varias herramientas
/// leían con `as? Bool` / `as? Double`, que ignoran la cadena en silencio y toman el valor por
/// defecto. La más grave: `save_place` guardaba el lugar en la ubicación ACTUAL del usuario.
/// Hasta ese día esos caminos eran inalcanzables; el formato nuevo los hizo alcanzables.
@MainActor
final class StringSpelledArgumentsTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    /// Cuerpo JSON de una petición interceptada (URLProtocol entrega `httpBodyStream`).
    private static func body(_ req: URLRequest) -> [String: Any] {
        var data = req.httpBody
        if data == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096), acc = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                acc.append(buf, count: n)
            }
            data = acc
        }
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    final class Box: @unchecked Sendable {
        var body: [String: Any] = [:]
        var url: URL?
    }

    // MARK: la convención compartida

    func test_coerceBool_acepta_nativo_y_cadena_y_no_inventa_verdad() {
        XCTAssertEqual(CancelAlarmTool.coerceBool(true), true)
        XCTAssertEqual(CancelAlarmTool.coerceBool("true"), true)
        XCTAssertEqual(CancelAlarmTool.coerceBool(" TRUE "), true)
        XCTAssertEqual(CancelAlarmTool.coerceBool("false"), false)
        XCTAssertEqual(CancelAlarmTool.coerceBool("no"), false)
        XCTAssertNil(CancelAlarmTool.coerceBool("quizá"), "una cadena irreconocible no es ni true ni false")
        XCTAssertNil(CancelAlarmTool.coerceBool("Hola"))
        XCTAssertNil(CancelAlarmTool.coerceBool(nil))
    }

    func test_coerceDouble_acepta_nativo_y_cadena_y_rechaza_lo_que_no_es_numero() {
        XCTAssertEqual(CancelAlarmTool.coerceDouble(25.76), 25.76)
        XCTAssertEqual(CancelAlarmTool.coerceDouble(25), 25)
        XCTAssertEqual(CancelAlarmTool.coerceDouble("25.76"), 25.76)
        XCTAssertEqual(CancelAlarmTool.coerceDouble(" -80.19 "), -80.19)
        XCTAssertNil(CancelAlarmTool.coerceDouble("norte"))
        XCTAssertNil(CancelAlarmTool.coerceDouble("nan"))
        XCTAssertNil(CancelAlarmTool.coerceDouble("inf"))
        XCTAssertNil(CancelAlarmTool.coerceDouble(nil))
    }

    // MARK: save_place

    func test_save_place_con_coordenadas_y_radio_en_cadena_guarda_ESAS_coordenadas() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gemma.tests.strargs.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlaceStore(storageURL: dir.appendingPathComponent("places.json"))
        // La ubicación «actual» es otra (10, 20): si las cadenas se ignoraran, el lugar caería ahí.
        let service = LocationService(placeStore: store,
                                      locationProvider: StubLocationProvider(location: CLLocation(latitude: 10, longitude: 20)))
        let out = await SavePlaceTool(placeStore: store, locationService: service).run(
            argsJSON: #"{"name":"Casa de Marcos","latitude":"25.76","longitude":"-80.19","radius_meters":"40"}"#)
        XCTAssertTrue(out.contains("saved"), out)
        let place = try XCTUnwrap(store.list().first)
        XCTAssertEqual(place.latitude, 25.76, accuracy: 1e-9)
        XCTAssertEqual(place.longitude, -80.19, accuracy: 1e-9)
        XCTAssertEqual(place.uncertaintyRadiusMeters, 40, accuracy: 1e-9)
    }

    // MARK: agenda

    func test_create_event_lee_allDay_y_force_en_cadena() async throws {
        let box = Box()
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            if req.url?.path == "/v1/schedule/create" {
                box.body = Self.body(req)
                return (200, Data(#"{"created":true,"id":"e1","conflicts":[]}"#.utf8))
            }
            return (500, Data("{}".utf8))
        }
        let out = await CreateEventTool().run(
            argsJSON: #"{"title":"viaje","start":"2026-11-10","end":"2026-11-12","allDay":"true","force":"true"}"#)
        XCTAssertEqual(box.body["allDay"] as? Bool, true, "allDay en cadena se leyó como false: \(out)")
        XCTAssertEqual(box.body["force"] as? Bool, true, "force en cadena se ignoró: \(out)")
    }

    func test_create_event_una_cadena_irreconocible_no_activa_force() async throws {
        let box = Box()
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            if req.url?.path == "/v1/schedule/create" {
                box.body = Self.body(req)
                return (200, Data(#"{"created":true,"id":"e1","conflicts":[]}"#.utf8))
            }
            return (500, Data("{}".utf8))
        }
        _ = await CreateEventTool().run(
            argsJSON: #"{"title":"x","start":"2026-11-10T08:00","end":"2026-11-10T09:00","force":"quizá"}"#)
        XCTAssertEqual(box.body["force"] as? Bool, false, "forzar sobre un conflicto no puede salir de una cadena ambigua")
    }

    func test_update_event_lee_allDay_y_force_en_cadena() async throws {
        let box = Box()
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            box.body = Self.body(req)
            return (200, Data(#"{"updated":false,"notFound":true}"#.utf8))
        }
        _ = await UpdateEventTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"x","allDay":"true","force":"true"}"#)
        XCTAssertEqual(box.body["allDay"] as? Bool, true)
        XCTAssertEqual(box.body["force"] as? Bool, true)
    }

    func test_query_schedule_lee_includeCancelled_en_cadena() async throws {
        let box = Box()
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            box.url = req.url
            return (200, Data(#"{"events":[]}"#.utf8))
        }
        _ = await QueryScheduleTool().run(argsJSON: #"{"from":"2026-11-10","to":"2026-11-11","includeCancelled":"true"}"#)
        XCTAssertTrue(box.url?.absoluteString.contains("includeCancelled=true") == true, "url: \(String(describing: box.url))")
    }

    // MARK: memoria

    func test_save_memory_lee_permanent_en_cadena() async throws {
        let box = Box()
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            box.body = Self.body(req)
            return (200, Data(#"{"id":"n1"}"#.utf8))
        }
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"Roilan","kind":"self","permanent":"true"}"#)
        let extra = (box.body["extra"] as? String) ?? ""
        XCTAssertTrue(extra.contains("permanent"), "permanent en cadena se guardó como no permanente; body: \(box.body)")
    }

    // MARK: navegador

    func test_read_webpage_lee_outline_en_cadena() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"content":"x","status":200},"error":null}"#)
        _ = await ReadWebpageTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"url":"https://a.test","outline":"true"}"#)
        XCTAssertTrue((mock.receivedArguments.first ?? []).contains("--outline"))
    }

    func test_snapshot_lee_interactive_only_false_en_cadena() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"snapshot":"x","refs":{}},"error":null}"#)
        _ = await BrowserSnapshotTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"interactive_only":"false"}"#)
        XCTAssertFalse((mock.receivedArguments.first ?? []).contains("-i"),
                       "pedir el árbol completo con \"false\" devolvió el interactivo")
    }
}
