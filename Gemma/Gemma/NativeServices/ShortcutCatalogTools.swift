import Foundation

/// Inventario de lo que Gemma sabe ejecutar.
public final class ListShortcutsTool: AgentTool, Sendable {
    public static let name = "list_shortcuts"
    public static let description = """
    Lista los atajos que Gemma puede ejecutar, con su nombre exacto, para qué sirven, \
    qué entrada aceptan y qué devuelven. Úsala antes de run_shortcut cuando no estés \
    seguro del nombre, o cuando el usuario pregunte qué puedes hacer con sus apps. Los \
    marcados 'sensitive' exigen confirmación del usuario antes de ejecutarse. Usa \
    siempre el 'name' tal cual aparece aquí.
    """
    public static let parameters: [AgentToolParam] = []

    private let runner: any ShortcutRunning
    private let registry: ShortcutRegistry

    public init(
        runner: any ShortcutRunning = ShortcutRunnerFactory.make(),
        registry: ShortcutRegistry = .shared
    ) {
        self.runner = runner
        self.registry = registry
    }

    public func run(argsJSON: String) async -> String {
        let known = registry.all()

        // En macOS se puede preguntar al sistema. Los atajos reales que el registro no
        // conoce se listan igualmente: existen y se pueden ejecutar, solo que Gemma no
        // sabe para qué sirven.
        var undocumented: [String] = []
        if let available = await runner.listAvailableNames() {
            let knownKeys = Set(known.map { ShortcutRegistry.normalize($0.name) })
            undocumented = available.filter { !knownKeys.contains(ShortcutRegistry.normalize($0)) }
        }

        return ToolJSONOutput.object([
            "status": "ok",
            "count": known.count,
            "shortcuts": known.map { entry in
                [
                    "name": entry.name,
                    "purpose": entry.purpose,
                    "input": entry.inputDescription,
                    "output": entry.outputDescription,
                    "sensitive": entry.isSensitive
                ].compactMapValues { $0 }
            },
            "undocumented": undocumented,
            "message": known.isEmpty
                ? "Gemma todavía no conoce ningún atajo. Pídele al usuario el nombre exacto y guárdalo con remember_shortcut."
                : "\(known.count) atajos conocidos."
        ])
    }
}

/// Enseña a Gemma un atajo nuevo del usuario.
public final class RememberShortcutTool: AgentTool, Sendable {
    public static let name = "remember_shortcut"
    public static let description = """
    Guarda en la memoria de Gemma un atajo del usuario para poder ejecutarlo después. \
    Úsala cuando el usuario mencione un atajo que no esté en list_shortcuts, o cuando \
    corrija el nombre o el propósito de uno. Pide el nombre EXACTO tal como aparece en \
    la app Atajos: una mayúscula distinta hace que no se encuentre. Marca \
    sensitive=true si el atajo mueve dinero, envía mensajes, compra algo o borra algo.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "name", type: .string, description: "Nombre exacto del atajo en la app Atajos", required: true),
        AgentToolParam(name: "purpose", type: .string, description: "Para qué sirve, en una frase", required: true),
        AgentToolParam(name: "input", type: .string, description: "Qué entrada acepta, si acepta alguna", required: false),
        AgentToolParam(name: "output", type: .string, description: "Qué devuelve, si devuelve algo", required: false),
        AgentToolParam(name: "sensitive", type: .boolean, description: "true si mueve dinero, compra, envía mensajes o borra algo", required: false)
    ]

    private let registry: ShortcutRegistry

    public init(registry: ShortcutRegistry = .shared) {
        self.registry = registry
    }

    public func run(argsJSON: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'name' con el nombre exacto del atajo.")
        }
        guard let purpose = (dict["purpose"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !purpose.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'purpose' describiendo para qué sirve el atajo.")
        }

        // Si el modelo no clasifica el atajo, decide el nombre: ante la duda, sensible.
        // Estricto a propósito: solo un booleano nativo declara la sensibilidad. Una cadena se lee
        // como «no declarado» y el atajo cae en `looksSensitive`, que ante la duda lo marca
        // sensible: falla hacia el lado SEGURO (más confirmaciones, nunca menos).
        let declaredSensitive = dict["sensitive"] as? Bool
        let isSensitive = declaredSensitive ?? ShortcutRegistry.looksSensitive(name)

        let entry = ShortcutEntry(
            name: name,
            purpose: purpose,
            inputDescription: (dict["input"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            outputDescription: (dict["output"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isSensitive: isSensitive
        )
        registry.remember(entry)

        let recordId = ShortcutRegistry.record(for: entry).recordId
        return ToolJSONOutput.object([
            "status": "remembered",
            "name": entry.name,
            "sensitive": entry.isSensitive,
            // Honesto sobre dónde quedó: en el dispositivo siempre, en el servidor en
            // cuanto haya red.
            "sync": MirrorStatus.describe(kind: MirrorKind.shortcut, recordId: recordId),
            "sync_note": MirrorStatus.note(kind: MirrorKind.shortcut, recordId: recordId),
            "message": isSensitive
                ? "Atajo '\(entry.name)' guardado. Se tratará como sensible: pedirá confirmación antes de ejecutarse."
                : "Atajo '\(entry.name)' guardado. Ya puedes ejecutarlo con run_shortcut."
        ])
    }
}
