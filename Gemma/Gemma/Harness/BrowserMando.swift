import CoreGraphics
import Foundation
import SwiftUI

/// Lo que la vista necesita del volante del navegador remoto, y nada más.
///
/// POR QUÉ UN PROTOCOLO Y NO EL ACTOR. Dos razones, y las dos son del lado de la vista. La
/// primera es que el panel no tiene por qué saber que detrás hay un WebSocket, una reconexión
/// con retroceso exponencial y un bucle de acuses: lo único que hace es pedir el volante,
/// devolverlo y mandar lo que el usuario teclea. La segunda es medible: con el mando detrás de
/// un protocolo, las pruebas inyectan un doble que **cuenta llamadas sin abrir un socket**, así
/// que el camino que lleva la contraseña del usuario se puede medir entero sin red y sin un relé
/// de verdad.
///
/// LO QUE EL `Bool` SIGNIFICA, Y LO QUE NO. Significa «el mensaje SALIÓ del aparato», no
/// «concedido». Un `false` es que no hay conexión o que el mensaje pasa del tope del relé. Un
/// `true` **no autoriza a pintar «es tu turno»**: eso lo dice solo `BrowserPanelState.quienConduce`,
/// y solo cuando llega el mensaje `mando` del servidor. Pintarlo de forma optimista es la
/// mentira exacta que todo este subsistema existe para borrar, porque el usuario escribiría su
/// contraseña contra una página que no está recibiendo su entrada.
public protocol MandoDelNavegador: Sendable {
    @discardableResult func tomaElMando() async -> Bool
    @discardableResult func devuelveElMando() async -> Bool
    @discardableResult func manda(entrada: String) async -> Bool
}

extension BrowserRelayClient: MandoDelNavegador {}

/// La entrada del usuario cuando tiene el volante: de un gesto sobre la imagen del stream a los
/// mensajes exactos que el demonio espera, y de lo que teclea a sus pulsaciones.
///
/// PURO Y SIN ESTADO, igual que sus dos vecinos (`BrowserInputEvents`, `BrowserInputMapper`). No
/// abre sockets, no guarda nada y no decide quién puede teclear: eso es de la vista, que es la
/// que tiene el rótulo delante. Lo que hay aquí es la aritmética del muestreo y la del delta del
/// texto, que son las dos cosas que se pueden equivocar en silencio.
///
/// AQUÍ NO SE REGISTRA NADA, Y NO ES NEGOCIABLE. Por este fichero pasa la contraseña del usuario
/// —la tecla y la coordenada, que sobre un teclado en pantalla son lo mismo— y no se registra ni
/// el contenido, que es obvio, ni **una línea por pulsación sin contenido**: una traza por tecla
/// revela cuántas tiene la contraseña y con qué ritmo se escribió, y el log unificado de macOS
/// lo lee cualquier proceso con permiso. Lo afirma una prueba que LEE ESTE FUENTE con una lista
/// **blanca** de identificadores (`BrowserPanelViewTests`
/// `.test_el_mando_de_la_vista_solo_usa_identificadores_permitidos`), porque una ausencia no se
/// puede observar ejecutando código. Una lista **negra** no sirve: ya se midió que
/// `UserDefaults.standard.set`, un acumulador `static var` y el `userInfo` de
/// `NotificationCenter` pasaban verdes por una lista de palabras prohibidas.
public enum BrowserMandoEntrada {

    /// En qué momento de un gesto estamos. Tres, y el tercero no es simétrico con los otros dos:
    /// ver `mensajesDePuntero`.
    public enum Fase { case pulsa, mueve, suelta }

    // MARK: el muestreo de un gesto continuo

    /// El tope de entrada de UN visor en el relé: 120 mensajes por ventana de 1 s, con el acuse
    /// exento (`MAX_ENTRADAS_POR_VENTANA` y `VENTANA_DE_ENTRADA`, `browser/relay.py:469-470`).
    ///
    /// Está aquí copiado a mano a propósito, con su procedencia, porque es la cifra contra la que
    /// se justifica el muestreo de abajo y no hay forma de leerla desde Swift. Si cambia allí,
    /// cambia aquí, y una prueba lo clava.
    public static let topeDeEntradasPorSegundoDelRele = 120

    /// Cuántas veces por segundo se manda un gesto continuo (un arrastre).
    ///
    /// POR QUÉ 30, Y NO 60 NI 120. Tres cotas, y el número cae entre ellas:
    ///
    ///   1. **Por arriba, el presupuesto del relé, dejando sitio al teclado.** El tope es 120
    ///      mensajes por segundo por visor y lo que lo pasa se descarta **en silencio**. Pero el
    ///      daño de verdad no es perder un movimiento: **el acuse del visor es lo que mueve el
    ///      ritmo del demonio** (el relé acusa al demonio cuando le acusa un visor), así que una
    ///      inundación que agote el presupuesto deja el fotograma en vuelo sin acusar y
    ///      **congela el panel de TODOS los visores**, no solo del que inunda. Un mecanógrafo
    ///      rápido hace ~10 pulsaciones/s y cada una son dos mensajes (`keyDown` + `keyUp`), o
    ///      sea ~20; arrastrar y teclear a la vez es el peor caso humano. Con el arrastre
    ///      quedándose como mucho con **la mitad** del presupuesto, las dos cosas juntas no lo
    ///      agotan nunca. (El propio relé derivó su 120 suponiendo un arrastre de 60/s; 30 deja
    ///      el doble de margen que lo que él supuso.)
    ///   2. **Por abajo, el ritmo del stream.** El panel recibe 25 fotogramas por segundo
    ///      (medido), así que por encima de 25 muestras el usuario **no puede ver** la
    ///      diferencia: la respuesta visual al arrastre la da el fotograma siguiente, no la
    ///      muestra. 30 queda justo por encima para que el muestreo no sea el cuello de botella
    ///      visible, y ni una muestra más de las que se pueden percibir.
    ///   3. **Y el hilo principal.** Decodificar un fotograma de 1280×720 fuera del hilo
    ///      principal es lo que evitó que el chat saltara (`BrowserPanelView.decodeOffMain`). El
    ///      muestreo de un gesto corre en ese mismo hilo: recalcular y mandar por cada píxel
    ///      compite con la decodificación del fotograma siguiente, que es exactamente el trabajo
    ///      del que depende que el usuario vea dónde está tocando.
    ///
    /// Lo que lo cambiaría: medir el caudal real de un arrastre contra el i3 por datos móviles,
    /// o que el stream suba de 25 fps.
    public static let muestrasPorSegundo = 30

    /// El intervalo mínimo entre dos muestras de un gesto continuo. 33 ms ≈ 30,3 muestras por
    /// segundo: se redondea a milisegundos enteros porque el reloj del muestreo es un instante
    /// monótono y la precisión de más no compra nada.
    public static let intervaloDeMuestreo: Duration = .milliseconds(33)

    /// Si toca mandar la muestra siguiente de un gesto continuo.
    ///
    /// El primer evento de un gesto (`ultimo == nil`) **no espera a nadie**: es la pulsación, y
    /// retrasarla sería retrasar el clic del usuario. El reloj es `ContinuousClock` —monótono— y
    /// no `Date`: un salto del reloj de pared (NTP, el teléfono despertando) podría dejar el
    /// muestreo parado o abierto de par en par justo mientras el usuario arrastra.
    public static func tocaMuestrear(ultimo: ContinuousClock.Instant?,
                                     ahora: ContinuousClock.Instant) -> Bool {
        guard let ultimo else { return true }
        return ultimo.duration(to: ahora) >= intervaloDeMuestreo
    }

    // MARK: el puntero

    /// Si con este fotograma y esta vista se puede situar un toque en la página.
    ///
    /// POR QUÉ EXISTE Y NO ES UN ADORNO. Hay un camino en el que el panel se ve
    /// **perfectamente** y ningún toque se manda: sin dimensiones del cable (un servidor sin
    /// desplegar, o un fotograma sin `metadata`), o con una imagen que no es el viewport escalado
    /// (el guarda de proporción del mapa, que existe porque por el cable no viaja desplazamiento
    /// y un recorte no se podría corregir). El usuario tiene que poder SABERLO: «toco y no pasa
    /// nada» es indistinguible de media docena de fallos distintos y lo mandaría a buscar el
    /// problema en la red cuando está en el cable.
    ///
    /// Se pregunta por el CENTRO de la vista a propósito, y se pregunta **al mapa** en vez de
    /// repetir sus guardas: el centro es el punto que siempre cae dentro del rectángulo dibujado
    /// cuando el fotograma es mapeable, así que un `nil` ahí solo puede venir de las dimensiones
    /// o de la proporción, que es justo lo que se quiere detectar. Y preguntando al mapa no hay
    /// una segunda copia de sus condiciones que se pueda quedar atrás.
    public static func sePuedeApuntar(tamañoDeLaVista: CGSize,
                                      tamañoDeLaImagen: CGSize,
                                      dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?) -> Bool {
        let centro = CGPoint(x: tamañoDeLaVista.width / 2, y: tamañoDeLaVista.height / 2)
        return BrowserInputMapper.paginaDesde(punto: centro,
                                              tamañoDeLaVista: tamañoDeLaVista,
                                              tamañoDeLaImagen: tamañoDeLaImagen,
                                              dimensionesDelCable: dimensionesDelCable) != nil
    }

    /// Los mensajes que le toca mandar a un momento de un gesto, y el punto de la página que hay
    /// que recordar para el momento siguiente.
    ///
    /// `nil` EN `pagina` SIGNIFICA «NO HAY GESTO EN CURSO QUE CERRAR», y la lista vacía significa
    /// «no mandes nada». Nunca se manda `.zero`: (0, 0) es una coordenada buenísima —es el
    /// logotipo de casi cualquier página— así que tratar un toque imposible de mapear como un
    /// cero lo convertiría en un clic en la esquina de arriba a la izquierda de una página con la
    /// sesión del usuario abierta.
    ///
    /// LAS TRES FASES NO SON SIMÉTRICAS, y la asimetría es el punto de esta función:
    ///
    ///   - **`pulsa`** sin punto mapeable no manda nada y no recuerda nada. No hay daño: no se
    ///     ha abierto ningún gesto.
    ///   - **`mueve`** sin punto mapeable no manda nada **pero conserva la memoria**. El dedo
    ///     puede volver a entrar en la imagen, y si al salir se olvidara el último punto bueno,
    ///     el `suelta` de después se quedaría sin sitio donde levantar el botón.
    ///   - **`suelta`** cae al último punto bueno si el actual no se puede mapear, y ÉSA es la
    ///     excepción a la dirección segura, a propósito y por una razón medida: ya se mandó un
    ///     `mousePressed`. Un `mousePressed` sin su `mouseReleased` deja el botón del ratón
    ///     **hundido** en la página remota y a partir de ahí todo lo que el usuario toque
    ///     arrastra. No mandar el soltar no es callarse: es dejarle el navegador roto. Si no hay
    ///     ningún punto bueno tampoco se manda, y ahí sí es correcto, porque entonces el `pulsa`
    ///     tampoco mandó nada y no hay botón hundido.
    ///
    /// Las coordenadas que salen del mapa **ya vienen enteras y ya en rango** `0…ancho-1`, así
    /// que aquí se pasan a `Int(_:)` directamente. **No se vuelve a redondear**: redondear dos
    /// veces es cómo se pierde un píxel.
    public static func mensajesDePuntero(fase: Fase,
                                          punto: CGPoint,
                                          ultimaPagina: CGPoint?,
                                          tamañoDeLaVista: CGSize,
                                          tamañoDeLaImagen: CGSize,
                                          dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?)
        -> (mensajes: [String], pagina: CGPoint?) {

        let pagina = BrowserInputMapper.paginaDesde(punto: punto,
                                                    tamañoDeLaVista: tamañoDeLaVista,
                                                    tamañoDeLaImagen: tamañoDeLaImagen,
                                                    dimensionesDelCable: dimensionesDelCable)
        switch fase {
        case .pulsa:
            guard let pagina else { return ([], nil) }
            return ([BrowserInputEvents.mouse(tipo: .pulsado, x: Int(pagina.x), y: Int(pagina.y),
                                              boton: .izquierdo, pulsaciones: 1)], pagina)
        case .mueve:
            guard let pagina else { return ([], ultimaPagina) }
            // `pulsaciones: 0` porque para un movimiento el recuento de clics no significa nada.
            return ([BrowserInputEvents.mouse(tipo: .movido, x: Int(pagina.x), y: Int(pagina.y),
                                              boton: .izquierdo, pulsaciones: 0)], pagina)
        case .suelta:
            guard let donde = pagina ?? ultimaPagina else { return ([], nil) }
            return ([BrowserInputEvents.mouse(tipo: .soltado, x: Int(donde.x), y: Int(donde.y),
                                              boton: .izquierdo, pulsaciones: 1)], nil)
        }
    }

    // MARK: el teclado

    /// Las pulsaciones que convierten `anterior` en `nuevo`.
    ///
    /// POR QUÉ UN DELTA Y NO «LA TECLA QUE SE PULSÓ». Porque en el teléfono no hay teclas: hay un
    /// campo de texto y un teclado del sistema que puede insertar, borrar, autocorregir y pegar.
    /// Lo único observable es que el texto era uno y ahora es otro. El delta es lo que de verdad
    /// pasó, y cubre gratis los cuatro casos.
    ///
    /// LA FORMA DEL DELTA: se borra hasta el prefijo común y se escribe el resto. Es lo que hace
    /// un humano y es lo que la página espera, porque el cursor está al final de lo que se
    /// escribió. Un cambio en medio («roi» → «rob») sale como un `Backspace` y una `b`.
    ///
    /// SE TROCEA POR CARACTERES DE SWIFT (GRAFEMAS) Y NO POR ESCALARES UNICODE. `"é"` compuesta
    /// son dos escalares y un solo grafema; mandarla como dos teclas escribiría basura en la
    /// contraseña del usuario. Es la misma razón por la que el troceado de la prueba de la lista
    /// blanca reconoce letras Unicode: los identificadores de este proyecto llevan `ñ`.
    ///
    /// SIN CAMBIO NO SE MANDA NADA, y no es una optimización: `onChange` de SwiftUI se dispara
    /// por motivos que no son una tecla nueva, y un mensaje por cada evaluación de la vista sería
    /// una inundación del presupuesto de caudal del relé — o sea el panel de todos congelado.
    ///
    /// NI `anterior` NI `nuevo` SE REGISTRAN, y tampoco los mensajes que los contienen. Es la
    /// restricción de la cabecera y es el motivo de que esta función no tenga ninguna rama de
    /// error: no hay dónde escribir un mensaje que los reprodujera.
    public static func mensajesDeTeclado(anterior: String, nuevo: String) -> [String] {
        let antes = Array(anterior)
        let despues = Array(nuevo)
        var comun = 0
        while comun < antes.count, comun < despues.count, antes[comun] == despues[comun] {
            comun += 1
        }

        var salida: [String] = []
        // El borrado NO lleva texto: la tecla de borrar no inserta nada, y mandar un `text` con
        // contenido insertaría ese contenido además de borrar.
        for _ in comun..<antes.count {
            salida.append(BrowserInputEvents.keyboard(tipo: .abajo, tecla: Self.claveDeBorrar, texto: ""))
            salida.append(BrowserInputEvents.keyboard(tipo: .arriba, tecla: Self.claveDeBorrar, texto: ""))
        }
        for caracter in despues[comun...] {
            let clave = Self.claveDe(caracter)
            let texto = Self.textoDe(caracter)
            salida.append(BrowserInputEvents.keyboard(tipo: .abajo, tecla: clave, texto: texto))
            salida.append(BrowserInputEvents.keyboard(tipo: .arriba, tecla: clave, texto: texto))
        }
        return salida
    }

    /// El nombre de la tecla de borrar en el protocolo del demonio (nombre de CDP).
    private static let claveDeBorrar = "Backspace"
    /// Y el de la tecla de retorno. Se manda como `Enter` y no como un carácter `\n` porque es la
    /// tecla que **envía un formulario**, que es justo lo que el usuario necesita para entrar en
    /// su cuenta; un `\n` suelto en un campo de una línea no hace nada.
    private static let claveDeRetorno = "Enter"
    private static let saltoDeLinea: Character = "\n"
    /// El `text` del retorno: CDP manda el retorno de carro, no el salto de línea.
    private static let textoDelRetorno = "\r"

    private static func claveDe(_ caracter: Character) -> String {
        caracter == saltoDeLinea ? claveDeRetorno : String(caracter)
    }

    private static func textoDe(_ caracter: Character) -> String {
        caracter == saltoDeLinea ? textoDelRetorno : String(caracter)
    }
}

// MARK: - las dos vistas del mando

/// La capa invisible que recoge los gestos **sobre la imagen del stream**.
///
/// POR QUÉ VA ENGANCHADA A LA `Image` Y NO AL CONTENEDOR, que es la decisión que cambia el mapa.
/// `.scaledToFit()` hace que la vista de la `Image` mida ya el **rectángulo dibujado**, no el
/// marco: el marco es `.frame(maxWidth: .infinity).frame(height: 220)`, de altura fija y anchura
/// del panel, así que su proporción depende del teléfono, de la rotación y de si el panel está
/// expandido, y nunca coincide con la del JPEG por construcción. Enganchando el gesto a la
/// imagen pasan dos cosas buenas:
///
///   1. Un toque sobre la banda **no llega** al reconocedor, en vez de llegar y ser descartado:
///      la clase entera de error desaparece en vez de gestionarse.
///   2. El relleno del contenedor deja de poder desplazar el origen en silencio, que es el único
///      fallo de esta familia que el mapa **no puede** detectar.
///
/// La lógica de bandas del mapa queda entonces **inerte, y eso está bien**: es la red por si
/// alguien cambia el enganche. No está muerta ni hay que borrarla.
///
/// `allowsHitTesting(capturar)` ES LA PUERTA, Y ES LO QUE EL USUARIO PIDIÓ. Con el volante del
/// agente esta capa no existe para los dedos: el toque pasa de largo al chat y el usuario **sigue
/// pudiendo desplazar la conversación y escribirle al agente** con el navegador a la vista. Si
/// tragara los gestos mientras el panel existe, le quitaría eso.
struct BrowserMandoGestos: View {
    let capturar: Bool
    let tamañoDeLaImagen: CGSize
    let dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?
    let mando: MandoDelNavegador?

    /// El último punto de la página que se pudo mapear en este gesto, para que el soltar tenga
    /// dónde levantar el botón si el dedo sale de la imagen.
    @State private var ultimaPagina: CGPoint?
    /// Cuándo se mandó la última muestra de este gesto. `nil` entre gestos, y eso es lo que
    /// distingue la pulsación del movimiento.
    @State private var ultimoMuestreo: ContinuousClock.Instant?
    /// La cadena de envíos, en orden. Existe porque un `mouseReleased` que adelantara a su
    /// `mousePressed` dejaría el botón hundido en la página remota: cada envío espera al
    /// anterior, así que el orden de los mensajes es el orden de los gestos.
    @State private var cola: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometria in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { valor in
                            // `onChanged` se dispara también con el primer contacto, así que la
                            // pulsación es el evento que llega sin muestreo previo.
                            let fase: BrowserMandoEntrada.Fase = ultimoMuestreo == nil ? .pulsa : .mueve
                            manda(fase: fase, punto: valor.location, vista: geometria.size)
                        }
                        .onEnded { valor in
                            manda(fase: .suelta, punto: valor.location, vista: geometria.size)
                            ultimoMuestreo = nil
                            ultimaPagina = nil
                        }
                )
        }
        .allowsHitTesting(capturar)
    }

    /// Mapea, muestrea y manda. El mapa se consulta **siempre**, también cuando el muestreo va a
    /// descartar la muestra: es aritmética barata, y así el último punto bueno nunca se queda
    /// atrás (lo caro, y lo que el tope del relé cuenta, es el mensaje).
    private func manda(fase: BrowserMandoEntrada.Fase, punto: CGPoint, vista: CGSize) {
        let ahora = ContinuousClock.Instant.now
        let salida = BrowserMandoEntrada.mensajesDePuntero(fase: fase,
                                                           punto: punto,
                                                           ultimaPagina: ultimaPagina,
                                                           tamañoDeLaVista: vista,
                                                           tamañoDeLaImagen: tamañoDeLaImagen,
                                                           dimensionesDelCable: dimensionesDelCable)
        ultimaPagina = salida.pagina
        // La pulsación y el soltar no se muestrean nunca: son los dos extremos del clic.
        if fase == .mueve, !BrowserMandoEntrada.tocaMuestrear(ultimo: ultimoMuestreo, ahora: ahora) {
            return
        }
        ultimoMuestreo = ahora
        encola(salida.mensajes)
    }

    private func encola(_ mensajes: [String]) {
        guard let mando, !mensajes.isEmpty else { return }
        let previa = cola
        cola = Task {
            await previa?.value
            for mensaje in mensajes {
                await mando.manda(entrada: mensaje)
            }
        }
    }
}

/// La barra del mando: el botón, el rótulo de quién conduce, el aviso de cuando no se puede
/// apuntar, y el campo por donde entra lo que el usuario teclea.
///
/// EL CAMPO SOLO EXISTE CUANDO EL VOLANTE ES SUYO, y es la frase textual del usuario la que lo
/// manda: quiere **seguir escribiendo en el chat** con el navegador a la vista. Un campo
/// enfocado que se trague las teclas del teléfono mientras el panel existe le quita eso.
///
/// Y SE APAGA EN EL MISMO CAMBIO DE ESTADO en que el volante deja de ser suyo — no al final de un
/// gesto, no tras un plazo. El plazo del mando mide **inactividad**, y pensar no es actividad: el
/// volante se le puede caer justo mientras piensa la contraseña. En ese mismo instante el campo
/// desaparece, lo que quedara escrito se borra y el foco se suelta.
///
/// POR QUÉ `SecureField` Y NO `TextField`. El campo local no tiene que enseñar nada: la página
/// remota ya echa su propio eco por el stream (puntos en un campo de contraseña, texto en uno
/// normal), así que un eco local sería redundante **y dejaría la contraseña a la vista en el
/// historial del chat**, que es el secreto en reposo que el panel se cuida de no dejar.
struct BrowserMandoBarra: View {
    let state: BrowserPanelState
    let mando: MandoDelNavegador?
    let sePuedeApuntar: Bool

    @State private var tecleado = ""
    /// Cuándo se pidió el volante, si se está pidiendo. Es estado **de la vista** y no de
    /// `quienConduce` a propósito: pedirlo no lo concede.
    @State private var pidiendoDesde: ContinuousClock.Instant?
    @FocusState private var enfocado: Bool
    @State private var cola: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(pidiendoDesde == nil
                       ? BrowserPanelView.textoDelBoton(quienConduce: state.quienConduce)
                       : BrowserPanelView.textoDelBotonPidiendo) {
                    pulsa()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(mando == nil
                          || pidiendoDesde != nil
                          || !BrowserPanelView.elBotonActua(quienConduce: state.quienConduce))
                Text(BrowserPanelView.rotuloDeQuienConduce(quienConduce: state.quienConduce))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            if let aviso = BrowserPanelView.avisoDeApuntado(quienConduce: state.quienConduce,
                                                            sePuedeApuntar: sePuedeApuntar) {
                Text(aviso)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            if BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce) {
                SecureField(Self.pistaDelCampo, text: $tecleado)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .focused($enfocado)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
        }
        // EL CAMBIO DE ESTADO QUE APAGA LA CAPTURA. Va aquí, en el mismo sitio donde se entera la
        // vista, y no tras un plazo ni al acabar un gesto.
        .onChange(of: state.quienConduce) { _, _ in
            pidiendoDesde = nil
            // Se borra lo escrito y se suelta el foco. El borrado NO manda `Backspace` a la
            // página: el guarda de abajo mira quién conduce, y aquí ya no es el usuario. Si los
            // mandara, el número de pulsaciones delataría la longitud de la contraseña.
            tecleado = ""
            enfocado = false
        }
        .onChange(of: tecleado) { anterior, nuevo in
            guard BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce) else { return }
            encola(BrowserMandoEntrada.mensajesDeTeclado(anterior: anterior, nuevo: nuevo))
        }
        // LA PETICIÓN SE CAE SOLA. Una toma rechazada no produce **ningún** mensaje (`Mando.toma`
        // devuelve `False` y el relé descarta ese booleano), y el tope de caudal del relé se
        // aplica también al `mando_tomar`, así que la petición puede perderse en silencio con el
        // socket perfectamente sano. Sin esto el botón se quedaría en «pidiendo…» para siempre y
        // el usuario no tendría forma de saber que no pasó nada ni de volver a pulsar.
        .task(id: pidiendoDesde) {
            guard pidiendoDesde != nil else { return }
            try? await Task.sleep(for: BrowserRelayClient.caducidadDeLaPeticion)
            pidiendoDesde = nil
        }
    }

    /// La pista del campo. No dice «contraseña»: lo que el usuario teclea puede ser un correo,
    /// una dirección o un código, y nombrarlo de más sería adivinar.
    private static let pistaDelCampo = "lo que escribas va a la página"

    private func pulsa() {
        guard let mando else { return }
        if BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce) {
            // Devolverlo no se queda en «pidiendo»: el servidor publica el `mando` con
            // `"agente"` y ése es el que mueve el rótulo.
            Task { await mando.devuelveElMando() }
        } else {
            pidiendoDesde = ContinuousClock.Instant.now
            Task { await mando.tomaElMando() }
        }
    }

    private func encola(_ mensajes: [String]) {
        guard let mando, !mensajes.isEmpty else { return }
        let previa = cola
        cola = Task {
            await previa?.value
            for mensaje in mensajes {
                await mando.manda(entrada: mensaje)
            }
        }
    }
}
