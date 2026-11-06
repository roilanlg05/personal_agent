import XCTest
@testable import Gemma

/// Pruebas de las tres herramientas de contactos y redacción que hasta ahora solo
/// estaban cubiertas de refilón por los tests de escapado JSON.
///
/// El hilo común de lo que se verifica aquí es el contrato de honestidad: una
/// herramienta que no pudo mirar la libreta no puede devolver lo mismo que una que
/// miró y no encontró nada, y una herramienta que no entendió un argumento no puede
/// sustituirlo en silencio por un valor por omisión.

// MARK: - Utilidades

private func testDefaults(_ name: String) -> UserDefaults {
    let suite = "gemma.tests.contacts.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func permissionError() -> NSError {
    NSError(domain: "ContactsService", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Permiso denegado para acceder a Contactos"])
}

private func decode(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return [:]
    }
    return dict
}

// MARK: - search_contacts

final class SearchContactsToolTests: XCTestCase {

    private func contact(_ given: String, family: String = "", phones: [String] = ["+15551234567"]) -> GemmaContact {
        GemmaContact(givenName: given, familyName: family, phoneNumbers: phones)
    }

    private func tool(
        contacts: MockContactsManager,
        aliases: ContactAliasStore = ContactAliasStore(defaults: testDefaults("search"))
    ) -> SearchContactsTool {
        SearchContactsTool(manager: contacts, aliasStore: aliases)
    }

    func test_encuentra_contactos_y_lo_dice_como_found() async {
        let manager = MockContactsManager(contacts: [contact("Marcos", family: "Pérez")])
        let result = await tool(contacts: manager).run(argsJSON: #"{"query":"Marcos"}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "found")
        XCTAssertEqual(json["count"] as? Int, 1)
        XCTAssertEqual((json["contacts"] as? [[String: Any]])?.first?["fullName"] as? String, "Marcos Pérez")
    }

    func test_sin_resultados_es_not_found_no_ok() async {
        // Un 'ok' con cero resultados obliga al modelo a interpretar el conteo. Si se
        // despista, le dice al usuario que buscó bien y no hay nadie.
        let manager = MockContactsManager(contacts: [contact("Marcos")])
        let result = await tool(contacts: manager).run(argsJSON: #"{"query":"Fulano"}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "not_found")
        XCTAssertEqual(json["count"] as? Int, 0)
    }

    func test_sin_permiso_no_puede_parecer_que_no_hay_contactos() async {
        // Éste es el defecto que motivó estas pruebas: el error genérico hacía que el
        // modelo contara "no encontré a nadie con ese nombre" cuando en realidad iOS
        // no le dejó abrir la libreta.
        let manager = MockContactsManager(errorToThrow: permissionError())
        let result = await tool(contacts: manager).run(argsJSON: #"{"query":"Marcos"}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "permission_required")
        XCTAssertNil(json["count"], "Sin permiso no hay conteo que dar: cero sería mentira.")
    }

    func test_un_fallo_cualquiera_tampoco_es_not_found() async {
        let manager = MockContactsManager(errorToThrow: NSError(domain: "CNErrorDomain", code: 999))
        let result = await tool(contacts: manager).run(argsJSON: #"{"query":"Marcos"}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "failed")
    }

    func test_resuelve_el_alias_antes_de_buscar() async {
        let aliases = ContactAliasStore(defaults: testDefaults("alias-resolve"))
        aliases.setAlias(relationship: "mi jefe", contactTarget: "Carlos Pérez")
        let manager = MockContactsManager(contacts: [contact("Carlos", family: "Pérez")])

        let result = await tool(contacts: manager, aliases: aliases).run(argsJSON: #"{"query":"mi jefe"}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "found")
        XCTAssertEqual(json["searched_query"] as? String, "mi jefe")
        XCTAssertEqual(json["resolved_target"] as? String, "Carlos Pérez")
    }

    func test_si_el_alias_resolvio_y_no_hubo_nada_avisa_que_el_alias_puede_estar_mal() async {
        // Buscar "mi jefe" y no encontrar nada no significa que el usuario no tenga
        // jefe: significa que el alias apunta a un nombre que no está en la libreta.
        // Son dos consejos distintos para el usuario.
        let aliases = ContactAliasStore(defaults: testDefaults("alias-stale"))
        aliases.setAlias(relationship: "mi jefe", contactTarget: "Carlos Pérez")
        let manager = MockContactsManager(contacts: [contact("Marcos")])

        let result = await tool(contacts: manager, aliases: aliases).run(argsJSON: #"{"query":"mi jefe"}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "not_found")
        XCTAssertEqual(json["alias_used"] as? Bool, true)
        let message = (json["message"] as? String) ?? ""
        XCTAssertTrue(message.contains("Carlos Pérez"),
                      "El mensaje tiene que decir a qué nombre se tradujo el apodo: \(message)")
    }

    func test_query_vacio_pide_el_dato_en_vez_de_buscar() async {
        let manager = MockContactsManager(contacts: [contact("Marcos")])
        let result = await tool(contacts: manager).run(argsJSON: #"{"query":"   "}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "missing_fields")
    }

    func test_recorta_la_lista_para_no_volcar_la_libreta_entera() async {
        let many = (1...60).map { contact("Contacto\($0)") }
        let manager = MockContactsManager(contacts: many)
        let result = await tool(contacts: manager).run(argsJSON: #"{"query":"Contacto"}"#)
        let json = decode(result)

        XCTAssertEqual(json["status"] as? String, "found")
        XCTAssertEqual(json["count"] as? Int, 60, "El conteo tiene que ser el real, no el recortado.")
        XCTAssertEqual((json["contacts"] as? [[String: Any]])?.count, 25)
        XCTAssertEqual(json["truncated"] as? Bool, true)
    }
}

// MARK: - remember_contact_alias

final class RememberContactAliasToolTests: XCTestCase {

    private func contact(_ given: String, family: String = "") -> GemmaContact {
        GemmaContact(givenName: given, familyName: family, phoneNumbers: ["+15551234567"])
    }

    func test_guarda_el_alias_cuando_el_contacto_existe() async {
        let store = ContactAliasStore(defaults: testDefaults("remember-ok"))
        let manager = MockContactsManager(contacts: [contact("Carlos", family: "Pérez")])
        let tool = RememberContactAliasTool(aliasStore: store, contacts: manager)

        let json = decode(await tool.run(argsJSON: #"{"relationship":"mi jefe","contact":"Carlos Pérez"}"#))

        XCTAssertEqual(json["status"] as? String, "remembered")
        XCTAssertEqual(json["verified_in_contacts"] as? Bool, true)
        XCTAssertEqual(store.resolve(aliasOrName: "mi jefe"), "Carlos Pérez")
    }

    func test_no_guarda_un_alias_que_apunta_a_un_contacto_inexistente() async {
        // El mensaje viejo prometía "ya puedes usar ese apodo para llamar o escribir".
        // Con un nombre que no está en la libreta esa promesa no se cumple, y el
        // usuario se enterará la próxima vez que pida llamar.
        let store = ContactAliasStore(defaults: testDefaults("remember-missing"))
        let manager = MockContactsManager(contacts: [contact("Marcos")])
        let tool = RememberContactAliasTool(aliasStore: store, contacts: manager)

        let json = decode(await tool.run(argsJSON: #"{"relationship":"mi jefe","contact":"Carlos Pérez"}"#))

        XCTAssertEqual(json["status"] as? String, "contact_not_found")
        XCTAssertEqual(store.learned()["mi jefe"], nil, "No se guarda un alias roto.")
    }

    func test_sin_permiso_guarda_pero_declara_que_no_pudo_verificar() async {
        // Aquí sí se guarda: no poder mirar la libreta no es razón para perder lo que
        // el usuario acaba de enseñar. Pero no se puede decir que esté comprobado.
        let store = ContactAliasStore(defaults: testDefaults("remember-blind"))
        let manager = MockContactsManager(errorToThrow: permissionError())
        let tool = RememberContactAliasTool(aliasStore: store, contacts: manager)

        let json = decode(await tool.run(argsJSON: #"{"relationship":"mi jefe","contact":"Carlos Pérez"}"#))

        XCTAssertEqual(json["status"] as? String, "remembered_unverified")
        XCTAssertEqual(json["verified_in_contacts"] as? Bool, false)
        XCTAssertEqual(store.resolve(aliasOrName: "mi jefe"), "Carlos Pérez")
    }

    func test_avisa_cuando_varios_contactos_llevan_ese_nombre() async {
        let store = ContactAliasStore(defaults: testDefaults("remember-ambiguous"))
        let manager = MockContactsManager(contacts: [
            contact("Carlos", family: "Pérez"),
            contact("Carlos", family: "Pérez Gómez")
        ])
        let tool = RememberContactAliasTool(aliasStore: store, contacts: manager)

        let json = decode(await tool.run(argsJSON: #"{"relationship":"mi jefe","contact":"Carlos Pérez"}"#))

        XCTAssertEqual(json["status"] as? String, "remembered_ambiguous")
        XCTAssertEqual((json["candidates"] as? [String])?.count, 2)
        XCTAssertEqual(store.resolve(aliasOrName: "mi jefe"), "Carlos Pérez")
    }

    func test_falta_relationship() async {
        let store = ContactAliasStore(defaults: testDefaults("remember-missing-field"))
        let tool = RememberContactAliasTool(aliasStore: store, contacts: MockContactsManager())
        let json = decode(await tool.run(argsJSON: #"{"contact":"Carlos"}"#))

        XCTAssertEqual(json["status"] as? String, "missing_fields")
        XCTAssertEqual((json["required"] as? [String]), ["relationship"])
    }
}

// MARK: - draft_message

final class DraftMessageToolTests: XCTestCase {

    func test_tono_desconocido_no_se_sustituye_en_silencio() async {
        // Antes, cualquier tono que no fuera 'friend'/'business'/'family' caía a
        // amistoso. El usuario pedía un mensaje formal para su abogado y recibía un
        // saludo de colegas, con el modelo convencido de haber redactado algo formal.
        let json = decode(await DraftMessageTool().run(
            argsJSON: #"{"recipient":"Lic. Pérez","raw_idea":"necesito la escritura","tone":"solemne"}"#))

        XCTAssertEqual(json["status"] as? String, "invalid_tone")
        XCTAssertEqual(json["received"] as? String, "solemne")
        XCTAssertNil(json["drafted_message"], "Con el tono mal entendido no se entrega borrador.")
    }

    func test_entiende_los_tonos_en_espanol() async {
        let cases: [(String, String)] = [
            ("formal", "business"), ("trabajo", "business"), ("negocios", "business"),
            ("amigo", "friend"), ("informal", "friend"),
            ("familia", "family"), ("familiar", "family")
        ]
        for (input, expected) in cases {
            let json = decode(await DraftMessageTool().run(
                argsJSON: #"{"recipient":"Ana","raw_idea":"nos vemos","tone":"\#(input)"}"#))
            XCTAssertEqual(json["status"] as? String, "drafted", "tono '\(input)'")
            XCTAssertEqual(json["tone"] as? String, expected, "tono '\(input)'")
        }
    }

    func test_sin_tono_usa_amistoso_y_lo_declara() async {
        let json = decode(await DraftMessageTool().run(
            argsJSON: #"{"recipient":"Ana","raw_idea":"nos vemos"}"#))

        XCTAssertEqual(json["status"] as? String, "drafted")
        XCTAssertEqual(json["tone"] as? String, "friend")
        XCTAssertEqual(json["tone_defaulted"] as? Bool, true,
                       "El modelo tiene que saber que el tono lo eligió la herramienta, no el usuario.")
    }

    func test_falta_la_idea() async {
        let json = decode(await DraftMessageTool().run(argsJSON: #"{"recipient":"Ana"}"#))

        XCTAssertEqual(json["status"] as? String, "missing_fields")
        XCTAssertEqual((json["required"] as? [String]), ["raw_idea"])
    }

    func test_el_borrador_no_mete_jerga_regional() async {
        // La plantilla venía con jerga mexicana fija. El usuario es cubano: una
        // plantilla no debería elegirle el registro.
        let json = decode(await DraftMessageTool().run(
            argsJSON: #"{"recipient":"Ana","raw_idea":"nos vemos","tone":"amigo"}"#))
        let draft = (json["drafted_message"] as? String) ?? ""

        XCTAssertFalse(draft.lowercased().contains("qué onda"), "Jerga regional en el borrador: \(draft)")
        XCTAssertTrue(draft.contains("Ana"))
        XCTAssertTrue(draft.contains("nos vemos"))
    }

    func test_declara_que_el_borrador_es_una_plantilla() async {
        // El modelo que conduce a Gemma redacta mejor que esta plantilla. Si no se le
        // dice que lo que recibe es un relleno mecánico, lo manda tal cual.
        let json = decode(await DraftMessageTool().run(
            argsJSON: #"{"recipient":"Ana","raw_idea":"nos vemos","tone":"amigo"}"#))

        XCTAssertEqual(json["is_template"] as? Bool, true)
    }

    func test_parse_de_tono_rechaza_lo_que_no_entiende() {
        XCTAssertEqual(MessageTone.parse("formal"), .business)
        XCTAssertEqual(MessageTone.parse("FAMILIA"), .family)
        XCTAssertEqual(MessageTone.parse(nil), nil)
        XCTAssertEqual(MessageTone.parse("solemne"), nil)
        XCTAssertEqual(MessageTone.parse(""), nil)
    }
}
