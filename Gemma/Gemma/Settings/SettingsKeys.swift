import Foundation

/// UserDefaults keys shared between the Settings UI (@AppStorage) and non-View readers (HarnessModel).
enum SettingsKeys {
    /// Bool. When true the server is launched with a wired-memory limit (anti-cold-start). Default false.
    static let keepModelResident = "keepModelResident"

    static let chatProvider = "chatProvider"            // ModelProvider.Kind.rawValue
    static let chatModel = "chatModel"
    static let consolidationProvider = "consolidationProvider"
    static let consolidationModel = "consolidationModel"

    /// String. Base URL of the i3 browser service (port 8083). Empty = drive a local `agent-browser`.
    static let browserBaseURL = "browserBaseURL"
    /// String. **SITIO VIEJO del token del navegador, y ya no se lee ni se escribe para usarlo.**
    ///
    /// El token de conducir vive en el llavero (`TokenDeConducir`), no aquí: `UserDefaults` se
    /// respalda, se sincroniza y se lee sin desbloquear nada, y este token autoriza al agente a
    /// conducir el navegador y al panel a verlo. Esta clave sobrevive por un único motivo: es el
    /// ORIGEN de la migración. `TokenDeConducir.migrar` la lee una vez, mueve lo que haya al
    /// llavero y la borra. Quien la vuelva a usar para guardar un token deshace la Tarea 6.
    static let browserBearerToken = "browserBearerToken"

    /// String. **SITIO VIEJO del token del servicio de memoria, y ya no se lee ni se escribe para
    /// usarlo.**
    ///
    /// El token del servicio de memoria vive en el llavero (`TokenDeMemoria`), no aquí. Es el
    /// secreto más valioso de esta app: con él se lee y se escribe la memoria personal entera del
    /// usuario en el i3 (conversaciones, identidad, agenda, contactos). `UserDefaults` se
    /// respalda, se sincroniza y se lee sin desbloquear nada, así que no es sitio para él.
    ///
    /// Igual que `browserBearerToken`, esta clave sobrevive por un único motivo: es el ORIGEN de
    /// la migración. `TokenDeMemoria.migrar` la lee una vez, mueve lo que haya al llavero y la
    /// borra. Quien la vuelva a usar para guardar un token deshace la Tarea 6b.
    ///
    /// La clave existía antes como literal `"memoryBearerToken"` repetido en cuatro ficheros; la
    /// constante se añade aquí para que la migración y el sitio viejo tengan un solo nombre.
    static let memoryBearerToken = "memoryBearerToken"
}
