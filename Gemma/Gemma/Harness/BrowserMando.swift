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

    /// El intervalo mínimo entre dos muestras de un gesto continuo, y **el único valor que
    /// gobierna la cadencia**: es el que lee `tocaMuestrear`.
    ///
    /// SE DERIVA DE `muestrasPorSegundo` Y NO SE ESCRIBE APARTE, y el motivo es un defecto medido
    /// (H2 de la revisión de rama). Antes era un literal (`.milliseconds(33)`) al lado de una
    /// `muestrasPorSegundo = 30` que **nadie leía**: las tres cotas razonadas de ahí arriba y la
    /// prueba del presupuesto del relé vigilaban la constante muerta, y bajar este intervalo a
    /// 1 ms —1000 muestras por segundo, 8,3 veces el presupuesto entero del relé— dejaba la
    /// suite verde. Con la derivación hay un solo número, y la prueba
    /// (`test_el_muestreo_elegido_deja_sitio_al_teclado_en_el_presupuesto_del_rele`) mide
    /// **éste**. 1 s / 30 = 33,3 ms: el reloj del muestreo es un instante monótono con precisión
    /// de sobra, así que no hace falta redondear.
    public static let intervaloDeMuestreo: Duration = .seconds(1) / muestrasPorSegundo

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
    /// **No** dice «la página lo recibió», y no se puede decir: el booleano del envío (que
    /// `BrowserMandoEnvio.encola` ya no tira: un `false` sube el aviso de lo que no salió)
    /// significa «el mensaje salió del aparato», no «la página lo aplicó». Un acuse de recepción
    /// por punto sería un dato nuevo en el cable.
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
    /// `BrowserMandoEntrada.intervaloEntreTeclas`, con los tres umbrales medidos. El reparto es
    /// **entre los mensajes de un mismo lote** (solo con `indice > 0`), no entre lotes: no se
    /// espera antes del primer mensaje de un lote.
    ///
    /// ⚠️ PERO UN CLIC SÍ PUEDE RETRASARSE, y es un precio aceptado (ronda 8). Desde que el
    /// teclado y el puntero comparten UNA cadena por sesión (`BrowserMandoSesion`), un clic
    /// encolado detrás de un pegado largo sale cuando el pegado termina: 200 caracteres son
    /// 400 mensajes y unos 6,8 s. Es lo que se quiere: el orden de los mensajes es el orden de
    /// los gestos, y un clic que adelantara a las teclas pendientes movería el foco a otro campo
    /// y el resto de la contraseña se escribiría ahí, quizá a la vista del stream.
    ///
    /// **LA INVALIDACIÓN, `vigente`**, se comprueba tras esperar a la cola anterior, tras cada
    /// espera del reparto y antes de cada unidad: un mensaje, o un par down/up cuando
    /// `enPares` es true (solo teclado). Nunca se corta entre el down y su up. Evita que la contraseña en
    /// vuelo no siga saliendo cuando el volante ya no es del usuario. Es un cierre que pregunta a
    /// quien encoló, y no `Task.cancel()`, por lo que midió la revisión adversarial de la ronda 8:
    /// cada llamada crea una tarea propia que espera a la anterior, así que cancelar la última
    /// **no cancela las anteriores**, y un pegado viejo seguía saliendo y podía escribir en el
    /// campo enfocado tras recuperar el volante. Con `vigente` a `nil` el lote **no se invalida
    /// nunca**: es lo que usan el puntero y el soltar defensivo, que se drenan siempre (cortarlos
    /// pierde el `mouseMoved` y el soltar de un gesto terminado, y deja `pulsar` sin `soltar`:
    /// medido en dos rondas, h3f). Lo que ya entró en `await mando.manda(...)` no se puede
    /// retirar: un mensaje en ese punto sale o falla; se termina su par antes de cortar.
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
    /// LOS LOTES QUE VAN DETRÁS DE UNO FALLIDO NO SE TOCAN, y es una decisión: el primer `false`
    /// corta **su** lote, no la cadena. Sin canal, cada lote de detrás falla en su primer mensaje
    /// y vuelve a llamar a `alFallar` (que solo pone un booleano, así que repetirlo no dice
    /// nada nuevo ni cuenta nada); con el tope pasado, el lote de detrás es otro y puede caber.
    ///
    /// `alFallar` **no recibe nada**, a propósito: ni el mensaje, ni su índice, ni cuántos
    /// quedaban. Cualquiera de los tres diría algo de lo que el usuario escribió.
    public static func encola(_ mensajes: [String],
                              por mando: MandoDelNavegador?,
                              tras previa: Task<Void, Never>?,
                              vigente: (@MainActor () -> Bool)? = nil,
                              enPares: Bool = false,
                              espera: @escaping Espera = esperaReal,
                              alFallar: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard let mando, !mensajes.isEmpty else { return previa }
        return Task {
            await previa?.value
            for (indice, mensaje) in mensajes.enumerated() {
                if indice > 0 { await espera(BrowserMandoEntrada.intervaloEntreTeclas) }
                // En la primera vuelta esto es «tras esperar a la cola anterior»; en las demás,
                // «tras la espera del reparto», antes de empezar la siguiente unidad.
                // El teclado se construye en pares down/up. Una vez enviado el down,
                // su up se drena incluso si cambia la generación durante el await.
                if !enPares || indice % 2 == 0 {
                    guard !Task.isCancelled, vigente?() ?? true else { return }
                }
                guard await mando.manda(entrada: mensaje) else {
                    alFallar()
                    return
                }
            }
        }
    }

    /// Cuánto se espera, como mucho, a que salga lo que quedaba en vuelo de un gesto (el soltar
    /// defensivo incluido) antes de dar el volante por perdido: antes de cerrar el socket de un
    /// panel retirado (`BrowserPanelCoordinator.retire`) y antes de devolver el volante
    /// (`BrowserMandoBarra.pulsa`).
    ///
    /// 1 s ES UN JUICIO, NO UNA MEDICIÓN, con su razón. La cola de un gesto es un mensaje por
    /// eslabón y sin esperas (el reparto en el tiempo es del teclado), así que con el enlace
    /// sano se vacía en milisegundos; si un segundo no basta, el enlace está muerto en la
    /// práctica. Lo que SÍ está medido es que el tope existe (`BrowserMandoSesionTests`
    /// `.test_un_envio_colgado_no_retiene_el_socket_mas_que_el_plazo`): con un envío que no
    /// vuelve, el socket se cierra al cumplirse el plazo. Más largo retrasaría liberar el
    /// socket, y con él el volante: mientras el socket viva el relé sigue viendo al usuario
    /// como portador y **el agente recibe 409 en cada herramienta**.
    ///
    /// Lo que cuesta pasarse del plazo: el soltar que seguía colgado no llega, y el botón puede
    /// quedar hundido igual que con un corte de red (hueco declarado, del relé).
    nonisolated public static let plazoParaLoQueQuedaEnVuelo: Duration = .seconds(1)

    /// Espera a `tarea` **o** a que pase `plazo`, lo que llegue antes, y vuelve EN ESE MOMENTO.
    ///
    /// 🔴 LA VERSIÓN ANTERIOR NO TENÍA TOPE, y el motivo es una regla de Swift que no se ve: un
    /// `withTaskGroup` espera a **todos** sus hijos al salir, y `await tarea.value` no atiende
    /// a `cancelAll()` (cancela al hijo que espera, no a la tarea esperada). Medido por el
    /// revisor con una sonda aislada: plazo 1 s, envío de 5 s → volvía a los 5,04 s. El
    /// comentario prometía un tope que no existía, y con un envío colgado el socket del panel
    /// retirado se quedaba abierto: el relé seguía viendo al usuario como portador y el agente
    /// recibía 409 en cada herramienta.
    ///
    /// Ahora la espera y el reloj corren en dos tareas **independientes** que compiten por
    /// reanudar UNA continuación; la primera que llega la reanuda y la otra encuentra la
    /// continuación ya gastada y no hace nada. Nadie espera a la perdedora. La tarea esperada
    /// **no se cancela**: no detendría un envío colgado (el envío no atiende a la cancelación) y
    /// sí podría cortar un mensaje que todavía no ha salido, que es la avería de `retira()` con
    /// la cola cancelada. Lo que la para es cerrar el socket, que es lo que hace quien llama.
    public static func espera(_ tarea: Task<Void, Never>, comoMucho plazo: Duration) async {
        await withCheckedContinuation { (continuacion: CheckedContinuation<Void, Never>) in
            let unaSola = ReanudaUnaSolaVez(continuacion)
            Task { @MainActor in
                await tarea.value
                unaSola.reanuda()
            }
            Task { @MainActor in
                try? await Task.sleep(for: plazo)
                unaSola.reanuda()
            }
        }
    }

    /// Una continuación que se reanuda **una sola vez** aunque la reclamen dos. Todo en el hilo
    /// principal, así que el `Bool` no necesita candado.
    @MainActor
    private final class ReanudaUnaSolaVez {
        private var continuacion: CheckedContinuation<Void, Never>?
        init(_ continuacion: CheckedContinuation<Void, Never>) { self.continuacion = continuacion }
        func reanuda() {
            continuacion?.resume()
            continuacion = nil
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
    /// LA cadena de envíos de este panel, en orden: el gesto **y el teclado**, una sola. Ver
    /// `BrowserMandoEnvio.encola`.
    ///
    /// POR QUÉ UNA Y NO DOS (ronda 8, revisión adversarial de Codex). El teclado tenía su propia
    /// cola en `BrowserMandoBarra`, independiente de ésta: un pegado seguía saliendo durante
    /// segundos por el reparto de 17 ms, y un clic en otro campo **adelantaba** a sus teclas
    /// pendientes, así que el resto de la contraseña se escribía en el campo nuevo —que puede
    /// enseñar el texto, y de ahí al stream y al agente—. Con una sola cadena, el orden de los
    /// mensajes es el orden de los gestos, también entre clic y tecla.
    private var cola: Task<Void, Never>?

    /// La generación del TECLADO. Cada lote de teclado la captura al encolarse y deja de mandar
    /// en cuanto deja de coincidir (ver `vigente` en `BrowserMandoEnvio.encola`). Se incrementa,
    /// **de forma síncrona**, en las tres transiciones tras las que una tecla pendiente ya no
    /// debe salir: el volante cambia de manos (`cambioElVolante`), el usuario empieza a
    /// devolverlo (`devuelve`) y el panel se retira (`retira`). En las dos últimas, **antes** de
    /// encolar el soltar defensivo: si no, el soltar esperaría detrás de un pegado (200
    /// caracteres son 6,8 s de reparto) y el plazo de 1 s vencería sin que saliera.
    ///
    /// SOLO EL TECLADO. Los mensajes del puntero y el soltar defensivo no se invalidan nunca:
    /// se drenan (h3f, medido en dos rondas).
    private var generacionDeTeclado = 0

    /// El usuario pulsó «Devolverlo» y el servidor todavía no ha publicado el `mando` nuevo.
    /// Mientras está puesto **ni el puntero ni el teclado emiten nada** (el soltar defensivo sí:
    /// no pasa por aquí). Se pone en `devuelve()` antes de cualquier espera, y se quita cuando el
    /// volante cambia de manos, cuando devolverlo no salió o cuando caduca su plazo.
    /// La caducidad avisa y permite reintentar; no modifica la concesión del servidor.
    ///
    /// POR QUÉ HACE FALTA (ronda 8, Codex). Entre pulsar el botón y que llegue el `mando` del
    /// servidor, `capturar` sigue a `true`; el dedo que sigue apoyado dispara otro `onChanged`, y
    /// como `cierraElGesto()` acaba de borrar el muestreo, se leía como un `.pulsa`: un
    /// `mousePressed` nuevo que salía antes del `mando_devolver` y que nadie soltaría.
    public private(set) var devolviendo = false

    /// El contacto del gesto abierto, identificado por su `DragGesture.Value.startLocation`, que
    /// solo cambia con un contacto NUEVO. `nil` sin gesto abierto o cuando la vista no lo dice.
    private var contactoEnCurso: CGPoint?
    /// El último contacto cuyo gesto se cerró **sin que el dedo se levantara** (al devolver el
    /// volante o al perderlo). Sus `onChanged` y su `onEnded` se ignoran: el dedo sigue apoyado,
    /// y sin esto, al recuperar el volante, su siguiente `onChanged` sería un `mousePressed`
    /// que nadie garantiza soltar —el propio `onEnded` no está garantizado—.
    ///
    /// POR QUÉ NO BASTA LIMPIAR `devolviendo` CON LA CONCESIÓN NUEVA: la concesión no prueba que
    /// el siguiente evento sea de un contacto nuevo. Se olvida al ver un contacto distinto o al
    /// levantarse éste.
    ///
    /// HUECO DECLARADO: si el `onEnded` de ese contacto no llega nunca, el siguiente contacto que
    /// empiece EXACTAMENTE en el mismo punto (posible con un ratón quieto en macOS) se ignora
    /// hasta que se levante: un clic perdido, en la dirección segura.
    private var contactoCerrado: CGPoint?

    /// Si algo de lo que el usuario mandó desde este panel **no salió del aparato**. Lo lee la
    /// barra para avisarle. Se apaga cuando el servidor le vuelve a conceder el volante.
    public private(set) var entradaPerdida = false

    /// Cuántas PULSACIONES han salido del aparato hacia la página (no movimientos ni soltados).
    /// La barra lo observa para subir el teclado del teléfono: tocar un campo de la página solo
    /// manda un clic al navegador remoto, y sin esto el teclado solo subía si el usuario
    /// enfocaba a mano el campo local. Cuenta lo que SALIÓ (`!mensajes.isEmpty`), no lo que se
    /// tocó: un toque que el mapa rechaza no levanta el teclado.
    public private(set) var pulsacionesEnviadas = 0

    private let plazoDeDevolucion: Duration
    private let esperaDeDevolucion: BrowserMandoEnvio.Espera

    public init(mando: MandoDelNavegador,
                plazoDeDevolucion: Duration = .seconds(6),
                esperaDeDevolucion: @escaping BrowserMandoEnvio.Espera = BrowserMandoEnvio.esperaReal) {
        self.mando = mando
        self.plazoDeDevolucion = plazoDeDevolucion
        self.esperaDeDevolucion = esperaDeDevolucion
    }

    /// El dedo toca o se mueve sobre la imagen. Devuelve si **de este punto salió un mensaje**,
    /// que es exactamente lo que el anillo del puntero puede marcar (ver
    /// `BrowserMandoEntrada.puntero`).
    ///
    /// LO QUE DEVUELVE ES `mensajes`, NO `pagina`, y no se puede cambiar sin mentir. Un `.mueve`
    /// cuyo punto no se puede mapear conserva la página VIEJA con CERO mensajes (para que el
    /// soltar tenga dónde levantar el botón), y una muestra que el muestreo descarta tampoco se
    /// manda: en los dos casos el anillo no se mueve.
    ///
    /// `contacto` es el `startLocation` del `DragGesture`, que identifica al dedo: ver
    /// `contactoCerrado`. `nil` cuando quien llama no lo sabe (y entonces no se filtra por él).
    public func toca(punto: CGPoint,
                     vista: CGSize,
                     tamañoDeLaImagen: CGSize,
                     dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?,
                     contacto: CGPoint? = nil,
                     ahora: ContinuousClock.Instant = .now) -> Bool {
        guard admite(contacto) else { return false }
        contactoEnCurso = contacto
        // `onChanged` se dispara también con el primer contacto, así que la pulsación es el
        // evento que llega sin muestreo previo.
        let fase: BrowserMandoEntrada.Fase = ultimoMuestreo == nil ? .pulsa : .mueve
        let salio = !manda(fase: fase, punto: punto, vista: vista, tamañoDeLaImagen: tamañoDeLaImagen,
                           dimensionesDelCable: dimensionesDelCable, ahora: ahora).isEmpty
        if salio && fase == .pulsa { pulsacionesEnviadas += 1 }
        return salio
    }

    /// El dedo se levanta: se manda el soltar (cayendo al último punto bueno si hace falta) y el
    /// gesto queda cerrado. No devuelve nada a propósito: el soltar puede salir en el punto
    /// VIEJO, así que su `punto` no es lo que viajó y el anillo no se puede mover con él.
    public func levanta(punto: CGPoint,
                        vista: CGSize,
                        tamañoDeLaImagen: CGSize,
                        dimensionesDelCable: BrowserInputMapper.DimensionesDelCable?,
                        contacto: CGPoint? = nil) {
        let admitido = admite(contacto)
        // Este dedo se ha levantado: si era el contacto cerrado, ya no hay nada que ignorar.
        if contacto != nil, contacto == contactoCerrado { contactoCerrado = nil }
        contactoEnCurso = nil
        // Un contacto ignorado no manda su soltar: su gesto ya se cerró (con su soltar
        // defensivo) o no llegó a abrirse, y un `mouseReleased` sin `mousePressed` es basura.
        guard admitido else { return }
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
    ///
    /// LAS TECLAS PENDIENTES SÍ SE CORTAN, y antes de encolar el soltar: la generación del
    /// teclado sube aquí, así que un pegado en curso deja de mandar en su próxima comprobación
    /// y el soltar no espera detrás de él (ver `generacionDeTeclado`).
    public func retira() -> Task<Void, Never>? {
        generacionDeTeclado += 1
        let enVuelo = cierraElGesto()
        mando = nil
        cola = nil
        return enVuelo
    }

    /// **CIERRA EL GESTO ABIERTO SIN SOLTAR EL MANDO**: el soltar defensivo de `retira()`, para
    /// cuando el panel sigue vivo y el volante se va a perder por decisión del usuario
    /// (el botón «Devolverlo» pulsado con otro dedo todavía sobre la imagen: N2 de la
    /// re-revisión de la ronda 6). Devuelve la cola hasta su último mensaje para que quien
    /// llama espere —acotado, `BrowserMandoEnvio.espera`— a que salga **antes** de devolver el
    /// volante: tras el `mando` del servidor, el relé ya no aceptaría el soltar.
    public func cierraElGesto() -> Task<Void, Never>? {
        if let donde = ultimaPagina {
            cola = BrowserMandoEnvio.encola([BrowserMandoEntrada.soltado(en: donde)], por: mando, tras: cola,
                                            alFallar: { [weak self] in self?.notaQueNoSalio() })
        }
        ultimaPagina = nil
        ultimoMuestreo = nil
        cierraElContacto()
        return cola
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
        cierraElContacto()
    }

    /// **EL VOLANTE CAMBIÓ DE MANOS**, sea cual sea el camino: un `mando` del servidor, un
    /// `.closed`, o el fin del flujo. Lo llama el coordinador **en el mismo paso en que aplica el
    /// evento** (`BrowserPanelCoordinator`, el bucle del consumidor), que es el momento más
    /// temprano y síncrono en que este lado se entera; no un observador de la vista, que corre
    /// después y deja una ventana en la que una tecla pendiente aún saldría.
    ///
    /// Invalida el teclado pendiente, termina la devolución (si la había: ya está resuelta) y
    /// olvida el gesto sin mandar nada, como `olvidaElGesto`. Lo que sobrevive: los mensajes de
    /// puntero ya encolados, que se drenan (si el canal ya no es del usuario, el relé los tira).
    public func cambioElVolante() {
        generacionDeTeclado += 1
        devolviendo = false
        olvidaElGesto()
    }

    /// **LO QUE EL USUARIO TECLEA**, encolado en LA cadena de la sesión, detrás de lo que haya
    /// del gesto y delante de lo que venga después. Lleva la generación del teclado del momento
    /// en que se encola: si el volante cambia de manos, el usuario empieza a devolverlo o el
    /// panel se retira, las teclas que queden de este lote no salen.
    ///
    /// Mientras se devuelve el volante no se encola nada.
    public func teclea(_ mensajes: [String]) {
        guard !devolviendo else { return }
        let generacion = generacionDeTeclado
        cola = BrowserMandoEnvio.encola(mensajes, por: mando, tras: cola,
                                        vigente: { [weak self] in self?.generacionDeTeclado == generacion },
                                        enPares: true,
                                        alFallar: { [weak self] in self?.notaQueNoSalio() })
    }

    /// **EL USUARIO DEVUELVE EL VOLANTE.** Todo lo que no puede esperar ocurre aquí, de forma
    /// síncrona y antes de crear ninguna tarea: se marca `devolviendo` (ni puntero ni teclado
    /// emiten nada desde este instante), se invalidan las teclas pendientes y se cierra el gesto
    /// abierto con su soltar defensivo, que así sale el primero detrás del puntero ya encolado y
    /// no detrás de un pegado. Después, en la tarea, se espera acotado a que ese soltar salga
    /// —tras el `mando` del servidor el relé ya no lo aceptaría— y se manda `mando_devolver`.
    ///
    /// SI DEVOLVERLO NO SALE DEL APARATO, la sesión sigue en `.yo` (el servidor no se ha
    /// enterado), así que `devolviendo` se quita: si no, el usuario se quedaría conduciendo con
    /// toda su entrada rechazada. El contacto cerrado sigue ignorándose hasta que se levante.
    ///
    /// Devuelve la tarea con lo que contestó el envío, para quien quiera esperarla.
    @discardableResult
    public func devuelve() -> Task<Bool, Never> {
        devolviendo = true
        generacionDeTeclado += 1
        let generacion = generacionDeTeclado
        let espera = esperaDeDevolucion
        let plazo = plazoDeDevolucion
        // El plazo incluye el envío bloqueado, no solo la espera posterior al Bool.
        // No se cambia quienConduce: solo el servidor puede conceder el volante.
        // Al caducar se permite reintentar y se muestra el aviso existente; el contacto
        // cerrado sigue bloqueado y ningún lote invalidado vuelve a la vida.
        Task { @MainActor [weak self] in
            await espera(plazo)
            guard let self, self.devolviendo,
                  self.generacionDeTeclado == generacion else { return }
            self.devolviendo = false
            self.notaQueNoSalio()
        }
        let cierre = cierraElGesto()
        let mando = self.mando
        return Task { @MainActor [weak self] in
            if let cierre {
                await BrowserMandoEnvio.espera(cierre, comoMucho: BrowserMandoEnvio.plazoParaLoQueQuedaEnVuelo)
            }
            var salio = false
            if let mando { salio = await BrowserMandoEnvio.ejecuta(.devuelve, por: mando) }
            if !salio, self?.generacionDeTeclado == generacion {
                self?.devolviendo = false
            }
            return salio
        }
    }

    /// El gesto se cerró con el dedo todavía apoyado: ese contacto queda marcado para ignorarse.
    private func cierraElContacto() {
        if let contacto = contactoEnCurso { contactoCerrado = contacto }
        contactoEnCurso = nil
    }

    /// Si este evento del dedo puede emitir: no mientras se devuelve el volante, ni si es del
    /// contacto cerrado. Un contacto distinto prueba que el cerrado terminó (el `DragGesture`
    /// sigue un solo contacto a la vez). Un contacto que EMPIEZA mientras se devuelve queda él
    /// como el cerrado: es la misma situación, un dedo apoyado que el volante nuevo no debe
    /// convertir en clic.
    private func admite(_ contacto: CGPoint?) -> Bool {
        if devolviendo {
            if let contacto { contactoCerrado = contacto }
            return false
        }
        if let contacto {
            if contacto == contactoCerrado { return false }
            contactoCerrado = nil
        }
        return true
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
                            // `startLocation` identifica al dedo: solo cambia con un contacto
                            // nuevo. Es lo que deja a la sesión ignorar el dedo que siguió
                            // apoyado tras devolver o perder el volante (ver
                            // `BrowserMandoSesion.contactoCerrado`).
                            if sesion?.toca(punto: valor.location, vista: geometria.size,
                                            tamañoDeLaImagen: tamañoDeLaImagen,
                                            dimensionesDelCable: dimensionesDelCable,
                                            contacto: valor.startLocation) == true {
                                ultimoPunteroDeLaVista = valor.location
                            }
                        }
                        .onEnded { valor in
                            sesion?.levanta(punto: valor.location, vista: geometria.size,
                                            tamañoDeLaImagen: tamañoDeLaImagen,
                                            dimensionesDelCable: dimensionesDelCable,
                                            contacto: valor.startLocation)
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
            // LA CONTRASEÑA EN VUELO NO SE CORTA AQUÍ, y es a propósito (ronda 8). Este observador
            // corre DESPUÉS de que el coordinador aplique el evento, y entre los dos una tecla
            // pendiente todavía saldría. Se corta antes, en el mismo paso en que se aplica:
            // `BrowserMandoSesion.cambioElVolante()`, desde el bucle del consumidor.
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
        // EL TECLADO SUBE CON LA PULSACIÓN. El volante es suyo (el campo solo existe entonces) y
        // acaba de tocar la página: lo que quiere es teclear en lo que tocó. Se enfoca el campo
        // local, que es el único que puede levantar el teclado de iOS.
        .onChange(of: sesion?.pulsacionesEnviadas) { _, _ in
            // NO DURANTE LA DEVOLUCIÓN (revisión de Codex): mientras `devolviendo` la sesión ya
            // descarta las teclas, pero `quienConduce` sigue en `.yo` hasta que el servidor
            // contesta. Enfocar ahí dejaría caracteres en `tecleado` que nadie envió y que los
            // siguientes deltas tampoco reenviarían.
            guard BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce),
                  sesion?.devolviendo != true else { return }
            enfocado = true
        }
        .onChange(of: tecleado) { anterior, nuevo in
            guard BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce) else { return }
            // UNA sola cadena con el puntero, y con la generación del teclado: ver
            // `BrowserMandoSesion.teclea`. Un clic ya no puede adelantar a las teclas pendientes.
            sesion?.teclea(BrowserMandoEntrada.mensajesDeTeclado(anterior: anterior, nuevo: nuevo))
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
        // DEVOLVERLO VA ENTERO POR LA SESIÓN, Y EMPIEZA AQUÍ MISMO, SIN TAREA DE POR MEDIO
        // (ronda 8). `devuelve()` marca la devolución, corta las teclas pendientes y cierra el
        // gesto abierto con su soltar (N2) **antes** de cualquier espera: si se hiciera dentro de
        // una tarea, un `onChanged` del dedo que sigue apoyado podría colarse antes y abrir un
        // `mousePressed` que nadie soltaría. Devolverlo no se queda «pidiendo»: el servidor
        // publica el `mando` con `"agente"` y ése es el que mueve el rótulo.
        if accion == .devuelve, let sesion {
            sesion.devuelve()
            return
        }
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
