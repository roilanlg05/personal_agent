import Foundation

/// El último cerco contra la fuga de un secreto: tacha del texto que viaja hacia el modelo
/// cualquier valor que la bóveda guarde.
///
/// POR QUÉ HACE FALTA AUNQUE EL MODELO NUNCA PIDA EL VALOR. El modelo no lee secretos, pero una
/// página puede reflejarlos (un `<input>` que el snapshot devuelve relleno, un mensaje de error
/// que repite la contraseña). Si eso llegara al prompt, quedaría en transcript, memoria y logs.
/// Por eso se limpia el resultado de CADA herramienta en el punto único por el que pasan todas.
///
/// FALLA CERRADO. Si el índice de la bóveda es ilegible, `valoresActuales()` no puede enumerar los
/// secretos y el redactor estaría ciego sin saberlo. Se prefiere perder un resultado a filtrar una
/// contraseña, así que en ese caso se devuelve un texto fijo en lugar del original.
enum SecretRedactor {
    /// Lo que sustituye al resultado cuando la bóveda no se puede leer.
    static let textoSiLaBovedaNoSeLee = "[resultado oculto: la bóveda de secretos no se puede leer]"

    static func limpia(_ texto: String, vault: SecretVault) -> String {
        guard vault.indiceLegible else { return textoSiLaBovedaNoSeLee }

        // Cada secreto con su nombre. Las herramientas devuelven JSON, y en JSON una contraseña con
        // comillas o barras aparece ESCAPADA (`pa\"ss`), que no contiene el valor literal: por eso
        // se tacha también la forma escapada. Sin esto la fuga pasaría con solo tener un `"`.
        var pares: [(buscar: String, nombre: String)] = []
        for s in vault.lista() {
            guard let valor = vault.valor(de: s.name), !valor.isEmpty else { continue }
            pares.append((valor, s.name))
            if let escapado = escapadoEnJSON(valor), escapado != valor {
                pares.append((escapado, s.name))
            }
        }
        // El más largo primero: si `abc` se sustituyera antes que `abcdef`, de `abcdef` quedaría
        // `[secreto: x]def`, que delata el resto del valor.
        pares.sort { $0.buscar.count > $1.buscar.count }

        var salida = texto
        for p in pares {
            salida = salida.replacingOccurrences(of: p.buscar, with: "[secreto: \(p.nombre)]")
        }
        return salida
    }

    /// El contenido de `valor` tal como lo escribe un serializador JSON, sin las comillas de fuera.
    private static func escapadoEnJSON(_ valor: String) -> String? {
        guard let d = try? JSONEncoder().encode(valor), let s = String(data: d, encoding: .utf8),
              s.count >= 2 else { return nil }
        return String(s.dropFirst().dropLast())
    }
}
