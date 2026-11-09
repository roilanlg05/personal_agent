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
    /// El tamaño del viewport remoto que produjo **el fotograma que hay en `jpeg`**, o `nil` si
    /// no se sabe. Es lo que `BrowserInputMapper` necesita para situar un toque.
    ///
    /// VIVE Y MUERE CON LA IMAGEN, y eso es el invariante que importa: si estas dimensiones
    /// sobrevivieran al fotograma que describen, el toque siguiente se mapearía contra el
    /// viewport de una imagen que ya no está en pantalla, y ésa es la forma exacta de pulsar
    /// otra cosa en la cuenta del usuario. Por eso se ponen (incluso a `nil`) en cada fotograma
    /// y se sueltan en los dos sitios donde se suelta el JPEG: al plegar y al congelar. Un
    /// `closed` NO las suelta, igual que no suelta la imagen: el panel sigue mostrando el último
    /// fotograma con su motivo, y el volante ya se ha ido con la conexión unas líneas más abajo,
    /// así que por ahí no puede salir ningún toque.
    public private(set) var dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?
    public private(set) var phrase: String = "abriendo el navegador"
    public private(set) var summary: String = ""
    /// Cuándo se capturó el fotograma mostrado. Se enseña, pero no decide `isLive`.
    public private(set) var lastFrameAt: Date?
    public private(set) var isLive: Bool = false
    /// Host de la página que el i3 está mostrando (evento `host`). `nil` hasta que llega.
    public private(set) var host: String?
    /// Por qué se cortó el relé la última vez (`closed`). `nil` si no se ha cortado o si ya
    /// volvió a llegar un `state`/`frame` (la conexión revivió). Vacío = el i3 no dio motivo.
    public private(set) var closedReason: String?
    /// `true` en cuanto llega un mensaje DEL RELÉ (`state`, `frame`, `narration`, `host`,
    /// `summary`). La vista no pinta nada antes, así que **si el i3 no habla, el panel no
    /// aparece** (spec §6.2(e), §8): es el caso del servicio caído y el del token rechazado,
    /// donde no se llega a abrir el socket.
    ///
    /// La línea exacta es «¿habló el servidor?», no «¿hay streaming?», y la diferencia es
    /// deliberada. Si el i3 responde pero no hay puerto de streaming, el relé manda un
    /// `state{live:false}` igualmente, así que el panel **sí** aparece, apagado y con su
    /// motivo. Eso es lo que queremos: las herramientas están funcionando —el agente está
    /// conduciendo el navegador— y el único roto es la vista, de modo que callar dejaría al
    /// usuario con un misterio en vez de con una explicación. Esconder el panel solo es la
    /// respuesta correcta cuando no hay nada ni nadie al otro lado.
    ///
    /// `closed` NO cuenta: lo fabrica también el cliente al fallar la conexión, y no prueba
    /// que haya nada detrás. Por eso el servidor manda un `state` antes del `closed` cuando
    /// rechaza por sesión equivocada (ver `browser/app.py`), que es su forma de decir «he
    /// hablado yo». Solo `apply` lo sube y `freeze()` no lo resucita.
    public private(set) var hasReceivedMessage: Bool = false
    /// Quién tiene el volante del navegador remoto, para que la vista pueda decirlo y decidir si
    /// captura los gestos del usuario. Arranca en `.agente`: el volante es del agente hasta que
    /// el servidor diga otra cosa, y **nada local lo mueve**. En particular, pulsar el botón de
    /// «toma el volante» no lo mueve: solo lo mueve el mensaje `mando` del relé, ya resuelto por
    /// `BrowserRelayClient` (que es quien sabe si la petición fue mía), más el corte de conexión
    /// de aquí abajo.
    public private(set) var quienConduce: QuienConduce = .agente
    /// Plegado: porque el relé lo dijo (reversible) o porque se congeló (irreversible).
    public var isCollapsed: Bool { relayCollapsed || isFrozen }
    private var relayCollapsed: Bool = false
    /// Solo lo pone `freeze()`. Irreversible.
    private var isFrozen: Bool = false

    /// Cuántos mensajes del relé han llegado, y cuántos de ellos eran fotogramas. No gobiernan
    /// nada: existen para que el panel pueda DECIR en pantalla por qué está vacío.
    ///
    /// Por qué hacen falta. El panel se le quedó al usuario en «Esperando la primera imagen del
    /// navegador…» mientras el i3 decía `Screencasting: true` y un visor de prueba enganchado al
    /// mismo relé recibía su primer fotograma a los 0,02 s. Con eso, desde fuera, no hay manera
    /// de distinguir tres cosas muy distintas: que no llegue ningún mensaje, que lleguen
    /// mensajes pero ningún fotograma, o que lleguen fotogramas y no se puedan pintar. Los tres
    /// casos se ven exactamente igual, y el teléfono no deja leer su `os_log` desde la terminal
    /// (`log --device-udid` ya no existe en macOS 27), así que el único sitio donde el usuario
    /// puede leer el diagnóstico es el propio panel.
    public private(set) var mensajesRecibidos: Int = 0
    public private(set) var fotogramasRecibidos: Int = 0
    /// Fotogramas que llegaron y se tiraron por estar plegado o congelado. Se cuentan aparte
    /// porque «no llegó» y «llegó y lo tiré a propósito» tienen arreglos opuestos.
    public private(set) var fotogramasDescartados: Int = 0

    public init() {}

    /// REGLA: `freeze()` pertenece al ciclo de vida local. Solo lo llaman `endTurn()` y el fin
    /// del `AsyncStream`. Un mensaje del relé (`state` o `closed`) NUNCA congela: solo mueve los
    /// dos booleanos, porque el relé puede plegar y luego desplegar y el panel debe revivir.
    public func apply(_ event: BrowserRelayEvent) {
        if !isFrozen {
            if case .closed = event {} else { hasReceivedMessage = true }
        }
        // Se cuenta ANTES de cualquier guarda, incluidas las de congelado y plegado: la cuenta
        // sirve para explicar los descartes, así que descontarlos la dejaría ciega justo en el
        // caso que hay que explicar.
        mensajesRecibidos += 1
        if case .frame = event {
            fotogramasRecibidos += 1
            if isCollapsed { fotogramasDescartados += 1 }
        }
        switch event {
        case .summary(let text):
            // El resumen es la etiqueta del panel plegado: se acepta también plegado o congelado.
            summary = text
        case .state(let live, let collapsed):
            guard !isFrozen else { return }
            isLive = live
            closedReason = nil
            relayCollapsed = collapsed
            // §6.2(g): un panel plegado no deja imagen en reposo. Se cumple soltando el jpeg,
            // no congelando, para que `collapsed: false` pueda revivirlo.
            if collapsed { jpeg = nil; dimensionesDelCable = nil }
        case .closed(let reason):
            // NO es terminal: BrowserRelayClient reconecta tras un cierre y llegan más frames y
            // un `state` nuevo. Solo apagamos el en-vivo.
            guard !isFrozen else { return }
            isLive = false
            closedReason = reason
            // EL VOLANTE SE VA CON LA CONEXIÓN, y no se espera a que el servidor lo diga. El
            // portador del mando es el SOCKET (el relé identifica al portador por él, y cuando
            // muere `Mando.se_fue` devuelve el volante al agente), así que la conexión siguiente
            // nunca lo tiene. Seguir pintando «es tu turno» tras un corte es mentirle al usuario
            // mientras teclea: sus pulsaciones irían a un socket nuevo que no es el portador y el
            // relé las descartaría en silencio. Esto corre ANTES de la reconexión, que es la
            // dirección segura: `.closed` llega en el momento del corte y la reconexión viene
            // después, con su espera de retroceso.
            quienConduce = .agente
        case .mando(let quien):
            // Ya viene resuelto: `.yo` solo puede haberlo puesto el cliente que mandó la
            // petición. Aquí no se interpreta nada, se guarda.
            guard !isFrozen else { return }
            quienConduce = quien
        case .frame(_, let data, let capturedAt, let viewport):
            // Plegado o congelado: un frame tardío reabriría el secreto en reposo.
            guard !isCollapsed else { return }
            jpeg = data
            // Se asigna SIEMPRE, también cuando viene `nil`. Un fotograma sin dimensiones tiene
            // que BORRAR las del anterior: dejarlas puestas mapearía el toque siguiente contra
            // el viewport de una imagen vieja, en silencio y con el panel pintando bien.
            dimensionesDelCable = viewport
            closedReason = nil
            lastFrameAt = capturedAt
        case .narration(let text):
            guard !isCollapsed else { return }
            phrase = text
        case .host(let name):
            host = name
        }
    }

    /// Plega el panel para siempre y suelta la imagen: un panel congelado no deja pantalla
    /// del navegador en el historial (§6.2(g)).
    public func freeze() {
        isFrozen = true
        isLive = false
        jpeg = nil
        dimensionesDelCable = nil
        // Un panel congelado es historial: su flujo está cortado, así que por ahí ya no sale
        // ninguna pulsación. Decir «conduces tú» en un panel muerto invitaría al usuario a
        // teclear su contraseña en una ventana que no manda nada a ninguna parte.
        quienConduce = .agente
    }
}
