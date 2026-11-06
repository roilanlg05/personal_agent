import Foundation

/// Bandera de un solo uso, para garantizar que una continuación se reanuda una vez.
///
/// Un callback del sistema que llega dos veces reanudaría la continuación dos veces, y
/// eso no es un aviso: el proceso cae. Vive en su propio fichero porque la usan tanto el
/// puente con la app Atajos (solo macOS) como la consulta de actividad de CoreMotion
/// (solo iOS), y dentro de un bloque condicional solo existiría en una plataforma.
final class SingleUseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// Devuelve `true` la primera vez y `false` en las siguientes.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}
