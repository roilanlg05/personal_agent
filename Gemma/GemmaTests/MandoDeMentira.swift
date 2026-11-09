import Foundation
@testable import Gemma

/// Un volante del navegador que **cuenta llamadas y no abre ningún socket**.
///
/// POR QUÉ EXISTE, Y POR QUÉ ES UN DOBLE DE PRODUCCIÓN Y NO UN SEAM DE PRUEBAS. El camino que
/// lleva la contraseña del usuario sale por el mismo socket por el que llegan los fotogramas, y
/// medirlo con un relé de verdad exigiría red, un servidor y un navegador. Con el mando detrás
/// del protocolo `MandoDelNavegador` —que es la forma en que el panel lo usa **en producción**—
/// la prueba inyecta esto y lee lo que salió. La alternativa era un seam que solo las pruebas
/// instalan, que mide el arnés y no la producción.
///
/// Vive en su propio fichero porque lo usan cuatro ficheros de prueba: el coordinador ya no
/// acepta un flujo a secas, sino el par (flujo, mando), así que toda prueba que abra un panel
/// necesita uno.
///
/// `@unchecked Sendable` con un candado de verdad: el protocolo es `Sendable` porque en
/// producción lo cumple un actor, y los contadores se leen desde el hilo de la prueba mientras
/// las llamadas pueden llegar desde otra tarea.
final class MandoDeMentira: MandoDelNavegador, @unchecked Sendable {
    private let candado = NSLock()
    private var _tomas = 0
    private var _devoluciones = 0
    private var _entradas: [String] = []

    var tomas: Int { candado.withLock { _tomas } }
    var devoluciones: Int { candado.withLock { _devoluciones } }
    var entradas: [String] { candado.withLock { _entradas } }

    func tomaElMando() async -> Bool {
        candado.withLock { _tomas += 1 }
        return true
    }

    func devuelveElMando() async -> Bool {
        candado.withLock { _devoluciones += 1 }
        return true
    }

    func manda(entrada: String) async -> Bool {
        candado.withLock { _entradas.append(entrada) }
        return true
    }
}
