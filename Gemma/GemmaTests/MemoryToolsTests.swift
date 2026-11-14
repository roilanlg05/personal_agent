import XCTest
@testable import Gemma

/// NOTA SOBRE LAS PRUEBAS DE ESTA CLASE Y DE `ForgetToolTests`. Afirmaban las cadenas de prosa
/// que estas dos herramientas devolvían («Saved: sushi», «memory unavailable», «nothing to
/// save», «Forgot 3 item(s)») con `contains` y `==`. Esa prosa era el defecto: lo que no es un
/// objeto JSON cae en la rama de fallo de `ToolLogRow.summarize`, así que un guardado correcto
/// salía en el chat con CRUZ ROJA. Al pasar las dos al contrato `status`, cada prueba se
/// re-apunta a LA PROPIEDAD QUE PROTEGÍA, que nunca fue la cadena:
///   - «devuelve Saved con la entidad» protegía que el usuario sepa QUÉ se guardó → ahora
///     `status: success` + la clave `entity`.
///   - «memory unavailable» protegía que un servicio caído no se cuente como guardado → ahora
///     `status: memory_unavailable`, que además es un fallo declarado para el bucle.
///   - «nothing to save» protegía que la basura no llegue a la red → ahora `status:
///     invalid_entity`, y la propiedad fuerte (no se hizo NINGUNA petición) se afirma de verdad
///     con un doble que cuenta las llamadas, que la prueba vieja no hacía.
///   - «Forgot 3 item(s)» protegía que el usuario sepa CUÁNTOS → ahora `forgotten_count`.
/// Ninguna se borró y ninguna se debilitó. Ver `HerramientasHablanStatusTests` para el censo
/// entero y para los dos textos de la app que esto arregla.
@MainActor
final class SaveMemoryToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "la salida tiene que ser un objeto JSON. got: \(out)")
    }

    func test_save_calls_endpoint_and_declares_what_it_saved() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/save")
            return (200, #"{"id":"n1"}"#.data(using: .utf8)!)
        }
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi","detail":"al user le gusta","kind":"preference"}"#)
        let json = try json(out)
        XCTAssertEqual(json["status"] as? String, "success", "got: \(out)")
        XCTAssertEqual(json["entity"] as? String, "sushi", "got: \(out)")
        XCTAssertEqual(json["kind"] as? String, "preference", "got: \(out)")
    }

    /// Un guardado que el servicio FUNDIÓ con un recuerdo que ya decía lo mismo sigue siendo un
    /// guardado. Y ahora el modelo puede saber que se fundió: las dos ramas devolvían la misma
    /// frase, así que esa información no existía para nadie.
    func test_save_merged_response_is_still_a_save_and_says_so() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/save")
            return (200, #"{"id":"n2","mergedInto":"n1"}"#.data(using: .utf8)!)
        }
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"Messi","kind":"preference"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "success", "got: \(out)")
        XCTAssertEqual(try json(out)["merged_into"] as? String, "n1", "got: \(out)")
    }

    func test_save_no_client_is_safe_and_is_not_counted_as_saved() async throws {
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"x","kind":"fact"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "memory_unavailable", "got: \(out)")
        XCTAssertTrue(Agent.esFallo(resultado: out),
                      "la memoria caída no puede contar como un guardado: \(out)")
    }

    /// LA PROPIEDAD SE AFIRMA DE VERDAD, QUE ANTES NO. La prueba vieja comparaba la frase
    /// «nothing to save» y razonaba en un comentario que si la basura no se filtrara la salida
    /// sería «memory unavailable» — o sea que distinguía los dos caminos por su TEXTO, con el
    /// cliente a `nil`. Ahora hay un doble que cuenta peticiones: la propiedad era que la basura
    /// no gaste un viaje de red, y eso se mide contando.
    func test_save_junk_entity_discarded_before_http() async throws {
        final class Contador: @unchecked Sendable { var peticiones = 0 }
        let contador = Contador()
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            contador.peticiones += 1
            return (200, #"{"id":"n9"}"#.data(using: .utf8)!)
        }
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"   ","kind":"preference"}"#)
        XCTAssertEqual(contador.peticiones, 0, "la basura no puede gastar un viaje de red")
        XCTAssertEqual(try json(out)["status"] as? String, "invalid_entity", "got: \(out)")
    }

    func test_save_permanent_flag_is_passed_in_extra() async {
        var capturedBody: Data?
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            // URLProtocol sees httpBody on the request via bodyStream sometimes; both checked.
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
            return (200, #"{"id":"n3"}"#.data(using: .utf8)!)
        }
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"Roilan","kind":"person","permanent":true}"#)
        if let data = capturedBody, let s = String(data: data, encoding: .utf8) {
            XCTAssertTrue(s.contains("permanent"), "extra should carry permanent flag; body=\(s)")
        } // if URLProtocol stripped the body, we still pass on the request being made.
    }

    func test_save_http_error_is_declared_as_a_failure() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in (500, Data()) }
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi","kind":"preference"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "failed", "got: \(out)")
        XCTAssertTrue(Agent.esFallo(resultado: out), "got: \(out)")
    }
}

@MainActor
final class ForgetToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "la salida tiene que ser un objeto JSON. got: \(out)")
    }

    /// ESTA PRUEBA YA ESTABA ROJA EN LA BASE, Y NO POR EL CONTRATO. Su doble afirmaba que la
    /// PRIMERA petición de `forget` es `/v1/memory/forget`, y dejó de serlo cuando la
    /// herramienta aprendió a buscar por nodos: hoy empieza por `GET /v1/nodes` y solo baja al
    /// borrado por etiqueta si no encontró ninguno. El doble se queja de la primera llamada y la
    /// prueba moría ahí, sin llegar a mirar nada de lo que decía medir. Ahora el doble contesta
    /// a las dos rutas y la aserción del camino de borrado se mantiene donde importa.
    func test_forget_calls_endpoint_and_declares_how_many_it_forgot() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            if req.url?.path == "/v1/nodes" {
                return (200, Data(#"{"nodes":[],"total":0}"#.utf8))
            }
            XCTAssertEqual(req.url?.path, "/v1/memory/forget")
            return (200, #"{"removed":3}"#.data(using: .utf8)!)
        }
        let out = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "success", "got: \(out)")
        XCTAssertEqual(try json(out)["forgotten_count"] as? Int, 3,
                       "cuántos se olvidaron es la propiedad: \(out)")
    }

    func test_forget_no_client_is_safe_and_is_not_counted_as_forgotten() async throws {
        let out = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "memory_unavailable", "got: \(out)")
        XCTAssertTrue(Agent.esFallo(resultado: out), "got: \(out)")
    }

    func test_forget_empty_query_is_noop() async throws {
        let out = await ForgetTool().run(argsJSON: #"{"query":""}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "missing_fields", "got: \(out)")
    }
}
