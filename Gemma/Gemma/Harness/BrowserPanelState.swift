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
    /// Plegado: porque el relé lo dijo (reversible) o porque se congeló (irreversible).
    public var isCollapsed: Bool { relayCollapsed || isFrozen }
    private var relayCollapsed: Bool = false
    /// Solo lo pone `freeze()`. Irreversible.
    private var isFrozen: Bool = false

    public init() {}

    /// REGLA: `freeze()` pertenece al ciclo de vida local. Solo lo llaman `endTurn()` y el fin
    /// del `AsyncStream`. Un mensaje del relé (`state` o `closed`) NUNCA congela: solo mueve los
    /// dos booleanos, porque el relé puede plegar y luego desplegar y el panel debe revivir.
    public func apply(_ event: BrowserRelayEvent) {
        switch event {
        case .summary(let text):
            // El resumen es la etiqueta del panel plegado: se acepta también plegado o congelado.
            summary = text
        case .state(let live, let collapsed):
            guard !isFrozen else { return }
            isLive = live
            relayCollapsed = collapsed
            // §6.2(g): un panel plegado no deja imagen en reposo. Se cumple soltando el jpeg,
            // no congelando, para que `collapsed: false` pueda revivirlo.
            if collapsed { jpeg = nil }
        case .closed:
            // NO es terminal: BrowserRelayClient reconecta tras un cierre y llegan más frames y
            // un `state` nuevo. Solo apagamos el en-vivo.
            guard !isFrozen else { return }
            isLive = false
        case .frame(_, let data, let capturedAt):
            // Plegado o congelado: un frame tardío reabriría el secreto en reposo.
            guard !isCollapsed else { return }
            jpeg = data
            lastFrameAt = capturedAt
        case .narration(let text):
            guard !isCollapsed else { return }
            phrase = text
        case .host:
            break
        }
    }

    /// Plega el panel para siempre y suelta la imagen: un panel congelado no deja pantalla
    /// del navegador en el historial (§6.2(g)).
    public func freeze() {
        isFrozen = true
        isLive = false
        jpeg = nil
    }
}
