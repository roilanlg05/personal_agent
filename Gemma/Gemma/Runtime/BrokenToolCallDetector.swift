import Foundation

/// ¿Es este texto «final» en realidad una llamada a herramienta que llegó ROTA?
///
/// EL DEFECTO QUE CIERRA (chat del 2026-11-11, proveedor Claude, assistant seq 20). El modelo
/// quiso llamar `browser_wait`, pero en vez de un bloque `tool_use` estructurado escribió la
/// sintaxis de invocación como TEXTO (`<function_calls>` / `<invoke name="browser_wait">` /
/// `<parameter …>`). Ningún parser la reconoce como llamada y `GemmaToolCallParser.strip`, con
/// su barrido genérico de etiquetas, se come `<function_calls>`, `<invoke` y `</invoke>` pero
/// deja el atributo: el texto guardado terminó en ` name="browser_wait">`. Sin llamadas
/// pendientes, el bucle del agente lo tomó por la respuesta final y el turno se paró ahí.
///
/// QUÉ MIRA, Y SOBRE QUÉ TEXTO. Se aplica al `text` del `.completed`, que en el camino de
/// servidor ya viene LIMPIO (pasado por `strip`): por eso reconoce también el RESTO que deja la
/// limpieza, no solo la sintaxis cruda. Dos familias:
///   1. Marcas crudas de llamada, que ninguna respuesta legítima al usuario contiene: si una
///      llamada completa hubiera llegado, el parser la habría extraído y la ronda no sería final.
///   2. El resto de atributo ` name="x">`, pero SOLO si `x` es el nombre de una herramienta
///      registrada. Así una respuesta que hable de HTML (`<input name="email">`, que `strip`
///      también deja en ` name="email">`) no se confunde con una llamada.
///
/// Es puro: ni red ni estado. El bucle decide qué hacer con un `true` (`Agent.run`).
enum BrokenToolCallDetector {
    /// Marcas crudas de sintaxis de llamada. `antml:` es el prefijo de espacio de nombres de la
    /// sintaxis de invocación de Claude; las demás son las de los formatos que ya conoce
    /// `GemmaToolCallParser` cuando llegan sin cerrar.
    static let marcas = ["<function_calls", "</function_calls", "<invoke", "</invoke", "antml:",
                         "<tool_call", "<|tool_call", "<parameter name=", "<function name="]

    /// Las marcas propias de la sintaxis de invocacion de Claude. `ServerRuntime` las usa para
    /// no sacar a pantalla el resto que `strip` deja de ellas.
    static let marcasDeInvocacion = ["<function_calls", "<invoke", "antml:"]

    private static let resto = try! NSRegularExpression(
        pattern: #"(?:^|\s)name\s*=\s*["']([A-Za-z0-9_\-.]+)["']\s*/?>"#)

    static func esLlamadaRota(_ texto: String, herramientas: Set<String>) -> Bool {
        if marcas.contains(where: { texto.contains($0) }) { return true }
        let ns = texto as NSString
        for m in resto.matches(in: texto, range: NSRange(location: 0, length: ns.length)) {
            if herramientas.contains(ns.substring(with: m.range(at: 1))) { return true }
        }
        return false
    }
}
