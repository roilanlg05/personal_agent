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
    /// Tras cuánto tiempo sin que el turno siguiente toque el navegador se retira un panel vivo.
    private let liveIdleLimit: Duration
    private var idleTask: Task<Void, Never>?

    /// Tope de INACTIVIDAD de un panel vivo: tiempo sin que el usuario le hable al agente. Cada
    /// mensaje suyo lo reinicia (`noteUserActivity()`), así que quien pone un video y sigue
    /// charlando con el agente (justo el uso que se pidió) nunca pierde el panel mientras lo usa.
    /// Solo corre en el silencio total.
    ///
    /// NO HAY MEDICIÓN: 30 min es un juicio. El visor cuesta del orden de 10 Mbit/s contra el
    /// servidor casero mientras dure, y esta clase no puede saber si el usuario mira (no hay señal
    /// de ventana visible). Como tope de silencio es defendible: 30 min sin escribir ni hablar es
    /// el mismo umbral con que `ChatSession` da por terminada una conversación, y quien mira un
    /// video largo sin tocar el chat es el único al que esto le corta algo (un video de más de
    /// media hora, visto en silencio). Más corto lo castigaría a él; más largo deja al servidor
    /// emitiendo a nadie. Lo cambiaría una señal real de «ventana oculta» (acortarlo mucho) o
    /// saber cuánto deja puesto el usuario en la práctica.
    public static let defaultLiveIdleLimit: Duration = .seconds(30 * 60)
    private var consumers: [String: Task<Void, Never>] = [:]

    public init(stream: @escaping StreamFactory, liveIdleLimit: Duration = BrowserPanelCoordinator.defaultLiveIdleLimit) {
        self.makeStream = stream
        self.liveIdleLimit = liveIdleLimit
    }

    /// Abre el panel del turno si `toolName` es de navegador y aún no hay uno activo.
    /// Devuelve su id, o `nil` si no es de navegador, si ya hay panel activo (un panel por
    /// turno) o si no hay flujo (sin relé configurado).
    public func openIfNeeded(toolName: String) -> String? {
        guard Self.isBrowserTool(toolName) else { return nil }
        // Dentro del turno, cada herramienta que actúa sobre la página la deja (o la mantiene)
        // Nada se anota al empezar una herramienta: puede fallar. Se decide en `toolFinished`.
        guard activeID == nil, let stream = makeStream() else { return nil }
        // El panel de este turno hereda lo que se sabía: si había uno vivo, el navegador estaba
        // abierto, y así sigue hasta que un `browser_close` EXITOSO diga lo contrario. Empezar
        // en «cerrado» congelaría la ventana de un video que sigue sonando cuando el primer
        // uso del turno es un `browser_close` que falla (el mismo defecto, por otro camino).
        // Si el navegador se hubiera cerrado por fuera, el relé lo cuenta en el panel y el tope
        // de inactividad lo retira; es el error del lado seguro.
        browserLeftOpen = livePanelID != nil
        // Un panel nuevo toma el relevo del vivo del turno anterior. Nunca se vuelve a emitir en
        // un panel viejo, y dos visores a la vez sobre la misma sesión no tienen sentido.
        retireLivePanel()
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
            // Un panel vivo cuyo flujo terminó ya está congelado: dejarlo como «el vivo» haría
            // que el panel siguiente naciera creyendo que el navegador sigue abierto.
            if let self, self.livePanelID == id {
                self.livePanelID = nil
                self.idleTask?.cancel()
                self.idleTask = nil
            }
            // El id es único por panel, así que esta entrada es la de esta tarea.
            self?.consumers[id] = nil
        }
        return id
    }

    /// Resultado de una herramienta de navegador: aquí se decide si el navegador quedó abierto.
    /// Una herramienta que TERMINÓ BIEN lo deja abierto, salvo `browser_close`, que lo cierra.
    /// Una que falló no cambia nada: ni un `browser_open` que no cargó la página abre el
    /// navegador (el panel quedaría vivo contra nada), ni un `browser_close` que falló lo cierra
    /// (congelar escondería una página que sigue ahí).
    ///
    /// Se lee el `status` del JSON y no se supone. Un resultado ilegible cuenta como fallo.
    public func toolFinished(toolName: String, result: String) {
        guard Self.isBrowserTool(toolName), Self.reportsSuccess(result) else { return }
        browserLeftOpen = toolName != Self.closeToolName
    }

    /// Fin del turno. Con el navegador cerrado congela el panel y corta su flujo (el panel queda
    /// como registro histórico). Con el navegador abierto lo deja EN VIVO: sigue consumiendo del
    /// relé, así que el visor no se va y el video sigue a la vista.
    ///
    /// Qué le pone fin a un panel vivo, todo observable desde aquí: (1) el turno siguiente abre
    /// otro panel (`openIfNeeded` lo retira), lo que cubre también el `browser_close` de un turno
    /// posterior, que abre su panel antes de cerrar; (2) el flujo termina (el cliente se rindió
    /// tras sus reintentos, o el relé cerró para siempre) y la red de seguridad lo congela;
    /// (3) el tope de inactividad (`defaultLiveIdleLimit`); (4) `retireLivePanel()`, que el
    /// arnés llama al empezar un chat nuevo tras mucho tiempo en silencio.
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
            armIdleCap(for: id)
            return
        }
        retire(id)
    }

    /// El usuario le habló al agente: reinicia el reloj del panel vivo, si lo hay. Es lo que hace
    /// que el tope mida inactividad y no vida máxima.
    public func noteUserActivity() {
        guard let id = livePanelID else { return }
        armIdleCap(for: id)
    }

    /// Congela el panel vivo, si lo hay, y corta su flujo.
    public func retireLivePanel() {
        idleTask?.cancel()
        idleTask = nil
        guard let id = livePanelID else { return }
        livePanelID = nil
        retire(id)
    }

    /// Arma el tope de inactividad del panel que acaba de quedar vivo. Vale la identidad: si
    /// para cuando despierta ya es otro el panel vivo (o ninguno), no toca nada.
    private func armIdleCap(for id: String) {
        idleTask?.cancel()
        let limit = liveIdleLimit
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            // Segunda capa de defensa. La primera es que `retireLivePanel()` y `armIdleCap()`
            // cancelan el reloj anterior. Cada una sola basta para las pruebas, pero juntas
            // cubren la carrera en que un reloj ya despertó y espera el hilo principal cuando
            // otro panel toma el relevo: sin esta identidad retiraría al panel nuevo. No quitar
            // por parecer redundante con las cancelaciones.
            guard !Task.isCancelled, let self, self.livePanelID == id else { return }
            self.retireLivePanel()
        }
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
