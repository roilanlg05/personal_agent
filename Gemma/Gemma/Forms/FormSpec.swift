import Foundation

/// Un campo de un formulario que el agente pide mostrar al usuario.
///
/// Es un tipo de datos puro: no sabe de UI ni de Keychain. Así la validación se prueba sin
/// arrancar nada y la misma definición sirve a iOS y a macOS.
struct FormField: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case text, secret, number, choice, multichoice, confirm, date
    }

    struct Option: Codable, Equatable, Sendable {
        var value: String
        var label: String
    }

    var id: String
    var label: String
    var kind: Kind
    var required: Bool
    var options: [Option]?
    /// Nombre con el que la bóveda guarda el valor. Solo en `secret`: el modelo nunca ve el valor.
    var secretName: String?
    var placeholder: String?
    var help: String?

    init(id: String, label: String, kind: Kind, required: Bool = true,
         options: [Option]? = nil, secretName: String? = nil,
         placeholder: String? = nil, help: String? = nil) {
        self.id = id; self.label = label; self.kind = kind; self.required = required
        self.options = options; self.secretName = secretName
        self.placeholder = placeholder; self.help = help
    }

    /// `required` es opcional en el JSON del modelo y por defecto es `true` (así lo fija el spec):
    /// si el modelo lo omite en una contraseña, el campo no puede quedar opcional por descuido.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(Kind.self, forKey: .kind)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        options = try c.decodeIfPresent([Option].self, forKey: .options)
        secretName = try c.decodeIfPresent(String.self, forKey: .secretName)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        help = try c.decodeIfPresent(String.self, forKey: .help)
    }
}

struct FormSpec: Codable, Equatable, Sendable {
    var title: String
    var description: String?
    var submitLabel: String?
    var fields: [FormField]

    /// Máximo de campos por formulario: más que eso ya no es un formulario, es un trámite.
    static let maxCampos = 12
    /// Mismo patrón que usará la bóveda para las cuentas del Keychain; se valida aquí, antes de
    /// mostrar nada, para que un nombre raro no llegue nunca al almacén.
    static let patronNombreDeSecreto = "^[a-z0-9_]{1,40}$"

    /// Construye y valida un formulario a partir de lo que manda el modelo.
    ///
    /// La validación cruzada (ids únicos, opciones y `secret_name` según el tipo) vive aquí y no
    /// en `init(from:)`: así el decodificador solo describe la forma y los errores llegan al
    /// modelo con un caso concreto que puede corregir.
    static func parse(title: String, description: String?, submitLabel: String?,
                      fieldsJSON: String) throws -> FormSpec {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let campos = try? decoder.decode([FormField].self, from: Data(fieldsJSON.utf8)) else {
            throw FormSpecError.jsonInvalido
        }
        guard !campos.isEmpty else { throw FormSpecError.sinCampos }
        guard campos.count <= maxCampos else { throw FormSpecError.demasiadosCampos }
        guard Set(campos.map(\.id)).count == campos.count else { throw FormSpecError.idsRepetidos }

        for campo in campos {
            let conOpciones = campo.kind == .choice || campo.kind == .multichoice
            if conOpciones {
                guard let o = campo.options, !o.isEmpty else { throw FormSpecError.faltanOpciones(campo.id) }
            } else if campo.options != nil {
                throw FormSpecError.opcionesNoPermitidas(campo.id)
            }

            if campo.kind == .secret {
                guard let nombre = campo.secretName else { throw FormSpecError.faltaNombreDeSecreto(campo.id) }
                guard nombre.range(of: patronNombreDeSecreto, options: .regularExpression) != nil else {
                    throw FormSpecError.nombreDeSecretoInvalido(nombre)
                }
            } else if campo.secretName != nil {
                throw FormSpecError.nombreDeSecretoNoPermitido(campo.id)
            }
        }
        return FormSpec(title: title, description: description, submitLabel: submitLabel, fields: campos)
    }
}

enum FormSpecError: Error, Equatable {
    case sinCampos
    case demasiadosCampos
    case idsRepetidos
    case nombreDeSecretoInvalido(String)
    case faltanOpciones(String)
    case opcionesNoPermitidas(String)
    case faltaNombreDeSecreto(String)
    case nombreDeSecretoNoPermitido(String)
    case jsonInvalido
}

enum FormStatus: String, Codable, Sendable {
    case submitted, cancelled, timeout
}

/// Lo único que vuelve al modelo tras un formulario.
struct FormResponse: Codable, Equatable, Sendable {
    var status: FormStatus
    var values: [String: String]

    /// El valor de un campo `secret` es siempre este literal, nunca lo que escribió el usuario:
    /// el modelo sabe que el secreto existe y cómo se llama, pero jamás lo lee.
    static func textoDeSecretoGuardado(_ nombre: String) -> String {
        "[secreto guardado: \(nombre)]"
    }

    /// JSON con claves ordenadas para que la salida sea estable.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let s = String(data: data, encoding: .utf8) else {
            return #"{"status":"cancelled","values":{}}"#
        }
        return s
    }
}
