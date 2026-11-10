import SwiftUI
import ImageIO

/// Panel del chat con lo que el navegador del agente está haciendo. Dos estados: en vivo
/// (frame + frase + «en vivo») y colapsado (una línea con el resumen y sin imagen).
/// Todo lo que muestra sale del estado; la vista no deduce «vivo» de que lleguen frames.
struct BrowserPanelView: View {
    let state: BrowserPanelState
    /// El volante de ESTE panel, o `nil` si no hay relé configurado. Lo entrega el coordinador,
    /// que es el único sitio que empareja un panel con su flujo. Sin valor por omisión a
    /// propósito: un `nil` implícito dejaría un botón muerto sin que nada se pusiera rojo.
    let mando: MandoDelNavegador?
    /// El gesto en curso y lo que no salió, de ESTE panel. Lo entrega el coordinador al lado del
    /// mando, y sin valor por omisión por la misma razón: ver `BrowserMandoSesion`.
    let sesion: BrowserMandoSesion?
    @State private var image: CGImage?

    var body: some View {
        Group {
            // Nada antes de oír al relé: sin i3 detrás el panel no aparece (spec §6.2(e), §8).
            if !state.hasReceivedMessage { EmptyView() }
            else if state.isCollapsed { collapsed } else { live }
        }
        // `lastFrameAt` identifica el frame con una comparación de fechas; usar el JPEG como id
        // obligaría a SwiftUI a comparar los bytes enteros en el hilo principal en cada evaluación.
        .task(id: Self.frameID(jpeg: state.jpeg, lastFrameAt: state.lastFrameAt)) {
            guard let jpeg = state.jpeg else { image = nil; return }
            // ImageIO fuera del hilo principal: un frame de 1280x720 decodificado aquí haría saltar el chat.
            let decoded = await Self.decodeOffMain(jpeg)
            // Un frame viejo que termina tarde no debe pintarse encima de uno nuevo.
            if !Task.isCancelled { image = decoded }
        }
    }

    private var collapsed: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe").font(.caption)
            Text(state.summary.isEmpty ? "navegador" : state.summary)
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.host.map { "\(state.phrase) · \($0)" } ?? state.phrase)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let reason = state.closedReason {
                // El usuario tiene que poder leer por qué el panel está muerto sin ir a Ajustes.
                Text(reason.isEmpty ? "Conexión con el navegador cerrada (sin motivo)." : "Conexión con el navegador cerrada: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        // EL GESTO VA ENGANCHADO A LA IMAGEN, NO AL CONTENEDOR. Con
                        // `.scaledToFit()` la vista de la `Image` mide ya el rectángulo
                        // dibujado, así que este `overlay` cubre exactamente la página y un
                        // toque sobre la banda NO LLEGA aquí. El contenedor, en cambio, tiene
                        // altura fija y anchura del panel: su proporción no coincide nunca con
                        // la del JPEG, y su relleno podría desplazar el origen en silencio —el
                        // único fallo de esta familia que el mapa no puede detectar.
                        //
                        // El tamaño de la imagen se lee del `CGImage` DECODIFICADO y nunca de
                        // una constante: el día que los topes del servidor cambien, una
                        // constante seguiría compilando y el usuario empezaría a pulsar botones
                        // que no quería sin que nada se pusiera rojo.
                        .overlay {
                            BrowserMandoGestos(
                                capturar: Self.capturaLosGestos(quienConduce: state.quienConduce),
                                tamañoDeLaImagen: CGSize(width: image.width, height: image.height),
                                dimensionesDelCable: state.dimensionesDelCable,
                                sesion: sesion)
                        }
                } else {
                    // NUNCA un rectángulo mudo. Sin imagen, el relleno era
                    // `Color.secondary.opacity(0.1)` a secas: en modo claro se lee como un hueco
                    // gris, pero en MODO OSCURO —que es como el usuario lleva el teléfono— es un
                    // rectángulo negro sin una sola palabra. El usuario lo describió como «la
                    // pantalla del navegador se veía negra», y no tenía forma de saber si era el
                    // stream, la app o la página. Hay dos momentos normales en que no hay imagen
                    // (antes del primer fotograma, mientras el demonio arranca, que son varios
                    // segundos; y después de que el panel suelte la imagen al cerrarse), así que
                    // el hueco es frecuente y tiene que explicarse solo.
                    ZStack {
                        Color.secondary.opacity(0.1)
                        VStack(spacing: 8) {
                            if Self.esperandoLaPrimera(closedReason: state.closedReason, isLive: state.isLive) {
                                ProgressView().controlSize(.small)
                            }
                            Text(Self.textoSinImagen(closedReason: state.closedReason,
                                                     isLive: state.isLive,
                                                     hayJpeg: state.jpeg != nil))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                            // La cuenta, en pequeño: es la que distingue «no llega nada» de
                            // «llegan fotogramas y no se pintan», que se ven igual desde fuera.
                            // Solo cuando informa — ver `muestraLaCuenta`: es diagnóstico en la
                            // pantalla del usuario, y sobre un panel que pintó cuarenta
                            // fotogramas y soltó la imagen al cerrarse no diagnostica nada.
                            if Self.muestraLaCuenta(fotogramas: state.fotogramasRecibidos,
                                                    descartados: state.fotogramasDescartados,
                                                    hayJpeg: state.jpeg != nil) {
                                Text(Self.cuenta(mensajes: state.mensajesRecibidos,
                                                 fotogramas: state.fotogramasRecibidos,
                                                 descartados: state.fotogramasDescartados))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            // Altura estable: el primer frame no debe mover el resto del historial.
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            BrowserMandoBarra(state: state, mando: mando, sePuedeApuntar: sePuedeApuntar, sesion: sesion)
            HStack(spacing: 6) {
                Spacer()
                // Presentación y nada más (spec §8(2)): si está vivo lo dice el i3.
                if let last = state.lastFrameAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let age = ctx.date.timeIntervalSince(last)
                        if age > 2 {
                            Text("último cambio hace \(Int(age)) s")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                        }
                    }
                }
                if state.isLive {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("en vivo").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Si con el fotograma que hay AHORA MISMO se puede situar un toque en la página.
    ///
    /// Se le pasa al mapa el tamaño de la imagen como tamaño de la vista a propósito: en ese caso
    /// la escala de dibujo es 1 y no hay bandas, así que lo único que puede devolver `nil` son
    /// las dimensiones del cable o el guarda de proporción — que son exactamente las dos causas
    /// que el aviso tiene que contarle al usuario. El tamaño real de la vista lo mide el gesto,
    /// dentro de su `GeometryReader`, y no hace falta aquí: un punto sobre la banda no llega al
    /// reconocedor porque el gesto va enganchado a la imagen.
    ///
    /// Sin imagen devuelve `true`: no hay nada que apuntar todavía, y el hueco ya se explica solo
    /// con `textoSinImagen`. Un aviso de «no se puede situar un toque» sobre un panel que aún no
    /// ha pintado el primer fotograma culparía al cable de algo que no ha pasado.
    private var sePuedeApuntar: Bool {
        guard let image else { return true }
        let tamaño = CGSize(width: image.width, height: image.height)
        return BrowserMandoEntrada.sePuedeApuntar(tamañoDeLaVista: tamaño,
                                                  tamañoDeLaImagen: tamaño,
                                                  dimensionesDelCable: state.dimensionesDelCable)
    }

    // MARK: el mando — lo que se puede probar sin pintar

    /// Lo que dice el botón del volante.
    ///
    /// LOS TRES CASOS, Y POR QUÉ EL TERCERO NO ES EL PRIMERO. Con el agente al volante está
    /// libre y pedirlo funciona. Con otro visor lo tiene un humano en otro aparato y el servidor
    /// rechazaría la toma **en silencio** —`Mando.toma` devuelve `False` y el manejador del visor
    /// descarta ese booleano (`relay.py:965`), no hay respuesta de error—, así que ofrecer
    /// «tomar el volante» sería prometer algo que no va a pasar y el usuario no recibiría
    /// ninguna explicación. Lo honesto es decir quién lo tiene.
    static func textoDelBoton(quienConduce: QuienConduce) -> String {
        switch quienConduce {
        case .agente: return "Tomar el volante"
        case .yo: return "Devolverlo"
        case .otroVisor: return "Lo tiene otro visor"
        }
    }

    /// Lo que dice el botón mientras la petición está en vuelo. No es un valor de
    /// `quienConduce`: pedir el volante no lo concede, y pintar «es tu turno» antes de que el
    /// servidor lo confirme es la mentira que el usuario pagaría escribiendo su contraseña
    /// contra una página que no la recibe.
    static let textoDelBotonPidiendo = "Pidiendo el volante…"

    /// Si pulsar el botón puede hacer algo. Con otro visor al volante, no: el servidor lo
    /// rechazaría en silencio. (`Mando.toma` devuelve `False` **también si el que pide ya lo
    /// tiene**, así que un segundo toque nunca re-confirma nada; por eso el caso `.yo` sí actúa,
    /// pero devolviendo.)
    static func elBotonActua(quienConduce: QuienConduce) -> Bool {
        quienConduce != .otroVisor
    }

    /// El rótulo de quién conduce.
    ///
    /// EL CASO `.otroVisor` NO ES COSMÉTICO. Mientras conduce un humano, el fotograma va **solo a
    /// su socket** (`relay.py:1033`); el estado, el resumen, la narración y el `mando` siguen
    /// yendo a todos los visores, precisamente para que uno que no conduce lo SEPA. Sin esta
    /// frase el usuario ve una imagen parada y sin explicación, que es el fallo de la foto
    /// congelada que ya se arregló una vez.
    static func rotuloDeQuienConduce(quienConduce: QuienConduce) -> String {
        switch quienConduce {
        case .agente: return "Conduce el agente."
        case .yo: return "Conduces tú: lo que toques y escribas va a la página."
        case .otroVisor: return "Conduce otro visor: la imagen no se actualiza aquí."
        }
    }

    /// El aviso de cuando el panel se ve bien y aun así ningún toque se puede mandar, o `nil` si
    /// no hay nada que avisar.
    ///
    /// POR QUÉ HACE FALTA: existe un camino en el que el fotograma llega, se pinta perfecto, y el
    /// mapa se calla —sin dimensiones del cable, o con una imagen que no es el viewport escalado—
    /// y entonces el usuario toca y no pasa nada. «Toco y no pasa nada» es indistinguible de
    /// media docena de fallos distintos y lo mandaría a buscar el problema en la red cuando está
    /// en el cable. **No se le deja mudo.**
    ///
    /// Solo sale cuando el volante es SUYO: decírselo mientras conduce el agente sería ruido
    /// sobre algo que no podría hacer de todas formas. Y dice que **escribir sí funciona**,
    /// porque es verdad y porque es lo que vino a hacer: el teclado no necesita coordenadas.
    ///
    /// **Y EL AVISO DE LO QUE NO SALIÓ VA PRIMERO, Y SALE CONDUZCA QUIEN CONDUZCA.** Un envío que
    /// falla (`BrowserMandoEnvio.encola`, `alFallar`) es un socket caído o un mensaje que pasa
    /// del tope del relé, y el `.closed` que pone el rótulo en «conduce el agente» llega **justo
    /// después**: si este aviso exigiera `.yo`, desaparecería en el mismo instante en que tiene
    /// algo que decir. No dice **nada** de lo que se escribió —ni el texto, ni cuánto—: no lo
    /// recibe.
    static func avisoDeApuntado(quienConduce: QuienConduce, sePuedeApuntar: Bool, entradaPerdida: Bool) -> String? {
        if entradaPerdida { return textoDeEntradaPerdida }
        guard quienConduce == .yo, !sePuedeApuntar else { return nil }
        return "Tienes el volante y puedes escribir, pero este fotograma no se puede situar: ningún toque se mandará."
    }

    /// Lo que se le dice al usuario cuando algo de lo que mandó no salió del aparato. Dice qué
    /// pasó y qué hacer, y nada de lo que escribió.
    static let textoDeEntradaPerdida =
        "Lo último que escribiste o tocaste NO llegó al navegador. Vuelve a tomar el volante y repítelo."

    /// Si la vista captura los gestos y las teclas del usuario.
    ///
    /// **SOLO CUANDO EL VOLANTE ES SUYO, y es la frase textual del usuario la que lo manda:**
    /// quiere seguir escribiendo en el chat con el navegador a la vista. Un teclado que se trague
    /// todas las teclas del teléfono mientras el panel existe le quita eso.
    ///
    /// Y ES LO QUE IMPIDE EL GESTO INÚTIL. El relé compara el portador por su socket y descarta
    /// la entrada ajena **en silencio** (`_reenvia_entrada`), así que sin esta puerta el usuario
    /// tocaría sin efecto y **sin que nada se lo diga**. La interfaz tiene que impedir el gesto,
    /// no confiar en que el servidor lo tire.
    ///
    /// Como es una función de `quienConduce` y de nada más, se apaga **en el mismo cambio de
    /// estado** en que el volante deja de ser suyo: no hay plazo que esperar ni gesto que
    /// terminar. Importa porque el plazo del mando mide **inactividad** y pensar no es actividad,
    /// así que el volante se le puede caer a mitad de una contraseña.
    static func capturaLosGestos(quienConduce: QuienConduce) -> Bool {
        quienConduce == .yo
    }

    /// Qué decir en el hueco de la imagen. Puro y estático para poder probarlo sin montar la
    /// vista: lo que importa es que NINGUNA combinación de estado devuelva una cadena vacía, que
    /// es lo que dejaría otra vez un rectángulo mudo.
    static func textoSinImagen(closedReason: String?, isLive: Bool, hayJpeg: Bool = false) -> String {
        // Este caso va EL PRIMERO y es el que faltaba: hay bytes de fotograma guardados y aun así
        // no hay imagen en pantalla, o sea que la decodificación falló. Antes caía en «Esperando
        // la primera imagen», que es exactamente lo contrario de lo que pasa y manda a buscar el
        // fallo en la red cuando está en la app.
        if hayJpeg { return "Llegó un fotograma pero no se pudo decodificar." }
        if closedReason != nil { return "Sin imagen: la conexión con el navegador se cerró." }
        if !isLive { return "Sin imagen: el panel está congelado." }
        return "Esperando la primera imagen del navegador…"
    }

    /// La línea de cuentas del hueco. Siempre dice algo: un hueco sin cuentas no distingue
    /// «el socket no habló» de «habló y no mandó fotogramas».
    /// Si la línea de cuentas se pinta.
    ///
    /// ES UNA LÍNEA DE DIAGNÓSTICO EN LA PANTALLA DEL USUARIO, y eso hay que ganárselo. Los
    /// contadores los puso un commit `diag(...)` para entender «el panel se muere», el usuario
    /// los leyó en su teléfono y los reportó. No se borran —el misterio que diagnostican,
    /// «mensajes 6 · fotogramas 0»: el socket habla y no llega ni un fotograma, sigue sin
    /// explicación— pero solo se muestran cuando de verdad informan.
    ///
    /// Esta función se llama ya dentro del hueco SIN IMAGEN, así que un panel que está pintando
    /// no las ve nunca. Lo que decide aquí es el otro caso: un hueco NORMAL, de los que el
    /// panel tiene a diario —el que queda cuando el panel suelta la imagen al cerrarse, después
    /// de haber pintado cuarenta fotogramas sin un solo problema—. Ahí los números no
    /// diagnostican nada: son ruido de desarrollador sobre un panel que funcionó.
    ///
    /// Se muestran, entonces, solo cuando el panel NO ha conseguido pintar:
    ///   - `fotogramas == 0`: no llegó ni uno. Es el misterio, y es lo que el usuario reportó.
    ///   - `descartados > 0`: llegaron y se tiraron.
    ///   - `hayJpeg`: llegó uno, está guardado, y aun así no hay imagen (no decodificó).
    static func muestraLaCuenta(fotogramas: Int, descartados: Int, hayJpeg: Bool) -> Bool {
        hayJpeg || descartados > 0 || fotogramas == 0
    }

    static func cuenta(mensajes: Int, fotogramas: Int, descartados: Int) -> String {
        var t = "mensajes \(mensajes) · fotogramas \(fotogramas)"
        if descartados > 0 { t += " · descartados \(descartados)" }
        return t
    }

    /// Solo se gira la ruedecita cuando de verdad se espera algo. Girar sobre un panel cerrado o
    /// congelado prometería una imagen que no va a llegar.
    static func esperandoLaPrimera(closedReason: String?, isLive: Bool) -> Bool {
        closedReason == nil && isLive
    }

    /// Id del `.task` que decodifica. Es opcional A PROPÓSITO: debe pasar a `nil` cuando el estado
    /// suelta el JPEG (panel plegado), o el efecto no se reejecuta y la imagen decodificada
    /// sobrevive en la vista (secreto en reposo, §6.2(g)). No simplificar a `lastFrameAt` a secas.
    static func frameID(jpeg: Data?, lastFrameAt: Date?) -> Date? {
        jpeg == nil ? nil : lastFrameAt
    }

    /// Decodifica el JPEG en una tarea de fondo. `nil` si los bytes no son una imagen.
    @concurrent static func decodeOffMain(_ jpeg: Data) async -> CGImage? {
        // `@concurrent` obliga a correr en el ejecutor global. Un `nonisolated async` a secas NO basta
        // aquí: con la ejecución no aislada heredada del llamador (valor por omisión del proyecto)
        // correría en el hilo principal; el `assert` de abajo lo detecta si alguien lo quita.
        // Llamada desde el `.task(id:)`, hereda su cancelación.
        assert(!Thread.isMainThread, "la decodificación del JPEG no puede ocurrir en el hilo principal")
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        // `ShouldCacheImmediately` fuerza la decodificación aquí, no al pintar en el hilo principal.
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
