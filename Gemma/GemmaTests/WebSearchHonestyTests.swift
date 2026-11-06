import XCTest
@testable import Gemma

final class WebSearchHonestyTests: XCTestCase {

    /// Sesión controlada: cada prueba decide qué devuelve la red.
    private final class SearchStubProtocol: URLProtocol {
        enum Outcome {
            case status(Int, Data)
            case failure(Error)
        }
        nonisolated(unsafe) static var outcome: Outcome = .status(200, Data())

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            switch Self.outcome {
            case .status(let code, let data):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private func searcher(_ outcome: SearchStubProtocol.Outcome) -> SystemWebSearcher {
        SearchStubProtocol.outcome = outcome
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStubProtocol.self]
        return SystemWebSearcher(session: URLSession(configuration: config))
    }

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "La salida debe ser JSON válido. got: \(out)")
    }

    // MARK: - Defecto 10: nada de resultados fabricados

    func test_network_failure_throws_instead_of_fabricating_a_result() async {
        let service = searcher(.failure(URLError(.notConnectedToInternet)))
        do {
            let results = try await service.search(query: "precio del bitcoin", maxResults: 3)
            XCTFail("Sin red debe fallar, no devolver un resultado inventado: \(results)")
        } catch {
            // Correcto: el fallo se propaga.
        }
    }

    func test_http_error_throws_instead_of_fabricating_a_result() async {
        let service = searcher(.status(503, Data()))
        do {
            let results = try await service.search(query: "noticias", maxResults: 3)
            XCTFail("Un 503 debe fallar, no devolver un resultado inventado: \(results)")
        } catch {
            XCTAssertTrue("\(error)".contains("503") || error is WebSearchError, "got: \(error)")
        }
    }

    func test_unparseable_body_throws_instead_of_fabricating_a_result() async {
        let service = searcher(.status(200, Data("no soy json".utf8)))
        do {
            let results = try await service.search(query: "noticias", maxResults: 3)
            XCTFail("Un cuerpo ilegible debe fallar, no devolver un resultado inventado: \(results)")
        } catch {
            // Correcto.
        }
    }

    func test_valid_but_empty_response_returns_no_results() async throws {
        let body = Data(#"{"Heading": "", "AbstractText": "", "RelatedTopics": []}"#.utf8)
        let service = searcher(.status(200, body))
        let results = try await service.search(query: "algo raro", maxResults: 3)
        XCTAssertTrue(results.isEmpty, "Una respuesta válida sin coincidencias son cero resultados, no uno falso.")
    }

    func test_valid_response_is_parsed() async throws {
        let body = Data(#"{"Heading": "Bitcoin", "AbstractText": "Una criptomoneda.", "AbstractURL": "https://x.test/bitcoin"}"#.utf8)
        let service = searcher(.status(200, body))
        let results = try await service.search(query: "bitcoin", maxResults: 3)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Bitcoin")
    }

    // MARK: - Defecto 10: el tool separa éxito, vacío y error

    func test_tool_reports_no_results_as_its_own_state() async throws {
        let tool = WebSearchTool(searchService: WebSearchService(searcher: MockWebSearcher(cannedResults: [])))
        let out = await tool.run(argsJSON: #"{"query": "consulta sin coincidencias"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "no_results", "got: \(out)")
        XCTAssertEqual(json["count"] as? Int, 0)
    }

    func test_tool_reports_error_state_on_failure() async throws {
        let searcher = MockWebSearcher()
        searcher.shouldThrowError = URLError(.notConnectedToInternet)
        let tool = WebSearchTool(searchService: WebSearchService(searcher: searcher))
        let out = await tool.run(argsJSON: #"{"query": "noticias"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error", "got: \(out)")
        XCTAssertNil(json["results"], "Un fallo no lleva resultados.")
        XCTAssertNotNil(json["message"] as? String)
    }

    func test_tool_reports_success_state_with_results() async throws {
        let searcher = MockWebSearcher(cannedResults: [
            WebSearchResult(title: "A", snippet: "B", url: "https://a.test")
        ])
        let tool = WebSearchTool(searchService: WebSearchService(searcher: searcher))
        let out = await tool.run(argsJSON: #"{"query": "a"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success", "got: \(out)")
        XCTAssertEqual(json["count"] as? Int, 1)
    }

    func test_tool_describes_its_states_to_the_model() {
        let description = WebSearchTool.description
        XCTAssertTrue(description.contains("no_results"), "got: \(description)")
        XCTAssertTrue(description.contains("error"), "got: \(description)")
    }

    /// El `MockWebSearcher` no debe fabricar un resultado cuando no se le dio ninguno:
    /// es el doble que usan las pruebas de los demás tools y debe reflejar la realidad.
    func test_mock_searcher_without_canned_results_returns_empty() async throws {
        let results = try await MockWebSearcher().search(query: "x", maxResults: 3)
        XCTAssertTrue(results.isEmpty)
    }
}
