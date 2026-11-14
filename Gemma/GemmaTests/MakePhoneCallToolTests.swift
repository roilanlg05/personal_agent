import XCTest
@testable import Gemma

/// `call_contact` tenía cuatro defectos, y el peor era de honestidad.
///
/// En iOS, abrir una URL `tel:` desde una app de terceros **no** inicia la llamada:
/// desde iOS 10.3 el sistema presenta una alerta de confirmación y espera a que el
/// usuario pulse "Llamar". `UIApplication.open` devuelve `true` en cuanto el sistema
/// acepta mostrar esa alerta, no cuando la llamada empieza. La herramienta tomaba ese
/// `true` como "llamando", así que Gemma decía "estoy llamando a mamá" mientras el
/// teléfono esperaba un dedo. Apple no ofrece ninguna API para marcar sin ese toque
/// (CallKit solo marca en apps VoIP, nunca por la red celular), así que lo único que se
/// puede arreglar es lo que se afirma.
///
/// Los otros tres eran los mismos que `send_message` ya resolvía y este no: elegir a
/// ciegas entre contactos homónimos, elegir a ciegas entre los números de un contacto, y
/// confundir "falta permiso de Contactos" con "no encontré a nadie".
final class MakePhoneCallToolTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func tool(
        contacts: [GemmaContact] = [],
        error: Error? = nil,
        opener: MockAppURLOpener = MockAppURLOpener(supportedSchemes: [])
    ) -> MakePhoneCallTool {
        MakePhoneCallTool(
            manager: MockContactsManager(contacts: contacts, errorToThrow: error),
            aliasStore: ContactAliasStore(defaults: UserDefaults(suiteName: "test.call.\(UUID().uuidString)")!),
            urlOpener: opener
        )
    }

    // MARK: - Honestidad: lo que de verdad pasa

    func test_abrir_el_marcador_no_es_estar_llamando() async throws {
        let result = try json(await tool(
            contacts: [GemmaContact(givenName: "Ana", familyName: "Ruiz", phoneNumbers: ["+13055551234"])]
        ).run(argsJSON: #"{"contact_or_number": "Ana"}"#))

        XCTAssertEqual(
            result["status"] as? String, "confirmation_required",
            "El sistema solo mostró la alerta: afirmar 'calling' es mentir. Salida: \(result)"
        )
        XCTAssertEqual(result["requires_user_tap"] as? Bool, true)
    }

    func test_dice_al_usuario_que_tiene_que_pulsar_llamar() async throws {
        let result = try json(await tool(
            contacts: [GemmaContact(givenName: "Ana", phoneNumbers: ["+13055551234"])]
        ).run(argsJSON: #"{"contact_or_number": "Ana"}"#))

        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(
            message.lowercased().contains("pulse") || message.lowercased().contains("confirm"),
            "El mensaje debe decir que falta el toque del usuario: \(message)"
        )
    }

    func test_la_descripcion_prohibe_afirmar_que_esta_llamando() {
        let description = MakePhoneCallTool.description.lowercased()
        XCTAssertTrue(
            description.contains("confirmation_required"),
            "El modelo necesita leer el estado real en la descripción."
        )
        XCTAssertTrue(
            description.contains("no afirmes") || description.contains("nunca afirmes"),
            "La descripción debe prohibir explícitamente afirmar la llamada."
        )
    }

    func test_si_el_sistema_no_abre_el_marcador_es_failed() async throws {
        let opener = MockAppURLOpener(supportedSchemes: [])
        opener.shouldSucceed = false
        let result = try json(await tool(
            contacts: [GemmaContact(givenName: "Ana", phoneNumbers: ["+13055551234"])],
            opener: opener
        ).run(argsJSON: #"{"contact_or_number": "Ana"}"#))

        XCTAssertEqual(result["status"] as? String, "failed")
    }

    // MARK: - La URL que se abre

    func test_marca_el_numero_directo_tal_cual() async throws {
        let opener = MockAppURLOpener(supportedSchemes: [])
        _ = await tool(opener: opener).run(argsJSON: #"{"contact_or_number": "+1 (305) 555-1234"}"#)

        let url = try XCTUnwrap(opener.openedURLs.first)
        XCTAssertEqual(url.absoluteString, "tel:+13055551234", "Se limpian separadores, se conserva el '+'.")
    }

    func test_usa_el_numero_del_contacto_resuelto() async throws {
        let opener = MockAppURLOpener(supportedSchemes: [])
        _ = await tool(
            contacts: [GemmaContact(givenName: "Ana", familyName: "Ruiz", phoneNumbers: ["305-555-9999"])],
            opener: opener
        ).run(argsJSON: #"{"contact_or_number": "Ana"}"#)

        XCTAssertEqual(opener.openedURLs.first?.absoluteString, "tel:3055559999")
    }

    // MARK: - Contactos homónimos: no se elige a ciegas

    func test_varios_contactos_que_encajan_se_preguntan() async throws {
        let result = try json(await tool(contacts: [
            GemmaContact(givenName: "María", familyName: "Gómez", phoneNumbers: ["3051111111"]),
            GemmaContact(givenName: "María", familyName: "Pérez", phoneNumbers: ["3052222222"])
        ]).run(argsJSON: #"{"contact_or_number": "María"}"#))

        XCTAssertEqual(
            result["status"] as? String, "ambiguous",
            "Llamar a la persona equivocada no se deshace. Salida: \(result)"
        )
        let candidates = try XCTUnwrap(result["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 2)
    }

    func test_un_contacto_ambiguo_no_abre_el_marcador() async throws {
        let opener = MockAppURLOpener(supportedSchemes: [])
        _ = await tool(contacts: [
            GemmaContact(givenName: "María", familyName: "Gómez", phoneNumbers: ["3051111111"]),
            GemmaContact(givenName: "María", familyName: "Pérez", phoneNumbers: ["3052222222"])
        ], opener: opener).run(argsJSON: #"{"contact_or_number": "María"}"#)

        XCTAssertTrue(opener.openedURLs.isEmpty, "No se marca a nadie mientras haya duda.")
    }

    // MARK: - Varios números del mismo contacto

    func test_un_contacto_con_varios_numeros_dice_cual_eligio() async throws {
        let result = try json(await tool(contacts: [
            GemmaContact(givenName: "Ana", phoneNumbers: ["3051111111", "3059999999"])
        ]).run(argsJSON: #"{"contact_or_number": "Ana"}"#))

        // Se marca el primero, que es el que la libreta da por principal, pero el modelo
        // tiene que poder decir "tiene dos, llamé al primero" en vez de callarlo.
        XCTAssertEqual(result["status"] as? String, "confirmation_required")
        XCTAssertEqual(result["available_numbers"] as? Int, 2)
    }

    func test_con_un_solo_numero_no_sobra_el_aviso() async throws {
        let result = try json(await tool(contacts: [
            GemmaContact(givenName: "Ana", phoneNumbers: ["3051111111"])
        ]).run(argsJSON: #"{"contact_or_number": "Ana"}"#))

        XCTAssertNil(result["available_numbers"], "Con un número no hay nada que advertir.")
    }

    // MARK: - Permiso y ausencias, contadas por separado

    func test_falta_de_permiso_no_se_cuenta_como_contacto_inexistente() async throws {
        let result = try json(await tool(
            error: NSError(domain: "Gemma", code: 403, userInfo: nil)
        ).run(argsJSON: #"{"contact_or_number": "Ana"}"#))

        XCTAssertEqual(
            result["status"] as? String, "permission_required",
            "Antes decía 'no se encontró número', y el usuario no podía saber que era el permiso."
        )
    }

    func test_contacto_que_no_existe() async throws {
        let result = try json(await tool(contacts: []).run(argsJSON: #"{"contact_or_number": "Nadie"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
        XCTAssertEqual(result["requested"] as? String, "Nadie")
    }

    func test_contacto_sin_ningun_numero() async throws {
        let result = try json(await tool(contacts: [
            GemmaContact(givenName: "Ana", familyName: "Ruiz", emailAddresses: ["ana@x.com"])
        ]).run(argsJSON: #"{"contact_or_number": "Ana"}"#))

        XCTAssertEqual(result["status"] as? String, "no_phone_number")
        XCTAssertEqual(result["contact"] as? String, "Ana Ruiz")
    }

    func test_sin_argumento_falla_claro() async throws {
        let result = try json(await tool().run(argsJSON: #"{}"#))
        XCTAssertNotNil(result["error"] ?? result["status"])
    }
}
