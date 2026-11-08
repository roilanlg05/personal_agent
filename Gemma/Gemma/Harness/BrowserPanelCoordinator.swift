import Foundation

/// Decide cuándo hay un panel de navegador en el chat: uno por turno, abierto con la primera
/// herramienta de navegador. Al terminar el turno se congela, SALVO que el navegador siga
/// abierto: entonces el panel sigue en vivo (ver `livePanelID`).
///
/// Por qué sobrevive: el panel es la ventana del usuario a SU navegador. Si el agente decidió
/// dejarlo abierto («ponme un video y déjalo»), congelar el panel al acabar el turno cortaba el
/// visor, el relé soltaba el screencast a los 15 s y el usuario veía el video quedarse quieto y
/// el navegador «cerrarse» cuando en realidad Chromium seguía vivo en el i3.
///
/// No sabe de dónde sale el flujo de eventos: lo pide a una fábrica. Así se prueba sin red y
/// el puente real con `BrowserRelayClient` vive fuera de aquí.
@MainActor
public final class BrowserPanelCoordinator {
    public typealias StreamFactory = @MainActor () -> AsyncStream<BrowserRelayEvent>?

    /// Todos los paneles, también los congelados: siguen en el historial del chat.
    public private(set) var panels: [String: BrowserPanelState] = [:]
    /// El panel del turno en curso; `nil` entre turnos.
    public private(set) var activeID: String?

    /// El panel de un turno YA terminado que sigue en vivo porque el navegador quedó abierto.
    /// Como mucho uno: el navegador del i3 es una sola sesión. `nil` si no hay ninguno.
    public private(set) var livePanelID: String?

    private let makeStream: StreamFactory
    /// ¿Quedó el navegador abierto, hasta donde se ve desde aquí? Esta clase no habla con el i3:
    /// solo ve los nombres de herramienta (`openIfNeeded`) y su resultado (`toolFinished`).
    /// Cualquier herramienta de navegador salvo `browser_close` lo deja abierto; un
    /// `browser_close` que terminó bien lo cierra; uno que falló no cambia nada.
    private var browserLeftOpen = false
    private var consumers: [String: Task<Void, Never>] = [:]

    public init(stream: @escaping StreamFactory) {
        self.makeStream = stream
    }

    /// Abre el panel del turno si `toolName` es de navegador y aún no hay uno activo.
    /// Devuelve su id, o `nil` si no es de navegador, si ya hay panel activo (un panel por
    /// turno) o si no hay flujo (sin relé configurado).
    public func openIfNeeded(toolName: String) -> String? {
        guard Self.isBrowserTool(toolName) else { return nil }
        // Dentro del turno, cada herramienta que actúa sobre la página la deja (o la mantiene)
        // abierta. `browser_close` no se anota al empezar: puede fallar; se decide en `toolFinished`.
        if activeID != nil, toolName != Self.closeToolName { browserLeftOpen = true }
        guard activeID == nil, let stream = makeStream() else { return nil }
        // Un panel nuevo toma el relevo del vivo del turno anterior. Nunca se vuelve a emitir en
        // un panel viejo, y dos visores a la vez sobre la misma sesión no tienen sentido.
        retireLivePanel()
        browserLeftOpen = toolName != Self.closeToolName
        let id = UUID().uuidString
        let state = BrowserPanelState()
        panels[id] = state
        activeID = id
        consumers[id] = Task { @MainActor [weak self, weak state] in
            for await event in stream {
                state?.apply(event)
            }
            // Red de seguridad, no cortesía: el flujo tiene búfer `.bufferingNewest(64)` y un
            // consumidor lento puede perder un `.closed`. Que el flujo termine congela el panel
            // por sí solo. No borrar por parecer redundante con `.closed`.
            state?.freeze()
            // El id es único por panel, así que esta entrada es la de esta tarea.
            self?.consumers[id] = nil
        }
        return id
    }

    /// Resultado de una herramienta. Solo importa `browser_close`: si terminó con éxito, el
    /// navegador ya no existe y no hay nada que seguir mostrando.
    ///
    /// Se lee el `status` del JSON y no se supone: una herramienta que falla (`browser_close`
    /// con el servicio caído) deja el navegador como estaba, y congelar entonces escondería una
    /// página que sigue ahí. Ante un resultado ilegible se asume que NO cerró (el error cae del
    /// lado de seguir mostrando, no de ocultar).
    public func toolFinished(toolName: String, result: String) {
        guard toolName == Self.closeToolName, activeID != nil else { return }
        if Self.reportsSuccess(result) { browserLeftOpen = false }
    }

    /// Fin del turno. Con el navegador cerrado congela el panel y corta su flujo (el panel queda
    /// como registro histórico). Con el navegador abierto lo deja EN VIVO: sigue consumiendo del
    /// relé, así que el visor no se va y el video sigue a la vista.
    ///
    /// Qué le pone fin a un panel vivo, todo observable desde aquí: (1) el turno siguiente abre
    /// otro panel (`openIfNeeded` lo retira), lo que cubre también el `browser_close` de un turno
    /// posterior, que abre su panel antes de cerrar; (2) el flujo termina (el cliente se rindió
    /// tras sus reintentos, o el relé cerró para siempre) y la red de seguridad lo congela;
    /// (3) `retireLivePanel()` por orden de quien tenga una señal mejor (cerrar el chat).
    ///
    /// `survive: false` es para el turno que NO acabó por su pie (el usuario pulsó detener, o
    /// falló): ahí se congela siempre, aunque el navegador siga abierto. Detener es una orden
    /// explícita y no se puede reinterpretar (la pantalla de un pago no debe quedar viva), y tras
    /// un fallo no se sabe en qué estado quedó el navegador.
    public func endTurn(survive: Bool = true) {
        guard let id = activeID else { return }
        activeID = nil
        if survive, browserLeftOpen {
            livePanelID = id
            return
        }
        retire(id)
    }

    /// Congela el panel vivo, si lo hay, y corta su flujo.
    public func retireLivePanel() {
        guard let id = livePanelID else { return }
        livePanelID = nil
        retire(id)
    }

    private func retire(_ id: String) {
        panels[id]?.freeze()
        consumers[id]?.cancel()
        consumers[id] = nil
    }

    private nonisolated static let closeToolName = "browser_close"

    private nonisolated static func reportsSuccess(_ result: String) -> Bool {
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["status"] as? String == "success"
    }

    /// Las ocho herramientas que conducen el navegador. `read_webpage` NO está: no trabaja en la
    /// sesión que el relé del i3 observa y conectar el visor levantaría un Chromium que esa
    /// herramienta existe para evitar (además de poder pintar una página vieja como «en vivo»).
    public nonisolated static func isBrowserTool(_ name: String) -> Bool {
        Agent.browserToolNames.contains(name)
    }
}
