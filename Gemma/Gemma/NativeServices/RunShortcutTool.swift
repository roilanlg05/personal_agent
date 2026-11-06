import Foundation

public final class RunShortcutTool: AgentTool, Sendable {
    public static let name = "run_shortcut"
    public static let description = """
    Ejecuta un atajo de la app Atajos del usuario y devuelve su salida. Es la vía para \
    actuar sobre apps que no tienen API propia (crear notas, consultar el banco, \
    reproducir en Spotify, domótica). Úsala SOLO con el nombre exacto de un atajo que \
    conozcas por list_shortcuts o porque el usuario te lo dijo: nunca inventes nombres. \
    'status' puede ser 'ok' (terminó; mira 'output'), 'not_found' (el nombre no existe; \
    mira 'suggestions'), 'confirmation_required' (es un atajo sensible: pregunta al \
    usuario y vuelve a llamar con confirmed=true solo si acepta), 'cancelled' (el \
    usuario lo canceló), 'timeout', 'failed' o 'not_available'. Informa exactamente lo \
    que diga 'status': no afirmes que algo se hizo si no es 'ok'.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "name", type: .string, description: "Nombre exacto del atajo a ejecutar", required: true),
        AgentToolParam(name: "input", type: .string, description: "Texto que se pasa al atajo como entrada, si acepta alguna", required: false),
        AgentToolParam(name: "confirmed", type: .boolean, description: "Solo para atajos sensibles: true cuando el usuario YA ha confirmado explícitamente en este momento de la conversación", required: false)
    ]

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
        guard let arguments = Self.parseArguments(argsJSON),
              let requestedName = arguments.name, !requestedName.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'name' con el nombre exacto del atajo.")
        }

        // El nombre tiene que ser exacto: Atajos no perdona una mayúscula distinta. El
        // modelo reescribe los nombres al reintentar (fue lo que rompió la primera
        // prueba de 'Paga mi tarjeta de chase', que pasó a 'Chase'), así que nunca se
        // usa el nombre tal como lo escribió: se resuelve contra lo que se conoce.
        let knownNames = registry.all().map(\.name)
        var effectiveName = requestedName

        if let available = await runner.listAvailableNames() {
            // macOS: el sistema sabe la verdad.
            if let exact = Self.match(requestedName, in: available) {
                effectiveName = exact
            } else {
                return ToolJSONOutput.object([
                    "status": "not_found",
                    "requested_name": requestedName,
                    "suggestions": Self.suggestions(for: requestedName, in: available),
                    "message": "No existe un atajo llamado '\(requestedName)'. Pregúntale al usuario cuál quiere o usa list_shortcuts."
                ])
            }
        } else if let exact = Self.match(requestedName, in: knownNames) {
            // iOS: no se puede enumerar, pero el registro guarda el nombre exacto.
            effectiveName = exact
        } else if let onlyCandidate = Self.soleStrongCandidate(for: requestedName, in: knownNames) {
            // Un único atajo conocido se parece lo bastante: se usa su nombre real.
            effectiveName = onlyCandidate
        }
        // Si no se conoce de nada, se intenta tal cual: el usuario puede tener atajos
        // que Gemma no ha registrado todavía.

        // Freno de los atajos sensibles. Se mira el registro y, si no hay ficha, el
        // propio nombre: un atajo que suena a pagar no se ejecuta por iniciativa del
        // modelo.
        let entry = registry.entry(named: effectiveName)
        let isSensitive = entry?.isSensitive ?? ShortcutRegistry.looksSensitive(effectiveName)
        if isSensitive, arguments.confirmed != true {
            return ToolJSONOutput.object([
                "status": "confirmation_required",
                "shortcut": effectiveName,
                "purpose": entry?.purpose,
                "message": "'\(effectiveName)' puede mover dinero o hacer algo difícil de deshacer. Pregúntale al usuario si quiere ejecutarlo y, solo si dice que sí, vuelve a llamar con confirmed=true."
            ])
        }

        let result = await runner.run(name: effectiveName, input: arguments.input)

        // Cuando Atajos dice que falló, lo más probable es que el nombre no exista en
        // este dispositivo. Se le dan al modelo los nombres parecidos que sí conoce,
        // para que pregunte o reintente bien en vez de insistir con el mismo error.
        var suggestions: [String]? = nil
        if result.outcome == .failed, !knownNames.isEmpty {
            suggestions = Self.suggestions(for: requestedName, in: knownNames)
        }

        return ToolJSONOutput.object([
            "status": result.outcome.rawValue,
            "shortcut": effectiveName,
            "output": result.output,
            "error_message": result.errorMessage,
            "suggestions": suggestions,
            "message": Self.message(for: result, shortcut: effectiveName)
        ])
    }

    /// Único candidato fuerte entre los nombres conocidos, o `nil` si hay cero o varios.
    ///
    /// Se exige unicidad a propósito: con dos candidatos, elegir uno sería adivinar, y
    /// adivinar con atajos que mueven dinero es inaceptable.
    static func soleStrongCandidate(for requested: String, in known: [String]) -> String? {
        let key = ShortcutRegistry.normalize(requested)
        guard key.count >= 3 else { return nil }
        let matches = known.filter { candidate in
            let normalized = ShortcutRegistry.normalize(candidate)
            return normalized.contains(key) || key.contains(normalized)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Mensajes

    static func message(for result: ShortcutRunResult, shortcut: String) -> String {
        switch result.outcome {
        case .ok:
            if let output = result.output, !output.isEmpty {
                return "El atajo '\(shortcut)' terminó y devolvió un resultado."
            }
            return "El atajo '\(shortcut)' terminó. No devolvió ninguna salida."
        case .cancelled:
            return "El usuario canceló '\(shortcut)' en la app Atajos. No se hizo nada."
        case .timedOut:
            return "'\(shortcut)' no respondió a tiempo. Puede que siga abierto en la app Atajos; no se sabe si llegó a completarse."
        case .failed:
            return "'\(shortcut)' falló. \(result.errorMessage ?? "Atajos no explicó el motivo.")"
        case .notAvailable:
            return "La app Atajos no está disponible en este dispositivo."
        }
    }

    // MARK: - Nombres

    /// Busca el nombre real, ignorando mayúsculas y acentos.
    static func match(_ requested: String, in available: [String]) -> String? {
        let key = ShortcutRegistry.normalize(requested)
        return available.first { ShortcutRegistry.normalize($0) == key }
    }

    /// Nombres parecidos, para que el modelo pregunte en vez de adivinar.
    static func suggestions(for requested: String, in available: [String]) -> [String] {
        let key = ShortcutRegistry.normalize(requested)
        let words = Set(key.split(separator: " ").map(String.init).filter { $0.count >= 3 })

        let scored = available.map { candidate -> (name: String, score: Int) in
            let normalized = ShortcutRegistry.normalize(candidate)
            var score = 0
            if normalized.contains(key) || key.contains(normalized) { score += 10 }
            score += words.filter { normalized.contains($0) }.count * 3
            // Un parecido débil: comparten la primera palabra significativa.
            if let firstWord = words.first, normalized.hasPrefix(firstWord) { score += 1 }
            return (candidate, score)
        }

        let relevant = scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        if relevant.isEmpty {
            // Nada se parece: se ofrecen unos pocos para que el usuario elija.
            return Array(available.prefix(5))
        }
        return relevant.prefix(5).map(\.name)
    }

    // MARK: - Argumentos

    private struct Arguments {
        let name: String?
        let input: String?
        let confirmed: Bool?
    }

    private static func parseArguments(_ json: String) -> Arguments? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = dict["input"] as? String
        var confirmed = dict["confirmed"] as? Bool
        if confirmed == nil, let text = dict["confirmed"] as? String {
            confirmed = ["true", "si", "sí", "yes", "1"].contains(text.lowercased())
        }
        return Arguments(name: name, input: input, confirmed: confirmed)
    }
}
