import Foundation

/// Compuerta entre los tokens que llegan del modelo y los que se le enseñan al usuario.
///
/// Por qué existe: algunos modelos escriben la llamada a una herramienta COMO TEXTO dentro
/// del contenido (`<function name="browser_click"><parameter ...>`). Los tokens se emiten en
/// vivo, así que cuando el parser ve el mensaje completo la sintaxis ya está en pantalla:
/// limpiar solo el texto final no arregla nada. En el chat del 2026-11-08 el mensaje empezaba
/// con prosa corriente, la decisión de «¿es una llamada?» se tomaba una sola vez al principio
/// y desde entonces todo, sintaxis incluida, se emitía sin mirar.
///
/// Qué hace: deja pasar la prosa con el menor retraso posible y retiene SOLO la cola que
/// todavía podría convertirse en un inicio de llamada (`<function`, `<tool_call`…). Cuando se
/// resuelve, o bien se confirma —y desde ese punto se descarta lo que resta del mensaje; el
/// texto limpio definitivo llega por `.completed`— o bien resulta ser prosa y se suelta. Es el
/// mismo patrón que `thoughtBuffer` en `ServerRuntime`: retener una cola corta, no el mensaje.
///
/// Es un tipo de valor sin E/S para poder probarlo sin red ni simulador.
struct ToolSyntaxStreamGate {
    enum Phase: Equatable {
        /// Aún no se sabe cómo empieza el mensaje (solo ocurre si se pidió `checksStart`).
        case undecided
        case streaming
        /// Se confirmó sintaxis de herramienta: todo lo que sigue se descarta.
        case suppressing
    }

    private(set) var phase: Phase
    /// Lo ya entregado al usuario, para cuadrar el texto limpio final contra él.
    private(set) var emitted = ""
    private var held = ""

    /// Inicios de llamada que se reconocen en cualquier punto del mensaje. Se necesita un
    /// carácter más para confirmarlos (`<functions` no es `<function`).
    private static let openers = ["<function", "<parameter", "<execute_tool", "<tool_call", "<|tool_call", "<|tool"]
    /// Solo cuentan al principio del mensaje: `call:` aparece en prosa legítima y `{` es JSON
    /// normal en medio de un texto.
    private static let startOnly = ["call:"]

    /// `checksStart` conserva la regla histórica del camino OpenAI: un mensaje que EMPIEZA por
    /// `{` o `call:` es una llamada y no se muestra. El camino de Anthropic recibe las
    /// llamadas como `tool_use` estructurado y un mensaje que empiece por `{` es una respuesta
    /// JSON legítima, así que ahí se usa solo la detección en mitad del texto.
    init(checksStart: Bool) {
        phase = checksStart ? .undecided : .streaming
    }

    /// Texto que ya se puede mostrar tras recibir `piece` (vacío si se retiene).
    mutating func feed(_ piece: String) -> String {
        held += piece
        if phase == .suppressing { held = ""; return "" }

        if phase == .undecided {
            let t = held.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return "" }
            let tools = Self.openers + Self.startOnly
            if t.hasPrefix("{") || tools.contains(where: { t.hasPrefix($0) }) {
                phase = .suppressing; held = ""; return ""
            }
            // «ca», «call», «<exec»…: puede ser el inicio de una llamada; se espera un token más.
            if tools.contains(where: { $0.hasPrefix(t) }) { return "" }
            phase = .streaming
        }
        return drain()
    }

    /// Fin del mensaje. Lo retenido que nunca llegó a confirmarse como sintaxis de herramienta
    /// (un `<`, `<f`, `<p`, `<|` o un «ca» final) es texto del usuario y se EMITE: soltarlo
    /// perdía en silencio el final del mensaje en la vista en vivo, aunque `.completed` lo
    /// llevara. Solo se descarta lo que sí se confirmó (`.suppressing`).
    mutating func finish() -> String {
        defer { held = "" }
        if phase == .suppressing { return "" }
        return record(held)
    }

    /// Lo que falta por mostrar del texto limpio final cuando la compuerta descartó algo y no
    /// hubo llamada: el resto de `clean` tras lo ya emitido (comparado sin espacios finales,
    /// porque el texto limpio viene recortado). Si no encaja, no se emite nada: el
    /// `.completed` lleva el texto íntegro y los consumidores lo prefieren.
    func remainder(ofCleanText clean: String) -> String {
        let done = emitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix(done) else { return "" }
        return String(clean.dropFirst(done.count))
    }

    private mutating func record(_ s: String) -> String {
        emitted += s
        return s
    }

    /// Recorre los `<` de lo retenido: el primero que confirma una llamada corta el flujo; el
    /// primero que aún podría serlo retiene desde ahí; si ninguno, todo es prosa.
    private mutating func drain() -> String {
        var i = held.startIndex
        while let lt = held[i...].firstIndex(of: "<") {
            let rest = held[lt...]
            switch Self.classify(rest) {
            case .confirmed:
                let before = String(held[..<lt])
                held = ""
                phase = .suppressing
                return record(before)
            case .pending:
                let before = String(held[..<lt])
                held = String(rest)
                return record(before)
            case .prose:
                i = held.index(after: lt)
            }
        }
        let out = held
        held = ""
        return record(out)
    }

    private enum Verdict { case confirmed, pending, prose }

    private static func classify(_ rest: Substring) -> Verdict {
        for o in openers {
            if rest.hasPrefix(o) {
                // Hace falta el carácter siguiente para distinguir `<function` de `<functions`.
                guard let next = rest.dropFirst(o.count).first else { return .pending }
                if next.isLetter || next.isNumber || next == "_" { continue }  // p. ej. `<|tool` + `_call`: lo decide otro opener
                return .confirmed
            }
            if o.hasPrefix(rest) { return .pending }
        }
        return .prose
    }
}
