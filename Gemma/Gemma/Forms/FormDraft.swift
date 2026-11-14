import Foundation

/// El borrador de un formulario mientras el usuario lo rellena: valores en curso y su validación.
///
/// Es lógica pura, sin SwiftUI, para poder probar las reglas sin dibujar nada. Vive en el
/// `@State` de la tarjeta y se descarta al enviar o cancelar: ningún valor (y menos un secreto)
/// sobrevive en el registro del chat.
///
/// Representación de los valores (la misma que viaja al broker):
///   - `confirm`: `"true"` / `"false"` (por defecto `"false"`: una confirmación nunca nace marcada);
///   - `multichoice`: los `value` elegidos separados por `\n`;
///   - `date`: `yyyy-MM-dd`;
///   - `number`: texto que parsea como número (se acepta la coma decimal);
///   - el resto: el texto tal cual.
struct FormDraft: Equatable {
    let spec: FormSpec
    private(set) var values: [String: String]

    init(spec: FormSpec) {
        self.spec = spec
        var inicial: [String: String] = [:]
        for campo in spec.fields {
            inicial[campo.id] = campo.kind == .confirm ? "false" : ""
        }
        self.values = inicial
    }

    mutating func set(_ id: String, _ value: String) {
        // Un id que no es del formulario se ignora: así `paraEnviar` no puede llevar claves ajenas.
        guard values[id] != nil else { return }
        values[id] = value
    }

    /// Valores elegidos de un `multichoice`, sin vacíos.
    static func elegidos(_ valor: String) -> [String] {
        valor.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func fecha(_ texto: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: texto)
    }

    static func textoDeFecha(_ fecha: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: fecha)
    }

    private static func numero(_ texto: String) -> Double? {
        let t = texto.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let d = Double(t), d.isFinite else { return nil }
        return d
    }

    /// Un mensaje por campo inválido (clave = id del campo), en español y para el usuario.
    var errores: [String: String] {
        var e: [String: String] = [:]
        for campo in spec.fields {
            let v = values[campo.id] ?? ""
            let vacio = campo.kind == .secret || campo.kind == .text
                ? v.isEmpty
                : v.trimmingCharacters(in: .whitespaces).isEmpty
            if vacio {
                // `confirm` nunca está vacío ("false" por defecto); no se exige marcarlo.
                if campo.required { e[campo.id] = "Obligatorio." }
                continue
            }
            switch campo.kind {
            case .text, .secret:
                break
            case .number:
                if Self.numero(v) == nil { e[campo.id] = "Escribe un número." }
            case .confirm:
                if v != "true" && v != "false" { e[campo.id] = "Valor no válido." }
            case .choice:
                if !(campo.options ?? []).contains(where: { $0.value == v }) { e[campo.id] = "Elige una de las opciones." }
            case .multichoice:
                let validas = Set((campo.options ?? []).map(\.value))
                if !Self.elegidos(v).allSatisfy(validas.contains) { e[campo.id] = "Elige solo entre las opciones." }
            case .date:
                if Self.fecha(v) == nil { e[campo.id] = "Fecha no válida (aaaa-mm-dd)." }
            }
        }
        return e
    }

    var puedeEnviar: Bool { errores.isEmpty }

    /// Lo que se entrega al broker: TODOS los ids del formulario (también los opcionales vacíos).
    var paraEnviar: [String: String] {
        var salida = values
        for campo in spec.fields where campo.kind == .number {
            if let n = Self.numero(values[campo.id] ?? "") {
                salida[campo.id] = n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            }
        }
        return salida
    }
}
