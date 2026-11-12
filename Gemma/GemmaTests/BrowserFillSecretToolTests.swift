import Foundation
import XCTest
@testable import Gemma

/// Invocador falso que SÍ acepta entrada estándar, como el `ProcessAgentBrowserInvoker`. Graba
/// los argumentos y la entrada de cada llamada para poder comprobar por dónde viajó el valor.
final class InvocadorConStdinFalso: AgentBrowserInvokingConStdin, @unchecked Sendable {
    /// Una salida por llamada, en orden; la última se repite.
    var salidas: [String]
    private(set) var argumentos: [[String]] = []
    private(set) var entradas: [Data?] = []

    init(salidas: [String]) { self.salidas = salidas }

    func invoke(arguments: [String], timeout: TimeInterval) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure> {
        await invoke(arguments: arguments, timeout: timeout, stdin: nil)
    }

    func invoke(arguments: [String], timeout: TimeInterval, stdin: Data?) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure> {
        argumentos.append(arguments)
        entradas.append(stdin)
        let salida = salidas.count > 1 ? salidas.removeFirst() : (salidas.first ?? "")
        return .success(AgentBrowserInvocation(exitCode: 0, standardOutput: salida, standardError: ""))
    }
}

/// Almacén que cuenta lecturas: sirve para demostrar que un nombre inválido se rechaza ANTES de
/// tocar la bóveda.
final class AlmacenQueCuenta: AlmacenDeSecretos, @unchecked Sendable {
    private let base = AlmacenEnMemoria()
    private(set) var cuentasLeidas: [String] = []
    func leer(cuenta: String) -> String? { cuentasLeidas.append(cuenta); return base.leer(cuenta: cuenta) }
    func borrar(cuenta: String) { base.borrar(cuenta: cuenta) }
    @discardableResult func escribir(_ valor: String, cuenta: String) -> Bool { base.escribir(valor, cuenta: cuenta) }
}

final class BrowserFillSecretToolTests: XCTestCase {
    /// Valor de juguete con todo lo que puede romper un JSON hecho a mano o un argumento de shell:
    /// comillas, barras, salto de línea, unicode compuesto y emoji.
    private let valor = "pa\"ss\\wo\nrd ñ😀 '$(x)'"

    private func url(_ u: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["url": u], "error": NSNull()]), as: UTF8.self)
    }
    /// Lo que devuelve `agent-browser batch --json --omit-command` medido en vivo (0.41.2).
    private let batchOK = ##"[{"error":null,"index":0,"result":{"filled":"#pw"},"success":true}]"##

    private func args(selector: String = "#pw", secret: String = "gmail_password") -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["selector": selector, "secret": secret]), as: UTF8.self)
    }

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }

    private func boveda(origen: String = "accounts.google.com", almacen: AlmacenDeSecretos = AlmacenEnMemoria()) -> SecretVault {
        let v = SecretVault(almacen: almacen)
        XCTAssertTrue(v.guarda(name: "gmail_password", value: valor, etiqueta: "Contraseña", origen: origen))
        return v
    }

    private func herramienta(_ inv: any AgentBrowserInvoking, _ vault: SecretVault) -> BrowserFillSecretTool {
        BrowserFillSecretTool(service: AgentBrowserService(invoker: inv, sessionName: "gemma"), vault: vault)
    }

    /// El valor no puede aparecer en ninguna forma: ni literal ni escapado como JSON.
    private func assertSinValor(_ texto: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(texto.contains(valor), "valor literal en: \(texto)", file: file, line: line)
        let escapado = String(String(decoding: try! JSONEncoder().encode(valor), as: UTF8.self).dropFirst().dropLast())
        XCTAssertFalse(texto.contains(escapado), "valor escapado en: \(texto)", file: file, line: line)
        XCTAssertFalse(texto.contains("pa\"ss") || texto.contains("wo\nrd"), "trozo del valor en: \(texto)", file: file, line: line)
    }

    // MARK: camino feliz

    func test_teclea_por_stdin_y_los_argumentos_no_contienen_el_valor() async throws {
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/signin?x=1"), batchOK])
        let out = await herramienta(inv, boveda()).run(argsJSON: args())

        XCTAssertEqual(try parse(out)["status"] as? String, "success", out)
        XCTAssertEqual(inv.argumentos.count, 2)
        XCTAssertEqual(inv.argumentos[1], ["--session", "gemma", "batch", "--omit-command", "--json"])
        for a in inv.argumentos.flatMap({ $0 }) { assertSinValor(a) }
        XCTAssertNil(inv.entradas[0], "get url no lleva entrada estándar")
        // La entrada es JSON válido y el valor llega ÍNTEGRO (serializado, no concatenado a mano).
        let entrada = try XCTUnwrap(inv.entradas[1])
        let decodificada = try XCTUnwrap(JSONSerialization.jsonObject(with: entrada) as? [[String]])
        XCTAssertEqual(decodificada, [["fill", "#pw", valor]])
    }

    func test_el_resultado_no_contiene_el_valor() async throws {
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/"), batchOK])
        let out = await herramienta(inv, boveda()).run(argsJSON: args())
        XCTAssertEqual(try parse(out)["status"] as? String, "success")
        assertSinValor(out)
    }

    func test_permite_un_subdominio() async throws {
        let inv = InvocadorConStdinFalso(salidas: [url("https://mail.google.com/u/0"), batchOK])
        let out = await herramienta(inv, boveda(origen: "google.com")).run(argsJSON: args())
        XCTAssertEqual(try parse(out)["status"] as? String, "success", out)
        XCTAssertEqual(inv.argumentos.count, 2)
    }

    // MARK: atadura al origen

    func test_se_niega_en_un_origen_distinto_y_no_ejecuta_batch() async throws {
        let inv = InvocadorConStdinFalso(salidas: [url("https://evil.com/accounts.google.com"), batchOK])
        let out = await herramienta(inv, boveda()).run(argsJSON: args())
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("accounts.google.com"), out)
        XCTAssertEqual(inv.argumentos, [["--session", "gemma", "get", "url", "--json"]], "solo se preguntó la URL")
        XCTAssertTrue(inv.entradas.allSatisfy { $0 == nil }, "no se tecleó nada")
        assertSinValor(out)
    }

    func test_si_no_se_puede_leer_la_url_no_teclea() async throws {
        let inv = InvocadorConStdinFalso(salidas: [#"{"success":false,"data":null,"error":"No page open"}"#, batchOK])
        let out = await herramienta(inv, boveda()).run(argsJSON: args())
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertEqual(inv.argumentos.count, 1)
    }

    // MARK: validación antes de tocar nada

    func test_secreto_inexistente_devuelve_error() async throws {
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/"), batchOK])
        let out = await herramienta(inv, boveda()).run(argsJSON: args(secret: "otro_secreto"))
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("otro_secreto"), out)
        XCTAssertTrue(inv.argumentos.isEmpty, "no se ejecutó nada")
    }

    func test_valor_vacio_devuelve_error_sin_ejecutar() async throws {
        let almacen = AlmacenEnMemoria()
        // `guarda` rechaza vacíos: se escribe a mano lo que un almacén corrupto podría tener.
        almacen.escribir(#"["vacio"]"#, cuenta: "indice")
        almacen.escribir(#"{"value":"","etiqueta":"x","origen":"accounts.google.com"}"#, cuenta: "secreto.vacio")
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/"), batchOK])
        let out = await herramienta(inv, SecretVault(almacen: almacen)).run(argsJSON: args(secret: "vacio"))
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertTrue(inv.argumentos.isEmpty)
    }

    func test_nombre_invalido_se_rechaza_sin_tocar_la_boveda() async throws {
        let almacen = AlmacenQueCuenta()
        let inv = InvocadorConStdinFalso(salidas: [batchOK])
        let tool = herramienta(inv, SecretVault(almacen: almacen))
        for nombre in ["Gmail", "../indice", "a b", "gmail\n", String(repeating: "a", count: 41), "indice\"x"] {
            let out = await tool.run(argsJSON: args(secret: nombre))
            XCTAssertEqual(try parse(out)["status"] as? String, "error", nombre)
        }
        // Leer el índice es legítimo (el redactor lo hace con cada respuesta); lo que no puede
        // ocurrir es que se consulte una cuenta construida con el nombre inválido.
        XCTAssertEqual(almacen.cuentasLeidas.filter { $0 != "indice" }, [], "la bóveda se consultó con un nombre inválido")
        XCTAssertTrue(inv.argumentos.isEmpty)
    }

    func test_selector_que_parece_una_bandera_se_rechaza() async throws {
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/"), batchOK])
        let out = await herramienta(inv, boveda()).run(argsJSON: args(selector: "--json"))
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertTrue(inv.argumentos.isEmpty)
    }

    func test_faltan_argumentos() async throws {
        let inv = InvocadorConStdinFalso(salidas: [batchOK])
        let tool = herramienta(inv, boveda())
        for a in [#"{"secret":"gmail_password"}"#, ##"{"selector":"#pw"}"##, "no es json"] {
            let out = await tool.run(argsJSON: a)
            XCTAssertEqual(try parse(out)["status"] as? String, "error", a)
        }
        XCTAssertTrue(inv.argumentos.isEmpty)
    }

    /// R5: con el índice ilegible la bóveda no puede enumerar sus secretos y el redactor está
    /// ciego; teclear así sería teclear sin red. Se niega sin ejecutar nada.
    func test_con_el_indice_ilegible_falla_cerrado_y_no_teclea() async throws {
        let almacen = AlmacenEnMemoria()
        let vault = boveda(almacen: almacen)
        almacen.escribir("{{corrupto", cuenta: "indice")
        XCTAssertNotNil(vault.origen(de: "gmail_password"), "el registro sigue legible: solo falla el índice")
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/"), batchOK])
        let out = await herramienta(inv, vault).run(argsJSON: args())
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("bóveda"), out)
        XCTAssertTrue(inv.argumentos.isEmpty, "se ejecutó algo con la bóveda ilegible")
    }

    // MARK: redacción

    /// Una página o el CLI pueden devolver el valor en un error (p. ej. `type` lo ecoa). Debe
    /// tacharse antes de llegar al modelo.
    func test_el_eco_del_valor_en_la_salida_se_redacta() async throws {
        let fila: [String: Any] = ["error": "No se pudo rellenar con \(valor)", "index": 0, "result": NSNull(), "success": false]
        let eco = String(decoding: try JSONSerialization.data(withJSONObject: [fila]), as: UTF8.self)
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/"), eco])
        let out = await herramienta(inv, boveda()).run(argsJSON: args())
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "refused", out)
        XCTAssertTrue((json["message"] as? String ?? "").contains("[secreto: gmail_password]"), out)
        assertSinValor(out)
    }

    func test_una_salida_ilegible_que_ecoa_el_valor_se_redacta() async throws {
        let inv = InvocadorConStdinFalso(salidas: [url("https://accounts.google.com/"), "basura \(valor)"])
        let out = await herramienta(inv, boveda()).run(argsJSON: args())
        XCTAssertEqual(try parse(out)["status"] as? String, "error", out)
        assertSinValor(out)
    }

    // MARK: invocador sin entrada estándar (HTTP, dobles)

    func test_sin_un_invocador_con_stdin_falla_claro_y_no_teclea() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [url("https://accounts.google.com/"), batchOK])
        let out = await herramienta(mock, boveda()).run(argsJSON: args())
        let json = try parse(out)
        XCTAssertNotEqual(json["status"] as? String, "success")
        XCTAssertTrue((json["message"] as? String ?? "").contains(
            "browser_fill_secret solo está disponible con el navegador local de la Mac por ahora"), out)
        XCTAssertEqual(mock.receivedArguments.count, 1, "solo get url: batch no se lanzó sin stdin")
        for a in mock.receivedArguments.flatMap({ $0 }) { assertSinValor(a) }
    }

    func test_el_invocador_http_no_acepta_stdin() {
        let http: any AgentBrowserInvoking = HTTPAgentBrowserInvoker(baseURL: URL(string: "http://127.0.0.1:1")!, bearerToken: "t")
        XCTAssertNil(http as? AgentBrowserInvokingConStdin)
    }
}
