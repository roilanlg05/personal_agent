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
    /// respalda, se sincroniza y se lee sin desbloquear nada, y ese token conduce un Chrome con la
    /// sesión de Google del usuario dentro. Esta clave sobrevive por un único motivo: es el
    /// ORIGEN de la migración. `TokenDeConducir.migrar` la lee una vez, mueve lo que haya al
    /// llavero y la borra. Quien la vuelva a usar para guardar un token deshace la Tarea 6.
    static let browserBearerToken = "browserBearerToken"
}
