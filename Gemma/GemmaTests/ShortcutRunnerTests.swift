import XCTest
@testable import Gemma

final class MockShortcutRunner: ShortcutRunning, @unchecked Sendable {
    var availableNames: [String]?
    var resultByName: [String: ShortcutRunResult] = [:]
    var defaultResult: ShortcutRunResult

    private(set) var runs: [(name: String, input: String?)] = []

    init(
        availableNames: [String]? = nil,
        defaultResult: ShortcutRunResult = ShortcutRunResult(outcome: .ok, output: "listo")
    ) {
        self.availableNames = availableNames
        self.defaultResult = defaultResult
    }

    func listAvailableNames() async -> [String]? { availableNames }

    func run(name: String, input: String?) async -> ShortcutRunResult {
        runs.append((name, input))
        return resultByName[name] ?? defaultResult
    }
}

final class ShortcutRunnerTests: XCTestCase {

    // MARK: - Construcción de la URL x-callback

    func test_callbackURL_hasAllRequiredParameters() throws {
        let url = try XCTUnwrap(
            URLSchemeShortcutRunner.callbackURL(name: "Create Note", input: "Leche y pan", token: "tok-1")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(components.scheme, "shortcuts")
        XCTAssertEqual(components.host, "x-callback-url")
        XCTAssertEqual(components.path, "/run-shortcut")
        XCTAssertEqual(items["name"], "Create Note")
        XCTAssertEqual(items["input"], "text")
        XCTAssertEqual(items["text"], "Leche y pan")
        XCTAssertEqual(items["x-success"], "gemma://shortcut-callback?token=tok-1&status=success")
        XCTAssertEqual(items["x-cancel"], "gemma://shortcut-callback?token=tok-1&status=cancel")
        XCTAssertEqual(items["x-error"], "gemma://shortcut-callback?token=tok-1&status=error")
    }

    func test_callbackURL_withoutInput_omitsTextParameter() throws {
        let url = try XCTUnwrap(
            URLSchemeShortcutRunner.callbackURL(name: "Total de ventas de hoy", input: nil, token: "t")
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(items.contains { $0.name == "text" })
        XCTAssertFalse(items.contains { $0.name == "input" })
    }

    func test_callbackURL_escapesNamesAndInput() throws {
        let url = try XCTUnwrap(
            URLSchemeShortcutRunner.callbackURL(
                name: "Paga mi tarjeta & cía",
                input: "100 USD / \"ahora\"",
                token: "t"
            )
        )
        // Si el escapado fuera incorrecto, los parámetros no se podrían volver a leer.
        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(items["name"], "Paga mi tarjeta & cía")
        XCTAssertEqual(items["text"], "100 USD / \"ahora\"")
    }

    // MARK: - Interpretación del callback que devuelve Atajos

    func test_parseCallback_successCarriesResult() throws {
        let url = try XCTUnwrap(URL(string: "gemma://shortcut-callback?token=tok-1&status=success&result=Nota%20creada"))
        let callback = try XCTUnwrap(ShortcutCallback(url: url))
        XCTAssertEqual(callback.token, "tok-1")
        XCTAssertEqual(callback.outcome, .ok)
        XCTAssertEqual(callback.output, "Nota creada")
    }

    func test_parseCallback_successWithoutResultHasNoOutput() throws {
        let url = try XCTUnwrap(URL(string: "gemma://shortcut-callback?token=t&status=success"))
        let callback = try XCTUnwrap(ShortcutCallback(url: url))
        XCTAssertEqual(callback.outcome, .ok)
        XCTAssertNil(callback.output)
    }

    func test_parseCallback_cancel() throws {
        let url = try XCTUnwrap(URL(string: "gemma://shortcut-callback?token=t&status=cancel"))
        XCTAssertEqual(ShortcutCallback(url: url)?.outcome, .cancelled)
    }

    func test_parseCallback_errorCarriesMessage() throws {
        let url = try XCTUnwrap(
            URL(string: "gemma://shortcut-callback?token=t&status=error&errorMessage=No%20existe")
        )
        let callback = try XCTUnwrap(ShortcutCallback(url: url))
        XCTAssertEqual(callback.outcome, .failed)
        XCTAssertEqual(callback.errorMessage, "No existe")
    }

    func test_parseCallback_rejectsUnrelatedURLs() {
        XCTAssertNil(ShortcutCallback(url: URL(string: "gemma://otra-cosa?token=t")!))
        XCTAssertNil(ShortcutCallback(url: URL(string: "https://example.com?token=t&status=success")!))
        XCTAssertNil(ShortcutCallback(url: URL(string: "gemma://shortcut-callback?status=success")!),
                     "Sin token no se puede saber a qué ejecución pertenece")
    }

    // MARK: - Broker: casar la respuesta con quien espera

    func test_broker_deliversResultToWaiter() async throws {
        let broker = ShortcutCallbackBroker()
        let token = await broker.makeToken()

        async let pending = broker.awaitCallback(token: token, timeout: 5)
        // Dar tiempo a que el llamador quede registrado antes de entregar.
        try await Task.sleep(nanoseconds: 50_000_000)
        let url = URL(string: "gemma://shortcut-callback?token=\(token)&status=success&result=42")!
        let delivered = await broker.deliver(url: url)

        XCTAssertTrue(delivered)
        let result = await pending
        XCTAssertEqual(result.outcome, .ok)
        XCTAssertEqual(result.output, "42")
    }

    func test_broker_timesOutWhenNothingArrives() async {
        let broker = ShortcutCallbackBroker()
        let token = await broker.makeToken()
        let result = await broker.awaitCallback(token: token, timeout: 0.2)
        XCTAssertEqual(result.outcome, .timedOut)
    }

    func test_broker_ignoresUnknownToken() async {
        let broker = ShortcutCallbackBroker()
        let url = URL(string: "gemma://shortcut-callback?token=desconocido&status=success")!
        let delivered = await broker.deliver(url: url)
        XCTAssertFalse(delivered)
    }

    func test_broker_tokensAreUnique() async {
        let broker = ShortcutCallbackBroker()
        var seen = Set<String>()
        for _ in 0..<20 {
            seen.insert(await broker.makeToken())
        }
        XCTAssertEqual(seen.count, 20)
    }

    func test_broker_lateCallbackAfterTimeoutIsHarmless() async {
        let broker = ShortcutCallbackBroker()
        let token = await broker.makeToken()
        let result = await broker.awaitCallback(token: token, timeout: 0.1)
        XCTAssertEqual(result.outcome, .timedOut)

        // El callback llega tarde: no debe reanudar nada ni provocar un fallo.
        let url = URL(string: "gemma://shortcut-callback?token=\(token)&status=success")!
        let delivered = await broker.deliver(url: url)
        XCTAssertFalse(delivered)
    }
}
