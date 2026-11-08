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
    ///
    /// EL ORDEN DE LAS CLAVES ES ESTABLE, Y ESO NO ES COSMÉTICO. Sin `.sortedKeys` esto
    /// serializaba un `Dictionary` de Swift en su orden de iteración, que no es una propiedad
    /// del contenido: sale de la semilla de hash del PROCESO (aleatoria por arranque) y de la
    /// CAPACIDAD de la tabla, que depende de cómo se construyó el diccionario. Medido con el
    /// par `["status", "message"]`: seis arranques del mismo programa dieron `message` primero
    /// en tres y `status` primero en los otros tres; y dentro de una sola ejecución, dos
    /// diccionarios con las mismas claves y distinta capacidad salieron en órdenes distintos.
    ///   La consecuencia era que cualquier prueba que compare la salida de una herramienta
    /// byte a byte es intermitente —ya pasó: una prueba de `BrowserCoreSkillTests` se ponía
    /// roja 1 de cada 3 veces—, y con ella la suite deja de ser un instrumento de medida.
    /// Ningún consumidor depende del orden (JSON es un objeto sin orden por especificación y
    /// todo lo que lee estos resultados pasa por `JSONSerialization.jsonObject`), así que
    /// fijarlo no cuesta nada y devuelve el determinismo a los más de setenta tools que
    /// construyen su salida aquí. Ver `ToolJSONOutputOrderTests`.
    public static func object(_ fields: [String: Any?]) -> String {
        let cleaned = fields.compactMapValues { $0 }
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned,
                                                    options: [.sortedKeys, .withoutEscapingSlashes]),
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
