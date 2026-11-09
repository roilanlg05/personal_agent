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
            // Con `status`, por lo mismo que `error(_:)`: un objeto sin estado se resume como
            // «listo» en la fila del chat y no gasta presupuesto en el bucle. Este literal no
            // puede pasar por `error(_:)` porque es justo el camino en el que serializar falló.
            return #"{"status": "error", "error": "El tool no pudo serializar su respuesta."}"#
        }
        return text
    }

    /// Objeto JSON de un fallo genérico: `status: error` más el motivo.
    ///
    /// EL DEFECTO QUE ARREGLA, Y ES LA PEOR DE LAS DOS MENTIRAS DE LA FILA. Esto emitía
    /// `{"error": …}` pelado: un objeto JSON **sin** `status`. `ToolLogRow.summarize` enumera el
    /// FALLO y no el éxito —hay ~70 estados y la mayoría de los correctos no son «success»—, así
    /// que un objeto sin `status` no entraba en la rama de fallo, caía en `case nil` y se
    /// resumía como «listo», con su tilde verde. Es el camino de las guardas de argumentos de
    /// medio registro (más de cincuenta sitios de llamada) y lo dispara el modelo llamando con
    /// los argumentos mal: el usuario leía «listo» sobre un error. Que el agente le cuente que
    /// hizo cosas que no hizo es su queja número uno.
    ///   Lo mismo en el bucle: sin `status` el resultado caía en el tercer estado («no se supo
    /// leer»), que no gasta presupuesto de fallos. Un modelo repitiendo la misma llamada mal
    /// formada daba vueltas hasta agotar las rondas del turno.
    ///
    /// POR QUÉ `error` Y NO `invalid_arguments` NI `missing_fields`. Este ayudante NO es solo la
    /// guarda de argumentos: el censo de sus llamadas incluye también «No se encontró ningún
    /// lugar con 'x'», «No se pudo actualizar la nota: …» y «No se pudo buscar el contacto: …».
    /// `error` es el estado genérico del contrato, existe desde el principio, está en
    /// `ToolLogRow.failureStatuses` («falló») y en `Agent.estadosDeFallo`, y es cierto en los
    /// tres grupos. Los estados finos siguen disponibles para quien quiera precisar en su propia
    /// llamada: `missing_fields` para un argumento que falta y la familia `invalid_*` para uno
    /// que no se entiende — así los usan `ScheduleRange.parse` y `CreateCalendarEventTool`.
    /// Migrar los cincuenta y tantos sitios uno a uno es otro trabajo; lo que no podía seguir es
    /// que el camino por omisión saliera en verde.
    ///
    /// LA CLAVE `error` SE QUEDA, y no es compatibilidad por compatibilidad: una veintena de
    /// pruebas de todo el registro la leen para comprobar que el motivo viajó entero y escapado
    /// (`ToolJSONEscapingTests`), y dice algo distinto que `status` — una es el motivo, la otra
    /// el estado.
    public static func error(_ message: String) -> String {
        object(["status": "error", "error": message])
    }
}
