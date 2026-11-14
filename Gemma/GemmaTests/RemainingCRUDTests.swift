import XCTest
@testable import Gemma

/// Editar una alarma ya puesta.
///
/// Sin esto, "cámbiala a las siete" obligaba al modelo a cancelar y crear otra, con dos
/// oportunidades de fallar en medio: si la creación falla después de cancelar, el usuario
/// se queda sin alarma y creyendo que la tiene.
final class UpdateAlarmTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func service(
        _ system: MockSystemAlarmScheduler = MockSystemAlarmScheduler()
    ) -> ClockService {
        ClockService(
            systemScheduler: system,
            scheduler: MockClockScheduler(),
            defaults: UserDefaults(suiteName: "test.updalarm.\(UUID().uuidString)")!
        )
    }

    func test_cambiar_la_hora_conserva_el_mismo_id() async throws {
        let clock = service()
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let updated = try await clock.updateAlarm(id: created.alarm.id, hour: 7, minute: 30)

        XCTAssertEqual(updated.alarm.id, created.alarm.id, "Es la misma alarma, no otra.")
        XCTAssertEqual(updated.alarm.hour, 7)
        XCTAssertEqual(updated.alarm.minute, 30)
        XCTAssertEqual(clock.listAlarms().count, 1, "No puede quedar la vieja al lado.")
        XCTAssertEqual(clock.listAlarms().first?.hour, 7)
    }

    func test_cambiar_la_hora_la_reprograma_en_el_sistema() async throws {
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        _ = try await clock.updateAlarm(id: created.alarm.id, hour: 7, minute: 0)

        XCTAssertTrue(system.cancelled.contains(created.alarm.id), "La vieja hay que cancelarla o suena a las 6 también.")
        XCTAssertEqual(system.scheduledAlarms.filter { $0.id == created.alarm.id }.count, 1)
        XCTAssertEqual(system.scheduledAlarms.first { $0.id == created.alarm.id }?.hour, 7)
    }

    func test_cambiar_solo_el_titulo_conserva_la_hora() async throws {
        let clock = service()
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let updated = try await clock.updateAlarm(id: created.alarm.id, title: "Trabajo")

        XCTAssertEqual(updated.alarm.title, "Trabajo")
        XCTAssertEqual(updated.alarm.hour, 6)
    }

    func test_cambiar_los_dias() async throws {
        let clock = service()
        let created = try await clock.createAlarm(title: "Gimnasio", hour: 6, minute: 0)

        let updated = try await clock.updateAlarm(id: created.alarm.id, daysOfWeek: [2, 4, 6])

        XCTAssertEqual(updated.alarm.daysOfWeek, [2, 4, 6])
    }

    func test_editar_algo_que_no_existe() async throws {
        do {
            _ = try await service().updateAlarm(id: UUID(), hour: 7, minute: 0)
            XCTFail("Debe fallar en vez de crear una alarma nueva de la nada.")
        } catch {
            XCTAssertEqual(error as? ClockError, .alarmNotFound)
        }
    }

    func test_si_la_reprogramacion_falla_la_alarma_vieja_no_se_pierde() async throws {
        // Lo peor posible: cancelar la vieja, fallar al poner la nueva y dejar al usuario
        // sin alarma creyendo que la tiene.
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)
        system.errorToThrow = SystemAlarmError.limitReached

        do {
            _ = try await clock.updateAlarm(id: created.alarm.id, hour: 7, minute: 0)
            XCTFail("Debe propagar el fallo.")
        } catch {
            XCTAssertEqual(
                clock.listAlarms().first?.hour, 6,
                "Si no se pudo reprogramar, lo apuntado sigue siendo la alarma vieja."
            )
        }
    }

    // MARK: - La herramienta

    func test_tool_cambia_la_hora_buscando_por_la_vieja() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let result = try json(await UpdateAlarmTool(clockService: clock)
            .run(argsJSON: #"{"time": "06:00", "new_time": "07:30"}"#))

        XCTAssertEqual(result["status"] as? String, "updated", "Salida: \(result)")
        XCTAssertEqual(result["time"] as? String, "07:30")
        XCTAssertEqual(clock.listAlarms().first?.hour, 7)
    }

    func test_tool_cambia_por_titulo() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let result = try json(await UpdateAlarmTool(clockService: clock)
            .run(argsJSON: #"{"title": "despertar", "new_time": "07:00"}"#))

        XCTAssertEqual(result["status"] as? String, "updated")
    }

    func test_tool_sin_nada_que_cambiar() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let result = try json(await UpdateAlarmTool(clockService: clock)
            .run(argsJSON: #"{"time": "06:00"}"#))

        XCTAssertEqual(result["status"] as? String, "nothing_to_change")
    }

    func test_tool_con_dos_candidatas_pregunta() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Trabajo", hour: 6, minute: 0)
        _ = try await clock.createAlarm(title: "Gimnasio", hour: 6, minute: 0)

        let result = try json(await UpdateAlarmTool(clockService: clock)
            .run(argsJSON: #"{"time": "06:00", "new_time": "07:00"}"#))

        XCTAssertEqual(result["status"] as? String, "ambiguous")
        XCTAssertEqual(clock.listAlarms().map(\.hour), [6, 6])
    }

    func test_tool_con_hora_invalida() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let result = try json(await UpdateAlarmTool(clockService: clock)
            .run(argsJSON: #"{"time": "06:00", "new_time": "las siete"}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_time")
        XCTAssertEqual(clock.listAlarms().first?.hour, 6)
    }

    func test_tool_de_algo_que_no_existe() async throws {
        let result = try json(await UpdateAlarmTool(clockService: service())
            .run(argsJSON: #"{"time": "09:00", "new_time": "10:00"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
    }
}

/// Olvidar un atajo aprendido, y ver/olvidar los alias de contacto.
///
/// `ShortcutRegistry.forget(named:)`, `ContactAliasStore.forgetAlias(_:)` y
/// `ContactAliasStore.learned()` ya existían: lo único que faltaba era una herramienta
/// que los expusiera, así que Gemma podía aprender un alias equivocado y no desaprenderlo.
final class ForgetToolsTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func registry() -> ShortcutRegistry {
        ShortcutRegistry(defaults: UserDefaults(suiteName: "test.forget.sc.\(UUID().uuidString)")!)
    }

    private func aliases() -> ContactAliasStore {
        ContactAliasStore(defaults: UserDefaults(suiteName: "test.forget.al.\(UUID().uuidString)")!)
    }

    // MARK: - forget_shortcut

    func test_olvida_un_atajo_aprendido() async throws {
        let registry = registry()
        registry.remember(ShortcutEntry(name: "Pagar luz", purpose: "Paga la factura"))

        let result = try json(await ForgetShortcutTool(registry: registry)
            .run(argsJSON: #"{"name": "Pagar luz"}"#))

        XCTAssertEqual(result["status"] as? String, "forgotten", "Salida: \(result)")
        XCTAssertNil(registry.entry(named: "Pagar luz"))
    }

    func test_olvidar_un_atajo_que_no_conoce() async throws {
        let result = try json(await ForgetShortcutTool(registry: registry())
            .run(argsJSON: #"{"name": "Nada"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
    }

    func test_olvidar_un_atajo_exige_nombre() async throws {
        let result = try json(await ForgetShortcutTool(registry: registry()).run(argsJSON: "{}"))
        XCTAssertNotNil(result["error"] ?? result["status"])
    }

    // MARK: - list_contact_aliases / forget_contact_alias

    func test_enumera_los_alias_aprendidos() async throws {
        let store = aliases()
        store.setAlias(relationship: "mi esposa", contactTarget: "Ana Ruiz")

        let result = try json(await ListContactAliasesTool(aliasStore: store).run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "ok")
        let rows = try XCTUnwrap(result["aliases"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["contact"] as? String, "Ana Ruiz")
    }

    func test_sin_alias_lo_dice() async throws {
        let result = try json(await ListContactAliasesTool(aliasStore: aliases()).run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "empty")
    }

    func test_olvida_un_alias_equivocado() async throws {
        let store = aliases()
        store.setAlias(relationship: "el jefe de turno", contactTarget: "Quien No Era")

        let result = try json(await ForgetContactAliasTool(aliasStore: store)
            .run(argsJSON: #"{"relationship": "el jefe de turno"}"#))

        XCTAssertEqual(result["status"] as? String, "forgotten", "Salida: \(result)")
        XCTAssertNil(result["now_resolves_to"], "No había valor de fábrica detrás.")
        XCTAssertEqual(
            store.resolve(aliasOrName: "el jefe de turno"), "el jefe de turno",
            "Desaprendido: ya no resuelve al contacto equivocado."
        )
    }

    func test_olvidar_un_alias_que_tapaba_uno_de_fabrica_lo_dice() async throws {
        // Hay alias de fábrica ('hermano' entre ellos). Al borrar el aprendido vuelven a
        // valer, y afirmar "ya no asocio nada" sería mentira: el usuario lo descubriría
        // la próxima vez que dijera "llama a mi hermano".
        let store = aliases()
        store.setAlias(relationship: "mi hermano", contactTarget: "Quien No Era")

        let result = try json(await ForgetContactAliasTool(aliasStore: store)
            .run(argsJSON: #"{"relationship": "mi hermano"}"#))

        XCTAssertEqual(result["status"] as? String, "forgotten")
        XCTAssertNotNil(
            result["now_resolves_to"],
            "Hay que avisar de que volvió a valer el de fábrica."
        )
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("omisión") || message.lowercased().contains("vuelve"),
                      "El mensaje debe explicarlo: \(message)")
    }

    func test_olvidar_un_alias_que_no_existe() async throws {
        let result = try json(await ForgetContactAliasTool(aliasStore: aliases())
            .run(argsJSON: #"{"relationship": "mi primo"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
    }
}

/// Renombrar un lugar guardado.
///
/// `save_place` ya actualizaba las coordenadas de un lugar existente, pero el nombre era
/// la clave: guardarlo con otro nombre creaba un segundo pin en el mismo sitio, y Gemma
/// se quedaba con dos lugares idénticos sin saber a cuál se refería el usuario.
final class RenamePlaceTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func store() -> PlaceStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("places-\(UUID().uuidString).json")
        return PlaceStore(storageURL: url)
    }

    private func place(_ name: String) -> KnownPlace {
        KnownPlace(name: name, latitude: 25.76, longitude: -80.19)
    }

    func test_renombra_conservando_coordenadas() async throws {
        let store = store()
        store.save(place: place("Casa de Mama"))

        let result = try json(await RenamePlaceTool(placeStore: store)
            .run(argsJSON: #"{"name": "Casa de Mama", "new_name": "Casa de mamá Ana"}"#))

        XCTAssertEqual(result["status"] as? String, "renamed", "Salida: \(result)")
        XCTAssertEqual(store.list().count, 1, "Renombrar no es crear otro lugar.")
        XCTAssertEqual(store.list().first?.name, "Casa de mamá Ana")
        XCTAssertEqual(store.list().first?.latitude ?? 0, 25.76, accuracy: 0.0001)
    }

    func test_renombrar_algo_que_no_existe() async throws {
        let result = try json(await RenamePlaceTool(placeStore: store())
            .run(argsJSON: #"{"name": "Nada", "new_name": "Otro"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
    }

    func test_no_deja_dos_lugares_con_el_mismo_nombre() async throws {
        // Dos pines iguales hacen imposible resolver a cuál se refiere el usuario, que
        // es justo lo que esta herramienta viene a evitar.
        let store = store()
        store.save(place: place("Oficina"))
        store.save(place: place("Gimnasio"))

        let result = try json(await RenamePlaceTool(placeStore: store)
            .run(argsJSON: #"{"name": "Gimnasio", "new_name": "Oficina"}"#))

        XCTAssertEqual(result["status"] as? String, "name_taken")
        XCTAssertEqual(store.list().count, 2)
        XCTAssertNotNil(store.place(named: "Gimnasio"), "No se tocó nada.")
    }

    func test_renombrar_al_mismo_nombre_no_es_un_cambio() async throws {
        let store = store()
        store.save(place: place("Oficina"))

        let result = try json(await RenamePlaceTool(placeStore: store)
            .run(argsJSON: #"{"name": "Oficina", "new_name": "oficina"}"#))

        XCTAssertEqual(result["status"] as? String, "unchanged")
    }

    func test_exige_los_dos_nombres() async throws {
        let result = try json(await RenamePlaceTool(placeStore: store())
            .run(argsJSON: #"{"name": "Oficina"}"#))

        XCTAssertEqual(result["status"] as? String, "missing_fields")
    }
}
