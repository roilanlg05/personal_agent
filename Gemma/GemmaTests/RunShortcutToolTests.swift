import XCTest
@testable import Gemma

final class RunShortcutToolTests: XCTestCase {

    private func tool(
        runner: MockShortcutRunner,
        registry: ShortcutRegistry? = nil
    ) -> RunShortcutTool {
        RunShortcutTool(runner: runner, registry: registry ?? ShortcutRegistry(defaults: Self.emptyDefaults()))
    }

    private static func emptyDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "gemma.tests.shortcuts.\(UUID().uuidString)")!
        return suite
    }

    func test_metadata() {
        XCTAssertEqual(RunShortcutTool.name, "run_shortcut")
        XCTAssertFalse(RunShortcutTool.description.isEmpty)
        XCTAssertTrue(RunShortcutTool.parameters.contains { $0.name == "name" && $0.required })
    }

    func test_run_returnsOutputToTheModel() async throws {
        let runner = MockShortcutRunner(defaultResult: ShortcutRunResult(outcome: .ok, output: "1.240,50 USD"))
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "Total de ventas de hoy"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(parsed["output"] as? String, "1.240,50 USD")
        XCTAssertEqual(runner.runs.first?.name, "Total de ventas de hoy")
    }

    func test_run_passesInputThrough() async throws {
        let runner = MockShortcutRunner()
        _ = await tool(runner: runner).run(
            argsJSON: #"{"name": "Create Note", "input": "Leche\npan"}"#
        )
        XCTAssertEqual(runner.runs.first?.input, "Leche\npan")
    }

    func test_run_missingName_returnsValidErrorJSON() async throws {
        let out = await tool(runner: MockShortcutRunner()).run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["error"])
    }

    func test_run_outputWithQuotesStaysValidJSON() async throws {
        let runner = MockShortcutRunner(
            defaultResult: ShortcutRunResult(outcome: .ok, output: #"Dijo "hola" \ y se fue"#)
        )
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "X"}"#)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            "Salida inválida: \(out)"
        )
        XCTAssertEqual(parsed["output"] as? String, #"Dijo "hola" \ y se fue"#)
    }

    func test_run_cancelled_isReportedAsCancelledNotSuccess() async throws {
        let runner = MockShortcutRunner(defaultResult: ShortcutRunResult(outcome: .cancelled, output: nil))
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "X"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "cancelled")
        let message = try XCTUnwrap(parsed["message"] as? String)
        XCTAssertFalse(message.lowercased().contains("ejecutado correctamente"))
    }

    func test_run_timeout_isReported() async throws {
        let runner = MockShortcutRunner(defaultResult: ShortcutRunResult(outcome: .timedOut, output: nil))
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "X"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "timeout")
    }

    func test_run_failure_includesErrorMessage() async throws {
        let runner = MockShortcutRunner(
            defaultResult: ShortcutRunResult(outcome: .failed, output: nil, errorMessage: "El atajo no existe")
        )
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "No existe"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "failed")
        XCTAssertEqual(parsed["error_message"] as? String, "El atajo no existe")
    }

    // MARK: - Nombre desconocido: no se inventa

    func test_run_nameNotInKnownList_suggestsInsteadOfGuessing() async throws {
        let runner = MockShortcutRunner(availableNames: ["Create Note", "Total de ventas de hoy"])
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "Crear Nota"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "not_found")
        let suggestions = try XCTUnwrap(parsed["suggestions"] as? [String])
        XCTAssertTrue(suggestions.contains("Create Note"), "Debe sugerir el nombre real parecido")
        XCTAssertTrue(runner.runs.isEmpty, "No se ejecuta un atajo con nombre inventado")
    }

    func test_run_whenEnumerationUnavailable_triesAnyway() async throws {
        // En iPhone no se pueden enumerar los atajos: no hay lista contra la que validar,
        // así que se intenta y se informa de lo que diga Atajos.
        let runner = MockShortcutRunner(availableNames: nil)
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "Lo que sea"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(runner.runs.count, 1)
    }

    func test_run_exactNameIsCaseAndAccentInsensitive() async throws {
        let runner = MockShortcutRunner(availableNames: ["Nueva nota con fecha"])
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "nueva NOTA con FECHA"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(
            runner.runs.first?.name, "Nueva nota con fecha",
            "Se ejecuta con el nombre real, no con lo que escribió el modelo"
        )
    }

    func test_run_sensitiveNameIsStoppedEvenWhenUnknownToTheRegistry() async throws {
        // No hay ficha en el registro: el freno debe saltar solo por el nombre.
        let runner = MockShortcutRunner(availableNames: ["Paga mi tarjeta de chase"])
        let out = await tool(runner: runner).run(argsJSON: #"{"name": "paga mi tarjeta de CHASE"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "confirmation_required")
        XCTAssertTrue(runner.runs.isEmpty)
    }

    // MARK: - Atajos sensibles: freno obligatorio

    func test_run_sensitiveShortcut_requiresConfirmationFirst() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(
            ShortcutEntry(
                name: "Paga mi tarjeta de chase",
                purpose: "Paga la tarjeta de crédito de Chase",
                isSensitive: true
            )
        )
        let runner = MockShortcutRunner()
        let out = await tool(runner: runner, registry: registry)
            .run(argsJSON: #"{"name": "Paga mi tarjeta de chase"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "confirmation_required")
        XCTAssertTrue(runner.runs.isEmpty, "Nada que mueva dinero se ejecuta sin confirmación")
        XCTAssertNotNil(parsed["message"])
    }

    func test_run_sensitiveShortcut_runsWhenConfirmed() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(
            ShortcutEntry(name: "Paga mi tarjeta de chase", purpose: "Paga la tarjeta", isSensitive: true)
        )
        let runner = MockShortcutRunner(defaultResult: ShortcutRunResult(outcome: .ok, output: "Pago enviado"))
        let out = await tool(runner: runner, registry: registry)
            .run(argsJSON: #"{"name": "Paga mi tarjeta de chase", "confirmed": true}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(runner.runs.count, 1)
    }

    func test_run_nonSensitiveShortcut_doesNotNeedConfirmation() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(ShortcutEntry(name: "Create Note", purpose: "Crea una nota", isSensitive: false))
        let runner = MockShortcutRunner()
        let out = await tool(runner: runner, registry: registry).run(argsJSON: #"{"name": "Create Note"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ok")
    }

    // MARK: - Registro

    func test_registry_rememberAndLookupIsAccentInsensitive() {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(ShortcutEntry(name: "Nueva nota con fecha", purpose: "Crea nota fechada"))
        XCTAssertEqual(registry.entry(named: "nueva NOTA con fecha")?.name, "Nueva nota con fecha")
        XCTAssertNil(registry.entry(named: "otra cosa"))
    }

    func test_registry_persistsAcrossInstances() {
        let defaults = Self.emptyDefaults()
        let first = ShortcutRegistry(defaults: defaults)
        first.remember(ShortcutEntry(name: "Create Note", purpose: "Crea una nota", isSensitive: false))

        let second = ShortcutRegistry(defaults: defaults)
        XCTAssertEqual(second.entry(named: "Create Note")?.purpose, "Crea una nota")
    }

    func test_registry_rememberOverwritesSameName() {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(ShortcutEntry(name: "X", purpose: "viejo"))
        registry.remember(ShortcutEntry(name: "X", purpose: "nuevo", isSensitive: true))
        XCTAssertEqual(registry.all().count, 1)
        XCTAssertEqual(registry.entry(named: "X")?.purpose, "nuevo")
        XCTAssertEqual(registry.entry(named: "X")?.isSensitive, true)
    }

    func test_registry_seedsSensitiveFlagForMoneyShortcuts() {
        // Un atajo que el usuario nombra con palabras de dinero entra marcado como
        // sensible aunque nadie lo haya dicho: el fallo seguro es pedir confirmación.
        XCTAssertTrue(ShortcutRegistry.looksSensitive("Paga mi tarjeta de chase"))
        XCTAssertTrue(ShortcutRegistry.looksSensitive("Transferir dinero a mamá"))
        XCTAssertTrue(ShortcutRegistry.looksSensitive("Send payment to landlord"))
        XCTAssertFalse(ShortcutRegistry.looksSensitive("Create Note"))
        XCTAssertFalse(ShortcutRegistry.looksSensitive("Total de ventas de hoy"))
    }
}

/// El registro y la siembra son lo que impide que el modelo invente nombres.
/// El fallo real que motivó esto: el modelo reintentó 'Paga mi tarjeta de chase'
/// escribiendo 'Chase' con mayúscula y Atajos no lo encontró.
final class ShortcutNameResolutionTests: XCTestCase {

    private static func emptyDefaults() -> UserDefaults {
        UserDefaults(suiteName: "gemma.tests.shortcuts.\(UUID().uuidString)")!
    }

    func test_iOS_resolvesExactNameFromRegistryWhenEnumerationUnavailable() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(ShortcutEntry(name: "Nueva nota con fecha", purpose: "Nota fechada"))
        // availableNames nil = iPhone: no se puede enumerar.
        let runner = MockShortcutRunner(availableNames: nil)
        let tool = RunShortcutTool(runner: runner, registry: registry)

        _ = await tool.run(argsJSON: #"{"name": "nueva nota con FECHA"}"#)

        XCTAssertEqual(
            runner.runs.first?.name, "Nueva nota con fecha",
            "Debe ejecutar el nombre exacto del registro, no el que escribió el modelo"
        )
    }

    func test_iOS_sensitiveShortcutRunsWithRegistryNameAfterConfirmation() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        ShortcutSeed.apply(to: registry, defaults: Self.emptyDefaults())
        let runner = MockShortcutRunner(availableNames: nil)
        let tool = RunShortcutTool(runner: runner, registry: registry)

        // Así lo reescribió el modelo en la prueba real.
        let out = await tool.run(argsJSON: #"{"name": "Paga mi tarjeta de Chase", "confirmed": true}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(
            runner.runs.first?.name, "Paga mi tarjeta de chase",
            "Con 'Chase' en mayúscula, Atajos no lo encuentra: hay que mandar el nombre sembrado"
        )
    }

    func test_soleStrongCandidate_requiresUniqueness() {
        let known = ["Total de ventas de hoy", "Total de ventas de esta semana"]
        XCTAssertNil(
            RunShortcutTool.soleStrongCandidate(for: "Total de ventas", in: known),
            "Con dos candidatos, elegir uno sería adivinar"
        )
        XCTAssertEqual(
            RunShortcutTool.soleStrongCandidate(for: "ventas de hoy", in: known),
            "Total de ventas de hoy"
        )
        XCTAssertNil(RunShortcutTool.soleStrongCandidate(for: "xy", in: known))
    }

    func test_failedRun_includesSuggestionsFromRegistry() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(ShortcutEntry(name: "Total de ventas de hoy", purpose: "Ventas"))
        registry.remember(ShortcutEntry(name: "Create Note", purpose: "Nota"))
        let runner = MockShortcutRunner(
            availableNames: nil,
            defaultResult: ShortcutRunResult(outcome: .failed, errorMessage: "No existe")
        )
        let tool = RunShortcutTool(runner: runner, registry: registry)

        let out = await tool.run(argsJSON: #"{"name": "ventas del mes"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let suggestions = try XCTUnwrap(parsed["suggestions"] as? [String])
        XCTAssertTrue(suggestions.contains("Total de ventas de hoy"))
    }

    // MARK: - Siembra

    func test_seed_appliesOnceAndDoesNotOverwriteUserEdits() {
        let defaults = Self.emptyDefaults()
        let registry = ShortcutRegistry(defaults: defaults)
        registry.remember(ShortcutEntry(name: "Create Note", purpose: "MI propia descripción"))

        let added = ShortcutSeed.apply(to: registry, defaults: defaults)
        XCTAssertGreaterThan(added, 0)
        XCTAssertEqual(
            registry.entry(named: "Create Note")?.purpose, "MI propia descripción",
            "La siembra no pisa lo que el usuario ya corrigió"
        )

        let secondRun = ShortcutSeed.apply(to: registry, defaults: defaults)
        XCTAssertEqual(secondRun, 0, "La siembra se aplica una sola vez")
    }

    func test_seed_marksMoneyShortcutsSensitive() {
        let defaults = Self.emptyDefaults()
        let registry = ShortcutRegistry(defaults: defaults)
        ShortcutSeed.apply(to: registry, defaults: defaults)
        XCTAssertEqual(registry.entry(named: "Paga mi tarjeta de chase")?.isSensitive, true)
        XCTAssertEqual(registry.entry(named: "Total de ventas de hoy")?.isSensitive, false)
    }

    func test_seed_warnsThatCreateNoteAsksOnScreen() {
        let defaults = Self.emptyDefaults()
        let registry = ShortcutRegistry(defaults: defaults)
        ShortcutSeed.apply(to: registry, defaults: defaults)
        let purpose = registry.entry(named: "Create Note")?.purpose ?? ""
        XCTAssertTrue(
            purpose.lowercased().contains("pregunta"),
            "El modelo debe saber que ese atajo ignora el texto que se le pasa"
        )
    }

    // MARK: - list_shortcuts

    func test_listShortcuts_returnsRegistryWithSensitivity() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(ShortcutEntry(name: "Paga mi tarjeta de chase", purpose: "Paga", isSensitive: true))
        registry.remember(
            ShortcutEntry(name: "Total de ventas de hoy", purpose: "Ventas", outputDescription: "Importe")
        )
        let tool = ListShortcutsTool(runner: MockShortcutRunner(availableNames: nil), registry: registry)

        let out = await tool.run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(parsed["count"] as? Int, 2)
        let list = try XCTUnwrap(parsed["shortcuts"] as? [[String: Any]])
        let chase = try XCTUnwrap(list.first { $0["name"] as? String == "Paga mi tarjeta de chase" })
        XCTAssertEqual(chase["sensitive"] as? Bool, true)
    }

    func test_listShortcuts_reportsUndocumentedOnesWhenSystemCanEnumerate() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        registry.remember(ShortcutEntry(name: "Create Note", purpose: "Nota"))
        let tool = ListShortcutsTool(
            runner: MockShortcutRunner(availableNames: ["Create Note", "Atajo misterioso"]),
            registry: registry
        )
        let out = await tool.run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["undocumented"] as? [String], ["Atajo misterioso"])
    }

    func test_listShortcuts_emptyRegistryAsksToLearn() async throws {
        let tool = ListShortcutsTool(
            runner: MockShortcutRunner(availableNames: nil),
            registry: ShortcutRegistry(defaults: Self.emptyDefaults())
        )
        let out = await tool.run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
        XCTAssertTrue((parsed["message"] as? String ?? "").contains("remember_shortcut"))
    }

    // MARK: - remember_shortcut

    func test_rememberShortcut_storesAndIsImmediatelyRunnable() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        let remember = RememberShortcutTool(registry: registry)

        let out = await remember.run(
            argsJSON: #"{"name": "Abrir garaje", "purpose": "Abre la puerta del garaje", "sensitive": false}"#
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "remembered")

        let runner = MockShortcutRunner(availableNames: nil)
        _ = await RunShortcutTool(runner: runner, registry: registry).run(argsJSON: #"{"name": "abrir GARAJE"}"#)
        XCTAssertEqual(runner.runs.first?.name, "Abrir garaje")
    }

    func test_rememberShortcut_inferSensitivityWhenNotDeclared() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        let out = await RememberShortcutTool(registry: registry)
            .run(argsJSON: #"{"name": "Transferir a mamá", "purpose": "Manda dinero"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["sensitive"] as? Bool, true)
        XCTAssertEqual(registry.entry(named: "Transferir a mamá")?.isSensitive, true)
    }

    func test_rememberShortcut_requiresNameAndPurpose() async throws {
        let registry = ShortcutRegistry(defaults: Self.emptyDefaults())
        let tool = RememberShortcutTool(registry: registry)
        for args in ["{}", #"{"name": "X"}"#, #"{"purpose": "Y"}"#] {
            let out = await tool.run(argsJSON: args)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
            XCTAssertNotNil(parsed["error"], "Argumentos '\(args)' deberían dar error")
        }
    }
}
