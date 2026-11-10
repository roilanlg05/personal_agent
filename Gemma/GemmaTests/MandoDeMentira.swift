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
    /// Lo que devuelven los tres métodos: «el mensaje SALIÓ del aparato». `false` es el socket
    /// caído, que es el caso en que el botón no debe quedarse en «pidiendo…».
    private let salida: Bool
    /// Lo que `manda(entrada:)` espera ANTES de anotar el mensaje, o `nil` para no esperar.
    ///
    /// Existe para que una prueba pueda medir el ORDEN de una cola: con un primer envío que se
    /// queda colgado en esta espera, un mensaje que no estuviera encadenado detrás de él lo
    /// adelantaría, y eso es justo lo que hay que poder ver (un `mouseReleased` que adelanta a
    /// su `mousePressed` deja el botón hundido). Sin la espera, las tareas del hilo principal
    /// salen en el orden en que se crearon y la cadena no se podría distinguir de la suerte.
    private let antesDeMandar: (@Sendable () async -> Void)?

    init(salida: Bool = true, antesDeMandar: (@Sendable () async -> Void)? = nil) {
        self.salida = salida
        self.antesDeMandar = antesDeMandar
    }

    var tomas: Int { candado.withLock { _tomas } }
    var devoluciones: Int { candado.withLock { _devoluciones } }
    var entradas: [String] { candado.withLock { _entradas } }

    func tomaElMando() async -> Bool {
        candado.withLock { _tomas += 1 }
        return salida
    }

    func devuelveElMando() async -> Bool {
        candado.withLock { _devoluciones += 1 }
        return salida
    }

    func manda(entrada: String) async -> Bool {
        await antesDeMandar?()
        candado.withLock { _entradas.append(entrada) }
        return salida
    }
}
