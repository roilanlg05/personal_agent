import Foundation

public final class CurrentActivityTool: AgentTool, Sendable {
    public static let name = "get_current_activity"
    public static let description = """
    Dice qué está haciendo el usuario físicamente según el sensor de movimiento: \
    conduciendo, caminando, corriendo, en bici o quieto. Lee 'status': 'ok' = hay una \
    medición real, y entonces vienen 'activity', 'confidence' y 'is_driving'; \
    'permission_required' = falta el permiso de Movimiento, pídeselo al usuario; \
    'unsupported' = el dispositivo no tiene el sensor; 'unknown' = el sensor funciona \
    pero no hay ninguna medición de los últimos minutos. Con cualquier estado distinto \
    de 'ok' no sabes qué está haciendo el usuario: no lo supongas ni digas que está \
    quieto, pregúntale.
    """
    public static let parameters: [AgentToolParam] = []

    private let motionService: MotionActivityService

    public init(motionService: MotionActivityService = MotionActivityService()) {
        self.motionService = motionService
    }

    public func run(argsJSON: String) async -> String {
        switch await motionService.currentActivity() {
        case .reading(let snapshot):
            return ToolJSONOutput.object([
                "status": "ok",
                "activity": snapshot.state.rawValue,
                "confidence": snapshot.confidence,
                "is_driving": snapshot.state == .automotive,
                "measured_at": ISO8601DateFormatter().string(from: snapshot.timestamp)
            ])

        case .unknown(let reason):
            // Ningún campo de actividad: lo que no se midió no se nombra, para que el
            // modelo no tenga nada que repetir como si fuera un dato.
            switch reason {
            case .permissionDenied:
                return ToolJSONOutput.object([
                    "status": "permission_required",
                    "reason": reason.rawValue,
                    "message": "Gemma necesita permiso de Movimiento y Estado Físico. Pídele al usuario que lo active en Ajustes."
                ])
            case .unavailable:
                return ToolJSONOutput.object([
                    "status": "unsupported",
                    "reason": reason.rawValue,
                    "message": "Este dispositivo no puede detectar la actividad física."
                ])
            case .noRecentData:
                return ToolJSONOutput.object([
                    "status": "unknown",
                    "reason": reason.rawValue,
                    "message": "No hay ninguna medición de movimiento de los últimos minutos. Pregúntale al usuario qué está haciendo."
                ])
            }
        }
    }
}
