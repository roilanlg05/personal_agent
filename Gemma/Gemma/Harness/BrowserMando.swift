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
    ///      mensajes por ventana de 1 s por visor y lo que lo pasa se descarta **en silencio**.
    ///      Un arrastre muestreado a este ritmo cabe en **31 mensajes** en cualquier ventana de
    ///      un segundo (una muestra cada ≥33 ms), y un mecanógrafo rápido añade ~20 (10
    ///      pulsaciones/s × `keyDown` + `keyUp`). Las dos cosas **a la vez**, que es el peor caso
    ///      humano: **51 de 120, cero descartes, 57 % del presupuesto libre.**
    ///
    ///      ⚠️ **AQUÍ HABÍA UN MOTIVO FALSO, Y SE CORRIGE CON LA CITA.** Lo que esta cota decía
    ///      antes —y lo decía el encargo de la tarea— era que «una inundación hambrea los acuses
    ///      de los fotogramas y congela el panel de todos los visores». **Es imposible por
    ///      construcción:** el relé **exime el acuse del tope de caudal**
    ///      (`browser/relay.py:959`, `if clase != "ack" and not viewer.caudal.admite(...)`) y su
    ///      propio comentario dice que la exención está ahí por esa razón exacta. El dato
    ///      correcto ya estaba escrito en el fichero de al lado, de la tarea anterior
    ///      (`BrowserRelayClient.swift`, `caducidadDeLaPeticion`: «`relay.py:959` aplica el
    ///      caudal a todo lo que no es `ack`»). Dos ficheros del mismo subsistema se
    ///      contradecían; el otro tenía razón.
    ///
    ///      **El mecanismo que SÍ existe** es otro y es peor de localizar: el acuse sale por **el
    ///      mismo WebSocket** que la entrada, y los mensajes de un WebSocket van ordenados. Una
    ///      ráfaga se le pone **delante**: 400 mensajes son ~34 kB, que por datos móviles malos
    ///      —el enlace que `caducidadDeLaPeticion` dice explícitamente que hay que aguantar— son
    ///      del orden de **2,7 s de demonio parado para todos los visores**. Es **bloqueo de
    ///      cabeza de línea**, no agotamiento de presupuesto. Y el camino por el que de verdad
    ///      se alcanza no es el arrastre, que ya está muestreado: es el **teclado**, que manda
    ///      dos mensajes por tecla. Lo cierra `intervaloEntreTeclas`, aquí abajo.
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

    /// El intervalo mínimo entre dos mensajes de teclado.
    ///
    /// POR QUÉ EXISTE, CON EL UMBRAL MEDIDO. `mensajesDeTeclado` produce **dos mensajes por
    /// grafema** (`keyDown` + `keyUp`), y cuatro cuando hay que borrar lo que había. Sin reparto,
    /// los 2N mensajes de un pegado caen en la misma ventana de un segundo y **el relé descarta
    /// el resto en silencio** (`CaudalDeEntrada`, cola deslizante de 120 en 1 s). Los umbrales se
    /// midieron reimplementando el algoritmo exacto del relé:
    ///
    ///     pegado solo ....................................... 60 caracteres (61 → llegan 60)
    ///     pegado con un arrastre en el mismo segundo ........ 45
    ///     AutoFill SOBRE UN CAMPO YA ESCRITO ................ 30   ← el caso real
    ///
    /// El tercero es el que importa: una contraseña se pega desde un gestor, y si el campo ya
    /// tenía algo, borrarlo cuesta 4 mensajes por carácter (2 de `Backspace` + 2 del nuevo). El
    /// usuario pega su contraseña, llegan 30 caracteres, y el acceso falla **sin un solo error**;
    /// la página le contesta «contraseña incorrecta» y no hay forma de que lo deduzca.
    ///
    /// POR QUÉ 17 ms, Y NO 8 NI 50. El reparto le da al teclado **la mitad** del presupuesto del
    /// relé, que es la misma regla que gobierna `muestrasPorSegundo`: 120/2 = 60 mensajes/s, o
    /// sea 1000/60 = 16,67 ms, redondeado **hacia arriba** a 17 ms (58,8 mensajes/s) porque la
    /// ventana del relé es deslizante y redondear hacia abajo dejaría el ritmo justo en el filo.
    /// Con esto no hay umbral: un pegado de 200 caracteres llega **entero**.
    ///
    /// Lo que cuesta, dicho con el número: una contraseña de 20 caracteres son 40 mensajes, 39
    /// esperas, **0,66 s** en lugar de ~4 ms. El usuario la ve entrar por el propio stream. Al
    /// lado de fallar el acceso sin explicación, es un cambio que gana.
    ///
    /// Y la otra mitad de lo que arregla: el bloqueo de cabeza de línea del acuse (ver la cota 1
    /// de `muestrasPorSegundo`). Repartido, la ráfaga ya no se le pone delante.
    public static let intervaloEntreTeclas: Duration = .milliseconds(17)

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

    /// Dónde dibujar el anillo del puntero **del usuario**, en coordenadas de la vista. `nil`
    /// significa «no dibujes nada».
    ///
    /// POR QUÉ ESTA SEÑAL EXISTE Y NO ES UN ADORNO. La página remota **no dibuja cursor** y por
    /// el cable no viaja ninguno: lo único que llega es el JPEG del stream. Sin el anillo, un
    /// toque que cayó dos píxeles al lado del campo de la contraseña es indistinguible de un
    /// toque que no se mandó, y el usuario no tiene forma de saber cuál de los dos pasó. El
    /// anillo es, literalmente, la única realimentación de dónde cayó su dedo.
    ///
    /// LO QUE EL ANILLO DICE, Y LO QUE NO. Dice «de este punto salió un mensaje de entrada».
    /// **No** dice «la página lo recibió», y no se puede decir: `BrowserMandoEnvio.encola`
    /// descarta el booleano del envío, y ese booleano significa «el mensaje salió del aparato»,
    /// no «la página lo aplicó». Un acuse de recepción por punto sería un dato nuevo en el
    /// cable.
    ///
    /// LAS DOS PUERTAS SON `&&`, Y LAS DOS SON OBLIGATORIAS:
    ///
    ///   - **`capturar`**: con el volante del agente no se dibuja nada, ni siquiera el anillo
    ///     que el usuario dejó en su turno anterior. El agente **no pulsa por coordenada**
    ///     (`BrowserClickTool` corre `["click", selector]` con una referencia `@eN` o un
    ///     selector CSS) y la narración que llega por el relé es `case narration(String)` y nada
    ///     más, así que no hay ningún punto del agente que dibujar. Dejar el del usuario puesto
    ///     sería un cursor que nadie mueve y que él leería como la posición del agente: un
    ///     puntero inventado miente más que la ausencia de puntero.
    ///   - **`sePuedeApuntar`**: el fotograma siguiente puede llegar sin `metadata` y entonces no
    ///     se puede mandar nada a ninguna parte. Dejar el anillo puesto pondría una marca justo
    ///     al lado del aviso que dice que este fotograma no se puede situar.
    ///
    /// Pura, sin efectos y **sin registro**, como todo este fichero: la coordenada del usuario es
    /// su contraseña cuando el teclado es el de la pantalla.
    public static func puntero(ultimoPunto: CGPoint?,
                               capturar: Bool,
                               sePuedeApuntar: Bool) -> CGPoint? {
        guard capturar, sePuedeApuntar else { return nil }
        return ultimoPunto
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
            return ([soltado(en: donde)], nil)
        }
    }

    /// El `mouseReleased` que cierra un gesto en el punto de la página `donde`.
    ///
    /// Es UNA función y la usan los dos caminos que levantan el botón —el `.suelta` de un gesto
    /// que termina por su pie y el cierre defensivo de `BrowserMandoSesion.retira()` cuando el
    /// panel se retira a mitad de gesto— para que los dos manden **exactamente** el mismo
    /// mensaje. Dos copias del literal se podrían separar, y un soltar que la página no reconoce
    /// como el par de su `mousePressed` deja el botón tan hundido como no mandarlo.
    public static func soltado(en donde: CGPoint) -> String {
        BrowserInputEvents.mouse(tipo: .soltado, x: Int(donde.x), y: Int(donde.y),
                                 boton: .izquierdo, pulsaciones: 1)
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

    // MARK: el botón

    /// Lo que un toque del botón del volante tiene que hacer, o `nil` si no hay nada que hacer.
    ///
    /// `nil` con otro visor al volante **no es pereza**: `Mando.toma` devuelve `False` cuando ya
    /// lo tiene otro y el manejador del visor descarta ese booleano (`relay.py:965`), así que
    /// pedirlo no produce ni concesión ni error. Y devuelve `False` **también si el que pide ya
    /// lo tiene**, por lo que un segundo toque nunca re-confirma nada.
    public enum AccionDelBoton: Equatable { case toma, devuelve }

    /// Qué hace el botón para cada valor de `quienConduce`. Pura, para que el cableado del
    /// cuerpo de la vista no sea el único sitio donde esta decisión se toma.
    public static func accionDelBoton(quienConduce: QuienConduce) -> AccionDelBoton? {
        switch quienConduce {
        case .agente: return .toma
        case .yo: return .devuelve
        case .otroVisor: return nil
        }
    }
}

/// El camino de salida de la entrada del usuario: la cola de envíos, repartida en el tiempo y
/// cancelable.
///
/// POR QUÉ ESTÁ FUERA DEL CUERPO DE LA VISTA, y es la razón de que exista este tipo. El cuerpo de
/// un `View` no es observable desde XCTest, así que mientras el bucle de envío vivía dentro de
/// `BrowserMandoBarra` **nada medía el camino que lleva la contraseña**: ni que pulsar el botón
/// pidiera el volante, ni que teclear llegara al socket, ni que el reparto en el tiempo
/// existiera, ni que la cola se cancelara. Un revisor lo midió: los tres contadores del doble de
/// pruebas no los leía **nadie**. Sacado aquí, con el reloj inyectable, las cuatro cosas se miden
/// con un doble y sin abrir un socket; lo que queda en el cuerpo de la vista es la llamada.
@MainActor
public enum BrowserMandoEnvio {

    /// Cómo se espera entre dos mensajes. Inyectable por la misma razón que el reloj de
    /// `BrowserRelayClient`: para que la prueba del reparto no tarde lo que tarda el reparto, y
    /// —más importante— para que pueda **observar** cuánto se esperó, que es la propiedad que se
    /// quiere medir y no un efecto colateral del tiempo real.
    public typealias Espera = @Sendable (Duration) async -> Void

    public static let esperaReal: Espera = { try? await Task.sleep(for: $0) }

    /// Encadena el envío de `mensajes` detrás de `previa` y devuelve la cola nueva.
    ///
    /// **EL ORDEN ES OBLIGATORIO, NO UNA CORTESÍA.** Un `mouseReleased` que adelantara a su
    /// `mousePressed` dejaría el botón del ratón **hundido** en la página remota, y a partir de
    /// ahí todo lo que el usuario tocara arrastraría. Por eso cada envío espera a `previa`.
    ///
    /// **EL REPARTO EN EL TIEMPO** es lo que impide que un pegado se coma su propia cola: ver
    /// `BrowserMandoEntrada.intervaloEntreTeclas`, con los tres umbrales medidos. No se espera
    /// antes del primer mensaje: un clic no se retrasa.
    ///
    /// **LA CANCELACIÓN** se comprueba después de cada espera, no solo al entrar, y es lo que
    /// hace que la contraseña en vuelo no siga saliendo cuando el volante ya no es del usuario.
    /// Sin reparto la ventana era de milisegundos; con reparto es de segundos, así que sin este
    /// guarda el arreglo de arriba habría abierto un agujero nuevo.
    ///
    /// Con `mando` a `nil` o sin mensajes **no se crea cola nueva**: se devuelve la que había,
    /// para no romper la cadena de orden de lo que ya estuviera en vuelo.
    ///
    /// **UN ENVÍO QUE FALLA SE DICE, Y CORTA EL RESTO DEL LOTE.** El `Bool` de `manda(entrada:)`
    /// significa «el mensaje salió del aparato», y un `false` es información que el aparato ya
    /// tiene en la mano: no hay canal (el socket se cayó y `enviaPorElCanal` lo soltó) o el
    /// mensaje pasa del tope del relé. Antes se tiraba, y el `.closed` que baja el rótulo llega
    /// **después**, por otra tarea (el bucle de recepción): en esa ventana el panel seguía
    /// diciendo «Conduces tú» y el usuario tecleaba su contraseña entera hacia ninguna parte,
    /// sin un solo error. `alFallar` es lo que lo hace visible (ver
    /// `BrowserPanelView.avisoDeApuntado`). El resto del lote no se intenta: sin canal fallaría
    /// igual, y con el tope pasado lo que saliera sería una contraseña con un hueco en medio,
    /// que es peor que ninguna porque la página contesta «contraseña incorrecta».
    ///
    /// `alFallar` **no recibe nada**, a propósito: ni el mensaje, ni su índice, ni cuántos
    /// quedaban. Cualquiera de los tres diría algo de lo que el usuario escribió.
    public static func encola(_ mensajes: [String],
                              por mando: MandoDelNavegador?,
                              tras previa: Task<Void, Never>?,
                              espera: @escaping Espera = esperaReal,
                              alFallar: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard let mando, !mensajes.isEmpty else { return previa }
        return Task {
            await previa?.value
            for (indice, mensaje) in mensajes.enumerated() {
                if indice > 0 { await espera(BrowserMandoEntrada.intervaloEntreTeclas) }
                guard !Task.isCancelled else { return }
                guard await mando.manda(entrada: mensaje) else {
                    alFallar()
                    return
                }
            }
        }
    }

    /// Ejecuta la acción del botón. Devuelve si el mensaje **salió del aparato**, que es lo único
    /// que el cliente puede saber: el servidor no contesta a una toma, ni para bien ni para mal.
    ///
    /// Un `false` es información que el aparato **ya tiene en la mano** —no hay conexión, o el
    /// mensaje pasa del tope del relé— y por eso el llamante la usa para bajar el «pidiendo…» en
    /// el momento, en vez de dejar al usuario mirando un botón inerte los seis segundos enteros
    /// de `caducidadDeLaPeticion`.
    @discardableResult
    public static func ejecuta(_ accion: BrowserMandoEntrada.AccionDelBoton,
                               por mando: MandoDelNavegador) async -> Bool {
        switch accion {
        case .toma: return await mando.tomaElMando()
        case .devuelve: return await mando.devuelveElMando()
        }
    }
}

/// Lo que un panel lleva EN CURSO con el volante: el gesto abierto sobre la imagen, su cola de
/// envíos, y si algo de lo que el usuario mandó **no salió**. Uno por panel, y lo tiene el
/// coordinador al lado del mando de ese panel.
///
/// POR QUÉ EXISTE, Y POR QUÉ NO VIVE EN EL CUERPO DE LA VISTA, que es donde vivía. Dos motivos,
/// y el primero es el defecto que el usuario sufría:
///
///   1. **EL BOTÓN HUNDIDO.** Retirar el panel a mitad de un gesto —el usuario manda otro
///      mensaje, pulsa detener, o salta el tope de inactividad— congela el panel y **cierra el
///      socket en el mismo paso** (`BrowserPanelCoordinator.retire`). Con el gesto dentro de la
///      vista, nadie fuera de ella sabía que había un `mousePressed` sin su `mouseReleased`, y
///      el `.onEnded` del `DragGesture` no está garantizado: `allowsHitTesting(false)` deja al
///      reconocedor sin entrada y `DragGesture` no tiene `onCancelled`. Resultado: el Chrome del
///      i3, con la sesión de Google del usuario dentro, se quedaba con el botón izquierdo
///      **pulsado**, y desde ahí todo lo que tocaran él o el agente **arrastraba**. Con el gesto
///      aquí, el coordinador puede cerrarlo (`retira()`) **antes** de cerrar el socket.
///   2. **LO QUE NO SALIÓ.** El aviso de «tu entrada no llegó» tiene que verse en la barra
///      aunque el fallo venga del gesto, y las dos vistas son hermanas: la única forma de que
///      compartan ese hecho es que viva en algo que las dos reciben.
///
/// Y de propina, el cuerpo de la vista deja de ser el único sitio donde vive la lógica del
/// gesto, así que se puede **ejecutar** en una prueba en vez de afirmar la forma de su texto.
///
/// AQUÍ TAMPOCO SE REGISTRA NADA, igual que en todo este fichero (la lista blanca de
/// `BrowserPanelViewTests` lo vigila): `ultimaPagina` es la coordenada del dedo del usuario, y
/// sobre un teclado en pantalla eso es su contraseña. Guarda **un** punto, no un trazo.
@Observable @MainActor
public final class BrowserMandoSesion {
    /// El volante de este panel. `nil` tras `retira()`: el panel retirado ya no manda nada, y
    /// soltar la referencia es lo que deja que el cliente del relé —y su socket— se liberen.
    private var mando: MandoDelNavegador?
    /// El último punto de la página que se pudo mapear en el gesto en curso. **`nil` significa
    /// «no hay gesto abierto que cerrar»**, igual que en `BrowserMandoEntrada.mensajesDePuntero`.
    private var ultimaPagina: CGPoint?
    /// Cuándo se mandó la última muestra del gesto. `nil` entre gestos, y eso es lo que
    /// distingue la pulsación del movimiento.
    private var ultimoMuestreo: ContinuousClock.Instant?
    /// La cadena de envíos del gesto, en orden: ver `BrowserMandoEnvio.encola`.
    private var cola: Task<Void, Never>?

    /// Si algo de lo que el usuario mandó desde este panel **no salió del aparato**. Lo lee la
    /// barra para avisarle. Se apaga cuando el servidor le vuelve a conceder el volante.
    public private(set) var entradaPerdida = false

    public init(mando: MandoDelNavegador) {
        self.mando = mando
    }

    /// El dedo toca o se mueve sobre la imagen. Devuelve si **de este punto salió un mensaje**,
    /// que es exactamente lo que el anillo del puntero puede marcar (ver
    /// `BrowserMandoEntrada.puntero`).
    ///
    /// LO QUE DEVUELVE ES `mensajes`, NO `pagina`, y no se puede cambiar sin mentir. Un `.mueve`
    /// cuyo punto no se puede mapear conserva la página VIEJA con CERO mensajes (para que el
    /// soltar tenga dónde levantar el botón), y una muestra que el muestreo descarta tampoco se
    /// manda: en los dos casos el anillo no se mueve.
    public func toca(punto: CGPoint,
                     vista: CGSize,
                     tamañoDeLaImagen: CGSize,
                     dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?,
                     ahora: ContinuousClock.Instant = .now) -> Bool {
        // `onChanged` se dispara también con el primer contacto, así que la pulsación es el
        // evento que llega sin muestreo previo.
        let fase: BrowserMandoEntrada.Fase = ultimoMuestreo == nil ? .pulsa : .mueve
        return !manda(fase: fase, punto: punto, vista: vista, tamañoDeLaImagen: tamañoDeLaImagen,
                      dimensionesDelCable: dimensionesDelCable, ahora: ahora).isEmpty
    }

    /// El dedo se levanta: se manda el soltar (cayendo al último punto bueno si hace falta) y el
    /// gesto queda cerrado. No devuelve nada a propósito: el soltar puede salir en el punto
    /// VIEJO, así que su `punto` no es lo que viajó y el anillo no se puede mover con él.
    public func levanta(punto: CGPoint,
                        vista: CGSize,
                        tamañoDeLaImagen: CGSize,
                        dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?) {
        _ = manda(fase: .suelta, punto: punto, vista: vista, tamañoDeLaImagen: tamañoDeLaImagen,
                  dimensionesDelCable: dimensionesDelCable, ahora: .now)
        ultimoMuestreo = nil
        ultimaPagina = nil
    }

    /// **EL PANEL SE RETIRA: SE CIERRA EL GESTO ABIERTO ANTES DE QUE SE CIERRE EL SOCKET.**
    ///
    /// Si había un `mousePressed` sin su `mouseReleased`, se encola el soltar en el último punto
    /// bueno —la misma excepción deliberada a la dirección segura que hace el `.suelta`, y por
    /// el mismo motivo: no mandarlo deja el botón hundido—. Va **detrás** de lo que ya esté en
    /// la cola: un soltar que adelantara a su pulsar dejaría el botón hundido igual. Si no había
    /// gesto abierto, no se manda nada.
    ///
    /// Devuelve la cola entera, hasta su último mensaje, para que el coordinador **espere a que
    /// salga** antes de cerrar el socket: el relé solo acepta entrada del portador del volante,
    /// y el portador ES el socket, así que lo que salga después de cerrarlo no llega. `nil` si
    /// no hay nada en vuelo.
    ///
    /// LA COLA NO SE CANCELA, y es a propósito. Cada eslabón de la cola de un gesto es UN
    /// mensaje sin espera, así que se vacía en milisegundos y no hay ninguna ráfaga que cortar;
    /// y lo que se cortaría podría ser justo el `mousePressed` todavía sin salir —con el soltar
    /// detrás, un `mouseReleased` huérfano— o el propio soltar de un gesto recién terminado.
    /// El que corta la cola es el coordinador, cerrando el socket, y lo hace tras el último.
    ///
    /// Y la sesión queda **cerrada**: sin mando, sin gesto y sin cola. Un `.onEnded` tardío no
    /// manda nada, y el cliente del relé deja de estar referenciado desde aquí.
    public func retira() -> Task<Void, Never>? {
        if let donde = ultimaPagina {
            cola = BrowserMandoEnvio.encola([BrowserMandoEntrada.soltado(en: donde)], por: mando, tras: cola,
                                            alFallar: { [weak self] in self?.notaQueNoSalio() })
        }
        let enVuelo = cola
        mando = nil
        cola = nil
        ultimaPagina = nil
        ultimoMuestreo = nil
        return enVuelo
    }

    /// **EL VOLANTE SE PERDIÓ POR OTRO CAMINO** (el servidor se lo dio a otro, o se cortó la
    /// conexión): el gesto se da por cerrado aquí, **sin mandar nada**.
    ///
    /// POR QUÉ NO SE MANDA EL SOLTAR AQUÍ, MEDIDO EN EL RELÉ Y NO SUPUESTO. Por estos caminos el
    /// volante ya no es del usuario cuando la vista se entera: con un `.closed` el canal ya es
    /// `nil` (`enviaPorElCanal` no manda nada), y con un `mando` del servidor el relé descarta
    /// la entrada de quien no es el portador (`_reenvia_entrada` compara el portador por su
    /// socket). Un soltar aquí no llegaría a la página por ningún camino. Lo que la página
    /// necesita en esos casos lo tiene que hacer el relé, que es el único que sigue hablando con
    /// el demonio — ver el hueco declarado en el informe de la ronda 6.
    ///
    /// LO QUE SÍ HACE, y es un defecto propio: sin esto `ultimoMuestreo` se quedaba puesto, así
    /// que cuando el usuario recuperaba el volante su primer toque se clasificaba como `.mueve`
    /// (un `mouseMoved`, sin `mousePressed`) y **ningún clic suyo funcionaba** hasta que un
    /// `.onEnded` lo limpiara.
    ///
    /// La cola no se cancela, por el mismo motivo que en `retira()`.
    public func olvidaElGesto() {
        ultimaPagina = nil
        ultimoMuestreo = nil
    }

    /// Un envío no salió del aparato. Ver `BrowserMandoEnvio.encola`.
    public func notaQueNoSalio() {
        entradaPerdida = true
    }

    /// El servidor le ha vuelto a conceder el volante: lo de antes ya está dicho.
    public func olvidaElFallo() {
        entradaPerdida = false
    }

    /// Mapea, muestrea y manda. El mapa se consulta **siempre**, también cuando el muestreo va a
    /// descartar la muestra: es aritmética barata, y así el último punto bueno nunca se queda
    /// atrás (lo caro, y lo que el tope del relé cuenta, es el mensaje). Devuelve lo que se
    /// encoló, que es vacío cuando el muestreo descarta la muestra.
    private func manda(fase: BrowserMandoEntrada.Fase,
                       punto: CGPoint,
                       vista: CGSize,
                       tamañoDeLaImagen: CGSize,
                       dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?,
                       ahora: ContinuousClock.Instant) -> [String] {
        let salida = BrowserMandoEntrada.mensajesDePuntero(fase: fase,
                                                           punto: punto,
                                                           ultimaPagina: ultimaPagina,
                                                           tamañoDeLaVista: vista,
                                                           tamañoDeLaImagen: tamañoDeLaImagen,
                                                           dimensionesDelCable: dimensionesDelCable)
        ultimaPagina = salida.pagina
        // La pulsación y el soltar no se muestrean nunca: son los dos extremos del clic.
        if fase == .mueve, !BrowserMandoEntrada.tocaMuestrear(ultimo: ultimoMuestreo, ahora: ahora) {
            return []
        }
        ultimoMuestreo = ahora
        cola = BrowserMandoEnvio.encola(salida.mensajes, por: mando, tras: cola,
                                        alFallar: { [weak self] in self?.notaQueNoSalio() })
        return salida.mensajes
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
    /// El gesto en curso, su cola y su mando. Vive en el coordinador y no aquí: es lo que deja
    /// que retirar el panel cierre el gesto **antes** de cerrar el socket (ver
    /// `BrowserMandoSesion`). `nil` sin relé configurado o con el panel ya retirado.
    let sesion: BrowserMandoSesion?

    /// El último punto **de la vista** del que salió un mensaje de entrada, que es lo que el
    /// anillo marca.
    ///
    /// **NO SE LIMPIA EN `.onEnded`, Y ESO ES EL PUNTO.** Ahí está su único valor: la página
    /// remota no dibuja cursor, así que tras levantar el dedo el anillo es la única señal de
    /// dónde cayó el toque. Se borra en las dos transiciones que lo vuelven mentira —perder el
    /// volante y cambiar el tamaño de la vista— y en ningún otro sitio.
    @State private var ultimoPunteroDeLaVista: CGPoint?

    var body: some View {
        GeometryReader { geometria in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { valor in
                            // EL ANILLO SE MUEVE SOLO SI DE ESTE PUNTO SALIÓ UN MENSAJE: ver
                            // `BrowserMandoSesion.toca`, que decide por `mensajes` y después de
                            // la puerta del muestreo.
                            if sesion?.toca(punto: valor.location, vista: geometria.size,
                                            tamañoDeLaImagen: tamañoDeLaImagen,
                                            dimensionesDelCable: dimensionesDelCable) == true {
                                ultimoPunteroDeLaVista = valor.location
                            }
                        }
                        .onEnded { valor in
                            sesion?.levanta(punto: valor.location, vista: geometria.size,
                                            tamañoDeLaImagen: tamañoDeLaImagen,
                                            dimensionesDelCable: dimensionesDelCable)
                        }
                )
                // EL ANILLO VA DENTRO DE ESTE `GeometryReader`, no fuera: el punto está guardado
                // en el espacio local del `DragGesture` (que es `.local` por omisión) y es el
                // mismo que el del `overlay` sobre este `Color.clear`. Fuera serían coordenadas
                // de otro espacio y el anillo caería desplazado. `.position(_:)` coloca el
                // CENTRO en el punto, así que no hay radio que restar.
                .overlay {
                    if let donde = BrowserMandoEntrada.puntero(
                            ultimoPunto: ultimoPunteroDeLaVista,
                            capturar: capturar,
                            sePuedeApuntar: BrowserMandoEntrada.sePuedeApuntar(
                                tamañoDeLaVista: geometria.size,
                                tamañoDeLaImagen: tamañoDeLaImagen,
                                dimensionesDelCable: dimensionesDelCable)) {
                        Circle()
                            .strokeBorder(Color.orange, lineWidth: 2)
                            .frame(width: 24, height: 24)
                            .position(donde)
                            .allowsHitTesting(false)
                    }
                }
                // Se pierde el volante, se va el anillo (ver `BrowserMandoEntrada.puntero`) Y SE
                // CIERRA EL GESTO. El `.onEnded` no está garantizado: con `allowsHitTesting` a
                // `false` el reconocedor se queda sin entrada, y sin esto el primer toque tras
                // recuperar el volante sería un `.mueve` y no un clic. Ver
                // `BrowserMandoSesion.olvidaElGesto`.
                .onChange(of: capturar) {
                    ultimoPunteroDeLaVista = nil
                    sesion?.olvidaElGesto()
                }
                // El punto está en coordenadas de la vista y sin su tamaño de referencia, así que
                // al redimensionar ya no señala el mismo sitio de la imagen. Borrarlo es la salida
                // honesta; remapearlo exigiría un mapa inverso, que no existe hoy.
                .onChange(of: geometria.size) { ultimoPunteroDeLaVista = nil }
        }
        .allowsHitTesting(capturar)
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
    /// Lo que este panel lleva en curso con el volante. La barra lee de aquí si algo de lo que
    /// el usuario mandó **no salió** —también desde el gesto, que es su vista hermana— y
    /// apunta aquí sus propios fallos.
    let sesion: BrowserMandoSesion?

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
                                                            sePuedeApuntar: sePuedeApuntar,
                                                            entradaPerdida: sesion?.entradaPerdida == true) {
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
            // LA CONTRASEÑA EN VUELO SE CORTA AQUÍ. La cola captura las pulsaciones **ya
            // codificadas**, y con el reparto en el tiempo de `intervaloEntreTeclas` la ventana
            // en que siguen saliendo pasa de milisegundos a segundos. Hoy el relé las tiraría
            // por portador, pero hay un camino estrecho en el que el volante vuelve a ser suyo
            // antes de que la cola acabe y la cola vieja escribe en la página con un retraso que
            // nadie espera.
            cola?.cancel()
            // Se borra lo escrito y se suelta el foco. El borrado NO manda `Backspace` a la
            // página: el guarda de abajo mira quién conduce, y aquí ya no es el usuario. Si los
            // mandara, el número de pulsaciones delataría la longitud de la contraseña.
            tecleado = ""
            enfocado = false
            // Un volante NUEVO deja atrás el aviso de lo que no salió: el usuario ya lo leyó, y
            // lo que teclee a partir de aquí sale por un canal que el servidor acaba de confirmar.
            // Mientras el volante no vuelva a ser suyo el aviso se queda, y es a propósito: el
            // `.closed` que baja el rótulo llega justo después del fallo, y si el aviso se fuera
            // con él no lo leería nadie.
            if state.quienConduce == .yo { sesion?.olvidaElFallo() }
        }
        .onChange(of: tecleado) { anterior, nuevo in
            guard BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce) else { return }
            cola = BrowserMandoEnvio.encola(BrowserMandoEntrada.mensajesDeTeclado(anterior: anterior, nuevo: nuevo),
                                            por: mando, tras: cola,
                                            alFallar: { sesion?.notaQueNoSalio() })
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
        guard let mando, let accion = BrowserMandoEntrada.accionDelBoton(quienConduce: state.quienConduce)
        else { return }
        // Solo la toma se queda «pidiendo». Devolverlo no: el servidor publica el `mando` con
        // `"agente"` y ése es el que mueve el rótulo.
        if accion == .toma { pidiendoDesde = ContinuousClock.Instant.now }
        Task {
            // EL BOOLEANO NO SE TIRA, y es información gratis. Significa «el mensaje salió del
            // aparato»; un `false` es que no hay conexión o que el mensaje pasa del tope del
            // relé, o sea algo que el aparato YA SABE. Tirarlo dejaba el botón en «pidiendo…» y
            // deshabilitado los seis segundos enteros de `caducidadDeLaPeticion`, informando de
            // una petición que el propio cliente sabía que no había ocurrido.
            if await BrowserMandoEnvio.ejecuta(accion, por: mando) == false {
                pidiendoDesde = nil
            }
        }
    }
}
