import Foundation
// Portabilidad: solo Foundation, más la capacidad de red donde vive separada
// (en Linux y Windows URLSessionWebSocketTask está en FoundationNetworking).
// `canImport` pregunta por una capacidad, no por un sistema operativo: no hay
// ramas por plataforma. Un cliente de iOS lo reusará tal cual.
// No decodifica la imagen: el JPEG sube en bytes.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Quién tiene el volante del navegador remoto, VISTO DESDE ESTE VISOR. Los tres valores no
/// vienen del cable: el servidor solo publica dos (ver `BrowserRelayEvent.mando`), y la
/// diferencia entre «conduzco yo» y «conduce otro visor» sale de correlacionar el mensaje con
/// lo que ESTE cliente pidió.
///
/// Por qué `otroVisor` no es `agente`, aunque en los dos casos el usuario no pueda teclear: el
/// botón de la vista se comporta distinto. Con `agente` el volante está libre y pedirlo
/// funciona; con `otroVisor` lo tiene un humano en otro aparato, el servidor rechazaría la toma
/// **en silencio** (`mando.toma` devuelve `False` y el relé descarta ese booleano) y lo honesto
/// es decir «lo tiene otro», no ofrecer un botón que no va a hacer nada.
public nonisolated enum QuienConduce: Equatable, Sendable {
    /// Nadie humano: el agente conduce y el volante está libre.
    case agente
    /// Lo tengo yo, en ESTE visor y en ESTA conexión.
    case yo
    /// Lo tiene un humano que no soy yo (otro aparato del usuario, otro visor del mismo relé).
    case otroVisor
}

/// Lo que el relé del i3 puede decirle al visor. Siete casos, ninguno con sitio
/// para parámetros de acciones: ni programando mal se podría transportar un secreto.
public nonisolated enum BrowserRelayEvent: Equatable, Sendable {
    case frame(seq: Int, jpeg: Data, capturedAt: Date)
    case narration(String)
    case host(String)
    case state(live: Bool, collapsed: Bool)
    case summary(String)
    case closed(reason: String)
    /// Quién conduce, YA RESUELTO para este visor. El cable trae dos valores
    /// (`{"type":"mando","quien":"agente"|"humano"}`, `browser/mando.py:463`) y no dice qué
    /// visor es el portador, a propósito: la identidad del portador no tiene que viajar a tres
    /// clientes. `decode` convierte el `"humano"` anónimo en el valor conservador `.otroVisor`
    /// y solo el actor —que sabe si fue ÉL quien pidió el volante— lo asciende a `.yo`.
    case mando(quien: QuienConduce)
}

/// El socket del visor, visto por lo poco que este cliente necesita de él: recibir texto,
/// mandar texto y cerrarse.
///
/// POR QUÉ EXISTE ESTE PROTOCOLO. Antes el socket era una variable local de `runOnce` y no
/// había forma de mandar nada desde fuera del bucle. Ahora hace falta: el usuario toma el
/// volante y teclea, y esos mensajes salen por el MISMO socket por el que llegan los
/// fotogramas (el relé identifica al portador por su socket, `relay.py:890`). Con el socket
/// detrás de un protocolo, el camino de envío —el que lleva la contraseña del usuario— se
/// puede medir entero sin red y sin un relé de verdad: la prueba inyecta su propio socket y lee
/// lo que salió. La alternativa era un seam que solo las pruebas instalan, que mide el arnés y
/// no la producción.
public protocol SocketDelVisor: Sendable {
    /// El siguiente mensaje de texto, o `nil` si lo que llegó no era texto (un marco binario,
    /// que este cliente ignora igual que antes). Lanza cuando el socket se cae.
    func recibeTexto() async throws -> String?
    func envia(_ texto: String) async throws
    func cierra()
}

extension URLSessionWebSocketTask: SocketDelVisor {
    public func recibeTexto() async throws -> String? {
        switch try await receive() {
        case .string(let texto): return texto
        case .data: return nil
        @unknown default: return nil
        }
    }

    public func envia(_ texto: String) async throws {
        try await send(.string(texto))
    }

    public func cierra() {
        cancel(with: .goingAway, reason: nil)
    }
}

/// Visor del WebSocket `/v1/browser/stream`. Acusa cada frame (el relé no acusa
/// al demonio hasta que se lo acusan a él) y reconecta con retroceso exponencial
/// cuando el relé cierra, porque el relé no se reengancha solo.
public actor BrowserRelayClient {
    /// Retroceso: 1, 2, 4, 8, 16, 30 s (tope). Sin esto, un `closed` inmediato
    /// (servicio del navegador caído) sería una tormenta de reconexiones.
    public static let maxReconnectDelay: TimeInterval = 30
    /// Fallos CONSECUTIVOS sin recibir ni un frame antes de rendirse (~2 min de espera total).
    public static let maxReconnectAttempts = 8

    public static func reconnectDelay(attempt: Int) -> TimeInterval {
        let exponent = max(0, min(attempt - 1, 10))
        return min(maxReconnectDelay, TimeInterval(1 << exponent))
    }

    /// Contador de fallos consecutivos tras un ciclo de conexión: un frame
    /// recibido lo reinicia a 1 (conexión sana); sin frame, crece de uno en uno.
    public static func nextFailureCount(current: Int, gotFrame: Bool) -> Int {
        gotFrame ? 1 : current + 1
    }

    /// Se rinde cuando los fallos consecutivos superan `maxReconnectAttempts`.
    public static func shouldGiveUp(failures: Int) -> Bool {
        failures > maxReconnectAttempts
    }

    /// Cuánto vive una petición del volante que nadie contesta.
    ///
    /// POR QUÉ CADUCA, Y NO ES UN ADORNO. Una toma RECHAZADA no produce ningún mensaje:
    /// `Mando.toma` devuelve `False` si el volante ya lo tiene otro (o uno mismo) y el manejador
    /// del visor descarta ese booleano (`relay.py:965`). El silencio es la única contestación
    /// posible. Sin caducidad, una petición se queda armada para siempre y le pone MI nombre al
    /// primer `"humano"` que pase: «pido el volante mientras lo tiene otro visor → silencio → el
    /// otro lo devuelve → `"agente"` → un tercero lo toma → `"humano"`» pintaría «es tu turno»
    /// siendo de otro, y el usuario escribiría su contraseña contra una página que no recibe su
    /// entrada. (El `"agente"` del medio ya descarta la petición, así que ese camino concreto
    /// está cerrado dos veces; la caducidad cubre el resto, incluido el `mando_tomar` que el
    /// relé tira por tope de caudal: `relay.py:959` aplica el caudal a todo lo que no es `ack`,
    /// también a la petición del volante, y también en silencio.)
    ///
    /// POR QUÉ SEIS SEGUNDOS. No hay medición: es un juicio, con sus dos bordes. Por abajo tiene
    /// que aguantar un viaje de ida y vuelta GENEROSO (iPhone → Tailscale → i3 doméstico, por
    /// datos móviles, con el relé atendiendo el mensaje en su bucle de eventos), y seis segundos
    /// es del orden de diez veces un enlace malo. Por arriba tiene que ser mucho menos que la
    /// paciencia del usuario con un botón que no responde: con un minuto, el usuario ya habría
    /// vuelto a pulsar dos veces y la petición vieja seguiría viva mientras él mira otra cosa.
    /// Lo que lo cambiaría: medir el viaje real contra el i3, o que el servidor llegue a
    /// contestar a la toma (y entonces esto desaparece, porque ya no haría falta correlacionar).
    public static let caducidadDeLaPeticion: Duration = .seconds(6)

    /// Lo que se manda para pedir el volante. El relé atiende este tipo y NO lo reenvía al
    /// demonio (`relay.py:676`); el campo `type` es lo único que lleva, y lo único que se mira.
    public static let payloadTomarElMando = #"{"type":"mando_tomar"}"#
    /// Lo que se manda para devolverlo. Mismo trato en el relé (`relay.py:967`).
    public static let payloadDevolverElMando = #"{"type":"mando_devolver"}"#

    private let baseURL: URL
    private let bearerToken: String
    /// Tope de fotogramas que la app PIDE. `nil` en producción: el tope del visor
    /// es del servicio, porque sale de su medición de caudal (el enlace móvil), y la
    /// app no debe tener una segunda opinión. Con `nil` el relé aplica su
    /// `DEFAULT_VIEWER_MAX_FPS`. Solo una prueba pasa un valor.
    private let maxFps: Int?
    private var loop: Task<Void, Never>?
    private var continuation: AsyncStream<BrowserRelayEvent>.Continuation?
    private var generation = 0
    /// Cómo se abre el socket. En producción es un `URLSessionWebSocketTask` ya arrancado; una
    /// prueba inyecta el suyo (ver `SocketDelVisor`).
    private let abreElSocket: @Sendable (URL, String) -> SocketDelVisor
    /// Reloj MONÓTONO, y eso es el punto: la caducidad de la petición se mide con
    /// `ContinuousClock` y no con `Date` porque un salto del reloj de pared (NTP, cambio de
    /// hora, el teléfono despertando) movería la caducidad de una petición ya hecha. Inyectable
    /// para que la prueba de la caducidad no tenga que esperar seis segundos de verdad.
    private let ahora: @Sendable () -> ContinuousClock.Instant

    /// El socket de la conexión EN CURSO, o `nil` si no hay ninguna. Es por donde sale la
    /// entrada del usuario, y es lo que hace que `manda(entrada:)` no mande nada con el socket
    /// caído: sin conexión no hay canal, y sin canal no hay envío.
    private var canal: SocketDelVisor?
    /// Cuándo pedí el volante por última vez, si la petición sigue sin contestar. Vive en el
    /// cliente y no en el panel a propósito: el portador del mando es la CONEXIÓN, así que la
    /// petición pertenece a quien la tiene, y así una reconexión se la lleva sin que nadie más
    /// tenga que acordarse de limpiarla.
    private var pedidoEl: ContinuousClock.Instant?

    public init(baseURL: URL, bearerToken: String, maxFps: Int? = nil, session: URLSession = .shared,
                abreElSocket: (@Sendable (URL, String) -> SocketDelVisor)? = nil,
                ahora: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.maxFps = maxFps
        self.ahora = ahora
        self.abreElSocket = abreElSocket ?? { url, token in
            var request = URLRequest(url: url)
            // El token va SOLO en la cabecera del handshake, nunca en la URL.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let socket = session.webSocketTask(with: request)
            socket.resume()
            return socket
        }
    }

    // MARK: puras

    public static func socketURL(baseURL: URL, maxFps: Int? = nil) -> URL? {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.scheme?.lowercased() {
        case "http", "ws": parts.scheme = "ws"
        case "https", "wss": parts.scheme = "wss"
        default: return nil
        }
        let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = base + "/v1/browser/stream"
        // Solo `maxFps` va en la query; el token va en la cabecera del handshake y
        // NO debe pasar a la URL (acaba en logs). Sin tope pedido no se añade nada.
        parts.queryItems = maxFps.map { [URLQueryItem(name: "maxFps", value: String($0))] }
        return parts.url
    }

    public static func decode(_ text: String) -> BrowserRelayEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "frame":
            guard let seq = (object["seq"] as? NSNumber)?.intValue,
                  let b64 = object["jpeg"] as? String,
                  // El relé puede pasar base64 envuelto en líneas; sin esto el panel quedaría negro.
                  let jpeg = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                  let seconds = (object["captured_at"] as? NSNumber)?.doubleValue else { return nil }
            return .frame(seq: seq, jpeg: jpeg, capturedAt: Date(timeIntervalSince1970: seconds))
        case "narration":
            return (object["text"] as? String).map { .narration($0) }
        case "host":
            return (object["host"] as? String).map { .host($0) }
        case "state":
            guard let live = object["live"] as? Bool, let collapsed = object["collapsed"] as? Bool else { return nil }
            return .state(live: live, collapsed: collapsed)
        case "summary":
            return (object["text"] as? String).map { .summary($0) }
        case "closed":
            return .closed(reason: (object["reason"] as? String) ?? "")
        case "mando":
            // UNA SOLA REGLA, Y CONSERVADORA: solo el literal exacto `"humano"` significa que
            // hay un humano al volante, y entonces se decodifica como `.otroVisor`, que es el
            // valor que NO le dice al usuario que teclee. Cualquier otra cosa —`"agente"`, un
            // `quien` ausente, de otro tipo, o un literal que este cliente no conozca— es
            // `.agente`. Es la dirección segura: con un mensaje que no entendemos, perder el
            // rótulo del volante cuesta un botón que hay que volver a pulsar, y pintar «es tu
            // turno» de más cuesta una contraseña escrita contra una página que no la recibe.
            return .mando(quien: (object["quien"] as? String) == "humano" ? .otroVisor : .agente)
        default:
            return nil
        }
    }

    public static func ackPayload(seq: Int) -> String {
        "{\"type\":\"ack\",\"seq\":\(seq)}"
    }

    /// Si una petición del volante hecha en `pedidaEn` sigue viva en `ahora`.
    ///
    /// `ContinuousClock` es monótono, así que `ahora` nunca es anterior a `pedidaEn` en
    /// producción y no hay que defenderse de un plazo negativo: la condición es una sola y su
    /// frontera es exacta (el instante justo de la caducidad todavía cuenta como viva).
    public static func peticionSigueViva(pedidaEn: ContinuousClock.Instant,
                                         ahora: ContinuousClock.Instant) -> Bool {
        pedidaEn.duration(to: ahora) <= caducidadDeLaPeticion
    }

    /// El `quien` del cable, resuelto para ESTE visor.
    ///
    /// La tabla entera, y el motivo de cada rama:
    /// - `.agente` → `.agente`. Nadie humano conduce, haya pedido yo o no.
    /// - `.otroVisor` + petición mía viva → `.yo`. El servidor dice «conduce un humano» y el
    ///   único humano que lo pidió hace un instante soy yo.
    /// - `.otroVisor` sin petición viva → `.otroVisor`. Conduce un humano que no soy yo.
    ///
    /// LA CARRERA QUE QUEDA, DECLARADA Y NO TAPADA. Dos visores piden el volante dentro del
    /// mismo viaje de ida y vuelta: el servidor se lo da a uno y al otro le contesta con
    /// silencio, así que los dos tienen petición viva y los dos leen ese `"humano"` como `.yo`.
    /// El perdedor se pinta «es tu turno» y su entrada se descarta en silencio (el relé compara
    /// el portador en `_reenvia_entrada`). Hay un discriminador disponible —al perdedor se le
    /// CORTAN los fotogramas, porque mientras conduce un humano la imagen va solo al portador
    /// (`relay.py:1033`)— y NO se usa a propósito: «si no llega fotograma en N segundos, no es
    /// mío» le quitaría el volante al usuario a mitad de una contraseña en una página estática,
    /// donde no llegan fotogramas porque no cambia nada. Eso es peor que la carrera: la carrera
    /// necesita dos visores pulsando a la vez y cuesta un rótulo equivocado; la heurística
    /// muerde al usuario solo, en el caso normal, y justo cuando más duele. Si algún día hace
    /// falta cerrarla, se cierra en el SERVIDOR diciéndole al visor si su toma fue concedida, no
    /// inventando aquí un tipo de mensaje nuevo: la lista de permitidos del relé no se abre por
    /// necesidad.
    public static func resuelve(_ quien: QuienConduce, peticionViva: Bool) -> QuienConduce {
        quien == .otroVisor && peticionViva ? .yo : quien
    }

    // MARK: ciclo de vida

    /// Un solo consumidor a la vez: pedir otro flujo termina el anterior.
    public func events() -> AsyncStream<BrowserRelayEvent> {
        endCurrent()
        generation += 1
        let mine = generation
        let (stream, cont) = AsyncStream<BrowserRelayEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation = cont
        loop = Task { [weak self] in
            await self?.run(cont)
            await self?.finishIfCurrent(generation: mine)
        }
        // Cancelar al consumidor cancela el bucle, y éste cierra el socket.
        cont.onTermination = { [weak self] _ in
            Task { await self?.terminated(generation: mine) }
        }
        return stream
    }

    public func stop() {
        endCurrent()
    }

    private func endCurrent() {
        loop?.cancel()
        loop = nil
        continuation?.finish()
        continuation = nil
    }

    private func terminated(generation g: Int) {
        guard g == generation else { return }
        loop?.cancel()
        loop = nil
        continuation = nil
    }

    private func finishIfCurrent(generation g: Int) {
        guard g == generation else { return }
        continuation?.finish()
        continuation = nil
        loop = nil
    }

    // MARK: el mando compartido

    /// Pide el volante del navegador remoto. Devuelve si el mensaje SALIÓ, no si fue concedido:
    /// el servidor no contesta a una toma, ni para bien ni para mal (ver
    /// `caducidadDeLaPeticion`). Lo único que confirma la concesión es el `mando` que llega
    /// después, y por eso aquí NO se mueve ningún estado visible.
    ///
    /// NUNCA SE PINTA `.yo` DE FORMA OPTIMISTA, y es el motivo de que esta rama exista: pintar
    /// «es tu turno» antes de que el servidor lo confirme es la mentira exacta que se está
    /// borrando, porque el usuario escribiría su contraseña contra una página que no está
    /// recibiendo su entrada. Si el botón quiere verse «pidiendo», ése es un estado de la
    /// petición y es de la vista, no de `quienConduce`.
    ///
    /// La petición se ARMA antes de mandar, no después: la respuesta del servidor llega por el
    /// bucle de recepción, que es otra tarea, y armarla después abriría la ventana en que el
    /// `"humano"` concedido a mí llega sin que nadie sepa que lo pedí.
    @discardableResult
    public func tomaElMando() async -> Bool {
        pedidoEl = ahora()
        let salio = await enviaPorElCanal(Self.payloadTomarElMando)
        // Una petición que no salió del aparato no puede estar viva: dejarla armada le pondría
        // mi nombre al volante de otro.
        if !salio { pedidoEl = nil }
        PanelLog.note("mando: el usuario pide el volante (salió=\(salio))")
        return salio
    }

    /// Devuelve el volante. Tampoco mueve estado: el servidor publica el `mando` con `"agente"`
    /// y ése es el que lo mueve. Lo que sí hace es desarmar la petición, para que una petición
    /// vieja no se quede esperando a ponerle mi nombre al volante del siguiente.
    @discardableResult
    public func devuelveElMando() async -> Bool {
        pedidoEl = nil
        let salio = await enviaPorElCanal(Self.payloadDevolverElMando)
        PanelLog.note("mando: el usuario devuelve el volante (salió=\(salio))")
        return salio
    }

    /// Manda al relé un mensaje de entrada YA CODIFICADO (`BrowserInputEvents`). Devuelve si
    /// salió. No manda nada con el socket caído, y no mira quién conduce: el relé compara el
    /// portador por su socket y descarta lo que no sea del portador, y quién puede teclear es
    /// una decisión de la vista, que es la que tiene el rótulo delante.
    ///
    /// Se comprueba el TOPE antes de mandar porque lo que lo pasa el relé lo descarta **en
    /// silencio** (`relay.py:655`): un mensaje demasiado grande desaparecería sin error y el
    /// usuario solo vería que no pasó nada. Un pegado largo se parte en varios mensajes de
    /// teclado, y eso es de quien los construye.
    ///
    /// ESTA FUNCIÓN NO REGISTRA NADA, Y LA AUSENCIA ES EL DISEÑO. Lo que viaja aquí puede ser la
    /// contraseña del usuario. No se registra el contenido, que es obvio, pero tampoco **una
    /// línea por mensaje sin contenido**: una traza por pulsación revela cuántas teclas tiene la
    /// contraseña y con qué ritmo se escribió, que es justo lo que no debe quedar en el log
    /// unificado de macOS, legible por cualquier proceso con permiso. Si algún día hace falta
    /// saber que el usuario está escribiendo, se dice UNA vez al tomar el volante (donde ya se
    /// dice) y no por tecla. Lo afirma `BrowserRelayClientTests`
    /// `.test_ninguna_linea_de_registro_de_este_cliente_lleva_la_entrada_del_usuario`, que lee
    /// este fuente, porque una ausencia no se puede observar ejecutando código.
    @discardableResult
    public func manda(entrada: String) async -> Bool {
        guard BrowserInputEvents.cabeEnElTope(entrada) else { return false }
        return await enviaPorElCanal(entrada)
    }

    /// El único camino de salida. Sin canal —nunca conectado, o el socket se cayó— no se manda
    /// nada y se dice que no se mandó. El error no se registra ni se reproduce: su descripción
    /// podría arrastrar el texto que iba dentro.
    ///
    /// Un canal que falla se SUELTA en el momento, sin esperar a que el bucle de recepción se
    /// entere: si no, cada pulsación siguiente volvería a intentarlo por un socket que ya no
    /// está, y entre el corte y el `.closed` cabe una contraseña entera.
    private func enviaPorElCanal(_ texto: String) async -> Bool {
        guard let canal else { return false }
        do {
            try await canal.envia(texto)
            return true
        } catch {
            self.canal = nil
            return false
        }
    }

    // MARK: bucle

    private func run(_ cont: AsyncStream<BrowserRelayEvent>.Continuation) async {
        guard let url = Self.socketURL(baseURL: baseURL, maxFps: maxFps) else {
            cont.yield(.closed(reason: "URL del relé inválida"))
            return
        }
        var failures = 0
        while !Task.isCancelled {
            let gotFrame = await runOnce(url: url, cont)
            if Task.isCancelled {
                PanelLog.note("visor: la conexión acabó y la tarea está cancelada; no se reintenta")
                return
            }
            failures = Self.nextFailureCount(current: failures, gotFrame: gotFrame)
            PanelLog.note("visor: conexión terminada (llegaron fotogramas=\(gotFrame)), fallos consecutivos=\(failures)")
            if Self.shouldGiveUp(failures: failures) {
                PanelLog.note("visor: se rinde tras \(failures) fallos; el panel se congelará")
                return
            }
            do { try await Task.sleep(for: .seconds(Self.reconnectDelay(attempt: failures))) }
            catch { return }
        }
    }

    /// Una conexión. Devuelve si llegó al menos un frame (conexión sana).
    private func runOnce(url: URL, _ cont: AsyncStream<BrowserRelayEvent>.Continuation) async -> Bool {
        let socket = abreElSocket(url, bearerToken)
        // Desde aquí hay por dónde mandar la entrada del usuario, y solo desde aquí.
        canal = socket
        var gotFrame = false
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                let texto: String?
                do { texto = try await socket.recibeTexto() }
                catch {
                    if !Task.isCancelled { cont.yield(.closed(reason: "fallo de recepción")) }
                    break
                }
                guard let texto, var event = Self.decode(texto) else { continue }
                if case .frame(let seq, _, _) = event {
                    gotFrame = true
                    // El demonio ignora en silencio lo que no entiende: un acuse que no
                    // llega solo se vería como frames que dejan de llegar. Si el envío
                    // falla, la conexión está caída: salir y dejar que reconecte.
                    do { try await socket.envia(Self.ackPayload(seq: seq)) }
                    catch {
                        if !Task.isCancelled { cont.yield(.closed(reason: "fallo al acusar")) }
                        break
                    }
                }
                if case .mando(let quien) = event {
                    let viva = pedidoEl.map { Self.peticionSigueViva(pedidaEn: $0, ahora: ahora()) } ?? false
                    event = .mando(quien: Self.resuelve(quien, peticionViva: viva))
                    // La petición se CONSUME con el primer mensaje de mando que llega, sea el que
                    // sea. Si el volante acabó siendo mío, ya está dicho; y si lo que llegó fue un
                    // `"agente"`, dejarla armada le pondría mi nombre al `"humano"` del siguiente
                    // que lo tome, que es el fallo que la tabla de esta tarea existe para cerrar.
                    pedidoEl = nil
                }
                cont.yield(event)
                if case .closed = event { break }
            }
        } onCancel: {
            socket.cierra()
        }
        socket.cierra()
        // El canal y la petición mueren CON la conexión: el portador del mando es la conexión,
        // así que un socket nuevo nunca lo tiene y nunca hereda una petición del anterior.
        canal = nil
        pedidoEl = nil
        return gotFrame
    }
}
