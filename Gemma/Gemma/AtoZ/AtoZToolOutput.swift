import Foundation

/// La salida de las tres herramientas de Amazon A to Z, en el contrato `status` que habla el
/// resto del registro.
///
/// POR QUÉ ES UNA PIEZA APARTE Y PURA. `add_shift` y `drop_shift` devuelven dos enumeraciones
/// (`AtoZAddShiftResult`, `AtoZDropShiftResult`) que son idénticas caso por caso, y el camino
/// que las produce atraviesa `AtoZClient.shared`: sesión, caché de oportunidades y red. Una
/// traducción escrita dentro de cada herramienta solo se podría medir levantando todo eso. Aquí
/// la decisión —qué `status` le toca a cada resultado— es una función pura sobre un enum cerrado,
/// y se mide entera sin red ni ajustes.
enum AtoZToolOutput {

    /// Para qué se pide el turno. Solo cambia la redacción del `message` que lee el modelo.
    enum Action {
        case add
        case drop

        var nombre: String {
            switch self {
            case .add: return "add_shift"
            case .drop: return "drop_shift"
            }
        }

        var verbo: String {
            switch self {
            case .add: return "aceptar"
            case .drop: return "soltar"
            }
        }

        var participio: String {
            switch self {
            case .add: return "aceptado"
            case .drop: return "soltado"
            }
        }
    }

    /// Las cinco formas que puede tomar una petición de turno, normalizadas.
    ///
    /// `AtoZAddShiftResult` y `AtoZDropShiftResult` son el mismo enum escrito dos veces, y sus
    /// dos casos con éxito llevan la oportunidad entera cuando lo único que la salida necesita es
    /// su descripción. Normalizarlas a `String` deja esta traducción medible sin construir una
    /// `AtoZShiftOpportunity` ni un cliente.
    enum Outcome: Equatable {
        case confirmationRequired(String)
        case dryRun(String)
        case confirmed(String)
        case unknownOutcome(String, String)
        case failed(AtoZFailure)
    }

    /// El `status` de cada resultado, y por qué cada uno.
    ///
    /// | resultado | `status` | por qué |
    /// |---|---|---|
    /// | `confirmationRequired` | `confirmation_required` | Ya está en `needsYouStatuses`: ni éxito ni fallo, la fila lo pinta con su icono propio. La herramienta no pudo seguir y espera algo del usuario, que es la definición. |
    /// | `dryRun` | `dry_run` | **Nada se envió a Amazon.** Es el camino NORMAL —`AtoZConfig` trae el modo simulado activado de fábrica—, así que pintarlo «listo» sería mentirle al usuario sobre la herramienta que le coge turnos de trabajo. Estado nuevo con su frase propia en `ToolLogRow`: ni «listo» ni «falló». |
    /// | `confirmed` | `success` | El turno se pidió Y se verificó en el horario. Es el contrato, y reinicia el presupuesto de fallos. |
    /// | `unknownOutcome` | `unknown` | Ya está en `needsYouStatuses`. La mutación se envió y la verificación no resolvió: lo honesto es que el usuario lo mire en su app, que es justo lo que dice el mensaje. |
    /// | `failed` | `failed` | Todos los `AtoZFailure` significan «no pude» y repetir no lo cambia (sesión caducada, acceso suspendido, turno ya cogido, error del servidor). El detalle fino viaja al modelo en `message` y en `reason`, que es donde le sirve; traducir once casos a once estados distintos no cambiaría nada de lo que el usuario ve ni de lo que el bucle hace. |
    static func json(_ outcome: Outcome, action: Action) -> String {
        switch outcome {
        case .confirmationRequired(let prompt):
            return ToolJSONOutput.object([
                "status": "confirmation_required",
                "action": action.nombre,
                "message": prompt
            ])
        case .dryRun(let desc):
            return ToolJSONOutput.object([
                "status": "dry_run",
                "action": action.nombre,
                "message": "MODO SIMULADO: se validó todo y NO se envió nada a Amazon, así que el turno NO se \(action.participio). Dile al usuario exactamente eso y que puede desactivar el «Modo simulado (Dry Run)» en Ajustes. \(desc)"
            ])
        case .confirmed(let desc):
            return ToolJSONOutput.object([
                "status": "success",
                "action": action.nombre,
                "shift": desc,
                "message": "Turno \(action.participio) y verificado en el horario del usuario: \(desc)."
            ])
        case .unknownOutcome(let desc, let reason):
            return ToolJSONOutput.object([
                "status": "unknown",
                "action": action.nombre,
                "shift": desc,
                "reason": reason,
                "message": "Resultado INCIERTO para el turno \(desc): \(reason). No se reintenta automáticamente, por seguridad. Dile al usuario que no se sabe si quedó hecho y que lo verifique en su app de A to Z."
            ])
        case .failed(let failure):
            return ToolJSONOutput.object([
                "status": "failed",
                "action": action.nombre,
                "reason": failure.userMessage,
                "message": "No se pudo \(action.verbo) el turno: \(failure.userMessage)"
            ])
        }
    }

    /// La consulta de turnos disponibles. Una lista vacía es un ÉXITO sin nada que contar
    /// (`no_content`, que `Agent.estadosDeExito` reconoce) y no un fallo: la consulta funcionó y
    /// lo que devuelve es información. Si saliera como fallo, cinco consultas a semanas sin
    /// turnos matarían el turno del usuario.
    static func listJSON(_ shifts: [AtoZShiftOpportunity]) -> String {
        guard !shifts.isEmpty else {
            return ToolJSONOutput.object([
                "status": "no_content",
                "count": 0,
                "message": "No hay ningún turno disponible en ese período. Dilo tal cual; no amplíes el rango por tu cuenta."
            ])
        }
        return ToolJSONOutput.object([
            "status": "success",
            "count": shifts.count,
            // El `id` es lo que `add_shift` necesita después, así que viaja por su propia clave y
            // no incrustado en una línea de texto que el modelo tenga que recortar.
            "shifts": shifts.map { opp in
                ([
                    "id": opp.id,
                    "type": opp.type,
                    "when": AtoZFormat.describe(opp),
                    "eligible": opp.isEligible,
                    "unclaimable_reasons": opp.unclaimableReasonCodes.isEmpty ? nil : opp.unclaimableReasonCodes
                ] as [String: Any?]).compactMapValues { $0 }
            },
            "message": "Hay \(shifts.count) turno(s). Los que traen 'eligible': false NO se pueden coger; di por qué si el usuario pregunta."
        ])
    }

    /// Un fallo de la consulta de turnos. Es `failed` por lo mismo que el de las mutaciones.
    static func listFailureJSON(_ reason: String) -> String {
        ToolJSONOutput.object([
            "status": "failed",
            "reason": reason,
            "message": "No se pudieron consultar los turnos: \(reason). Dile al usuario que no pudiste mirar; NO le digas que no hay turnos."
        ])
    }

    /// Falta el identificador de la oportunidad. `missing_fields` es el estado que el resto del
    /// registro usa para un argumento que no llegó, y no gasta presupuesto de fallos: el modelo
    /// puede arreglarlo él mismo consultando primero los turnos.
    static func missingOpportunityID(action: Action) -> String {
        ToolJSONOutput.object([
            "status": "missing_fields",
            "required": ["shift_opportunity_id"],
            "action": action.nombre,
            "message": "Falta 'shift_opportunity_id'. Llama primero a list_available_shifts y usa el ID que devuelve; no te lo inventes."
        ])
    }
}
