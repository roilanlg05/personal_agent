import Foundation

/// Serialización segura de la respuesta de un tool.
///
/// Los tools nativos construían su JSON interpolando strings a mano
/// (`"{\"title\": \"\(title)\"}"`). Cualquier comilla, barra invertida, salto de línea
/// o tabulador en un título, una dirección o un mensaje de error producía JSON inválido,
/// que el modelo recibía como basura y no podía interpretar.
///
/// Todos los tools deben construir su salida con este ayudante: delega en
/// `JSONSerialization`, que escapa correctamente cualquier contenido.
public enum ToolJSONOutput {

    /// Serializa un diccionario como objeto JSON de una línea.
    ///
    /// Los valores `nil` se omiten (no se emite `null`), porque el modelo interpreta
    /// mejor la ausencia de una clave que un `null` explícito.
    ///
    /// Si la serialización fallara (valores no representables en JSON), devuelve un
    /// objeto de error válido en lugar de una cadena corrupta.
    public static func object(_ fields: [String: Any?]) -> String {
        let cleaned = fields.compactMapValues { $0 }
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error": "El tool no pudo serializar su respuesta."}"#
        }
        return text
    }

    /// Objeto JSON con una única clave `error`.
    public static func error(_ message: String) -> String {
        object(["error": message])
    }
}
