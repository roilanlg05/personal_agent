import Foundation
import OSLog

/// Rastro del ciclo de vida del panel de navegador, legible desde FUERA del proceso.
///
/// Por qué existe. Al usuario se le ha muerto el panel del navegador tres veces, y las tres
/// veces el diagnóstico hubo que hacerlo leyendo código, porque este proceso no deja ningún
/// rastro de sus decisiones. El lado del servidor sí se puede interrogar después del hecho: el
/// demonio del screencast responde a `stream status`, la página sigue cargada y se le puede
/// preguntar la URL, y el contenedor registra cada visor que entra y sale. Con eso se descarta
/// el servidor en tres comprobaciones. Lo que queda —que la decisión de cortar el visor la tomó
/// ESTA clase— no se puede comprobar de ninguna manera, porque no se escribe en ninguna parte.
/// Esa asimetría es la que arregla este fichero: un corte de panel deja dicho quién lo cortó.
///
/// Por qué `os_log` y no `print`. La app se lanza fuera de Xcode (su padre es `launchd`), así
/// que su salida estándar no va a ningún sitio que se pueda leer luego. El log unificado se lee
/// desde otro proceso, sobre una app YA arrancada y sin depurador:
///
///     log stream --predicate 'subsystem == "com.gemma.panel"' --style compact
///     log show --predicate 'subsystem == "com.gemma.panel"' --last 30m --style compact
///
/// QUÉ NO SE ESCRIBE AQUÍ, y es deliberado: ninguna URL, ningún título de página, ningún texto
/// extraído de una página y ningún argumento de herramienta. Solo nombres de herramienta,
/// identificadores de panel y booleanos de estado. El log unificado de macOS lo puede leer
/// cualquier proceso con permiso para ello, y lo que el usuario tenga abierto en su navegador es
/// asunto suyo, no telemetría. Si alguna vez hace falta ver la URL para diagnosticar algo, no se
/// añade aquí: se mira en el panel, que es donde el usuario ya la ve.
public enum PanelLog {
    private static let log = Logger(subsystem: "com.gemma.panel", category: "panel")

    public static func note(_ message: String) {
        // `.public` a propósito: sin ello el log unificado sustituye el texto por `<private>` y
        // el rastro deja de servir justo cuando se necesita. Es seguro porque lo que se escribe
        // está acotado por la regla de arriba.
        log.info("\(message, privacy: .public)")
    }

    /// Los primeros ocho caracteres de un UUID de panel: suficiente para seguir uno a lo largo
    /// del log, y más corto de leer que el UUID entero.
    public static func corto(_ id: String?) -> String {
        guard let id else { return "ninguno" }
        return String(id.prefix(8))
    }
}
