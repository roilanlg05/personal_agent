import Foundation

/// Decide cuándo hay un panel de navegador en el chat: uno por turno, abierto con la primera
/// herramienta de navegador y congelado al terminar el turno.
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

    private let makeStream: StreamFactory
    private var consumers: [String: Task<Void, Never>] = [:]

    public init(stream: @escaping StreamFactory) {
        self.makeStream = stream
    }

    /// Abre el panel del turno si `toolName` es de navegador y aún no hay uno activo.
    /// Devuelve su id, o `nil` si no es de navegador, si ya hay panel activo (un panel por
    /// turno) o si no hay flujo (sin relé configurado).
    public func openIfNeeded(toolName: String) -> String? {
        guard Self.isBrowserTool(toolName), activeID == nil, let stream = makeStream() else { return nil }
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

    /// Fin del turno: congela el panel activo y corta su flujo.
    public func endTurn() {
        guard let id = activeID else { return }
        panels[id]?.freeze()
        consumers[id]?.cancel()
        consumers[id] = nil
        activeID = nil
    }

    /// Las ocho herramientas que conducen el navegador. `read_webpage` NO está: no trabaja en la
    /// sesión que el relé del i3 observa y conectar el visor levantaría un Chromium que esa
    /// herramienta existe para evitar (además de poder pintar una página vieja como «en vivo»).
    public nonisolated static func isBrowserTool(_ name: String) -> Bool {
        Agent.browserToolNames.contains(name)
    }
}
