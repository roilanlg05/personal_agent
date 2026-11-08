import Foundation
import Observation

/// Lo que el panel de navegador muestra de UN turno: el último fotograma, la frase de
/// narración, el resumen y si el navegador del i3 está en vivo.
///
/// Todo se RECIBE del relé del i3; nada se calcula aquí. En particular `isLive` y `summary`
/// los decide el i3 (spec §5.10): una página quieta sigue en vivo aunque no lleguen frames,
/// así que ni la edad del frame ni un reloj deciden nada.
///
/// El enum de eventos no tiene hueco para parámetros de acciones (el i3 los filtra en
/// origen), de modo que ningún selector ni valor de formulario puede entrar por aquí.
@Observable @MainActor
public final class BrowserPanelState {
    /// Solo el fotograma más nuevo: el anterior se suelta. `nil` tras congelar.
    public private(set) var jpeg: Data?
    public private(set) var phrase: String = "abriendo el navegador"
    public private(set) var summary: String = ""
    /// Cuándo se capturó el fotograma mostrado. Se enseña, pero no decide `isLive`.
    public private(set) var lastFrameAt: Date?
    public private(set) var isLive: Bool = false
    /// `true` una vez congelado. Irreversible.
    public private(set) var isCollapsed: Bool = false

    public init() {}

    public func apply(_ event: BrowserRelayEvent) {
        switch event {
        case .summary(let text):
            // El resumen es lo que queda del panel ya plegado, así que se acepta también congelado.
            summary = text
        case _ where isCollapsed:
            // Congelado: nada pinta ni narra ni revive. Un frame tardío reabriría el secreto en reposo.
            return
        case .frame(_, let data, let capturedAt):
            jpeg = data
            lastFrameAt = capturedAt
        case .narration(let text):
            phrase = text
        case .host:
            break
        case .state(let live, let collapsed):
            if collapsed {
                freeze()
            } else {
                isLive = live
            }
        case .closed:
            // NO es terminal: BrowserRelayClient reconecta tras un cierre y llegan más frames y
            // un `state` nuevo. Solo apagamos el en-vivo; congelar es cosa de `freeze()`.
            isLive = false
        }
    }

    /// Plega el panel para siempre y suelta la imagen: un panel congelado no deja pantalla
    /// del navegador en el historial (§6.2(g)).
    public func freeze() {
        isCollapsed = true
        isLive = false
        jpeg = nil
    }
}
