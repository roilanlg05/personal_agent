import Foundation

/// Los codificadores de la entrada del usuario cuando toma el volante del navegador remoto.
///
/// POR QUÉ EXISTE. El agente conduce un navegador en el servidor doméstico, y tiene prohibido
/// teclear contraseñas. Para entrar en una cuenta, el usuario toma el volante, escribe él su
/// contraseña y lo devuelve. Todo el lado del servidor está construido; lo que no había es
/// forma de mandar una sola tecla desde la app. Esto es la primera pieza: la forma exacta del
/// mensaje.
///
/// POR QUÉ ES PURO Y SIN ESTADO. No abre sockets, no guarda nada y no decide cuándo se manda
/// algo: solo construye el texto. Quién tiene el volante, cuándo se puede teclear y a qué ritmo
/// se muestrea un gesto son decisiones de la capa de arriba. Aquí solo se acierta la forma.
///
/// POR QUÉ LA FORMA SE MIDIÓ Y NO SE SUPUSO. El relé reenvía el mensaje al demonio **verbatim**
/// y valida **solo el `type`**, a propósito, para no acoplarse al protocolo de entrada del
/// demonio (`gemma-memory/browser/relay.py:678-684`). Nadie valida los campos: un campo mal
/// nombrado lo descarta el demonio sin error visible, y el síntoma que ve el usuario es «toco y
/// no pasa nada», indistinguible de media docena de fallos distintos. La forma de cada mensaje
/// sale de la referencia de streaming que trae el CLI `agent-browser` instalado, version-matched
/// (0.41.2), y la medición campo por campo, con la fuente de cada dato y con lo que NO se pudo
/// medir dicho como tal, está en
/// `docs/superpowers/notes/2026-11-09-protocolo-de-entrada-del-demonio.md`:
///
///     streaming.md:75  {"type": "input_mouse", "eventType": "mousePressed", "x": 40, "y": 40, "button": "left", "clickCount": 1}
///     streaming.md:76  {"type": "input_keyboard", "eventType": "keyDown", "key": "a", "text": "a"}
///     streaming.md:77  {"type": "input_touch", "eventType": "touchStart", "touchPoints": []}
///
/// SE EMITEN SIEMPRE TODOS LOS CAMPOS DEL EJEMPLO. Qué campos son obligatorios y cuáles tienen
/// valor por omisión no se pudo medir sin hablar con un demonio en marcha, y contra el servidor
/// doméstico no se puede abrir una sesión del CLI (el navegador comparte un solo perfil de
/// Chrome: una sesión paralela se queda el `SingletonLock` y la del agente deja de abrir páginas
/// en silencio, con todos los indicadores de salud en verde). Así que este código no depende de
/// ningún valor por omisión del demonio: los manda todos, explícitos.
///
/// TRES FUNCIONES, UN `type` CADA UNA, SIN VÍA GENÉRICA. No hay ningún parámetro de tipo, así
/// que no se puede construir un mensaje con un `type` que no sea uno de los tres que el relé
/// reenvía (`_ENTRADAS_REENVIABLES`, `relay.py:633`). Abrir esa lista por necesidad es lo que el
/// spec prohíbe con nombre y apellidos, y ya pasó una vez en este proyecto: la forma de que no
/// vuelva a pasar por descuido es que el cliente no sepa escribir otro tipo. Los `eventType` y
/// los botones son `enum` por lo mismo: un `String` libre permitiría un `"mousePress"` que el
/// demonio tira sin decir nada.
///
/// AQUÍ NO SE REGISTRA NADA, Y NO ES NEGOCIABLE. Lo que el usuario teclea puede ser su
/// contraseña. Ni rastro del panel, ni salida estándar, ni descripciones de excepción: este
/// fichero no tiene ningún camino de error que pudiera reproducir un valor de entrada. Vale
/// también para los valores intermedios: la cadena con la tecla no se le pasa a ninguna función
/// que registre. `ToolJSONOutput.object` no registra, y con `Int` y `String` no puede fallar; su
/// literal de reserva es constante y no contiene ninguna entrada. Lo afirma una prueba que LEE
/// ESTE FUENTE (`BrowserInputEventsTests.test_ninguna_funcion_del_fichero_registra_nada`),
/// porque una ausencia no se puede observar ejecutando código. Es frágil a propósito: si alguien
/// añade un rastro «solo para depurar», esa prueba se pone roja y dice por qué.
public enum BrowserInputEvents {

    // MARK: vocabulario del protocolo

    /// Los tres eventos de ratón. `mousePressed` está en el ejemplo publicado; `mouseReleased` y
    /// `mouseMoved` son literales del binario instalado y son los nombres de CDP.
    public enum TipoDeRaton: String {
        case pulsado = "mousePressed"
        case soltado = "mouseReleased"
        case movido = "mouseMoved"
    }

    /// `left` está en el ejemplo publicado; `right` y `middle` son literales del binario,
    /// contiguos a los tres nombres de evento de arriba.
    public enum BotonDelRaton: String {
        case izquierdo = "left"
        case derecho = "right"
        case central = "middle"
    }

    /// `keyDown` está en el ejemplo publicado. `keyUp` es el nombre de CDP y es inferencia: su
    /// literal NO aparece en el binario instalado — pero tampoco aparece el de ningún `type` de
    /// los tres mensajes, ni el que necesita el comando `agent-browser keyup` del propio CLI,
    /// así que en ese binario la ausencia de un literal no prueba nada. Está en la nota.
    public enum TipoDeTeclado: String {
        case abajo = "keyDown"
        case arriba = "keyUp"
    }

    /// `touchStart` está en el ejemplo publicado; `touchMove` y `touchEnd` son los nombres de
    /// CDP para el resto del gesto.
    public enum TipoTactil: String {
        case inicio = "touchStart"
        case movimiento = "touchMove"
        case fin = "touchEnd"
    }

    /// El tope de un mensaje del visor en el relé (`MAX_MENSAJE_VISOR`, `relay.py:641`).
    public static let topeDelRele = 4096

    // MARK: los tres mensajes

    /// Un evento de ratón en coordenadas del VIEWPORT de la página remota (no de la pantalla
    /// del usuario: mapearlas es de la capa que dibuja el fotograma, y ante una dimensión
    /// ausente, ilegible o absurda esa capa no manda nada, porque un toque mal mapeado pulsa
    /// otra cosa en la página del usuario).
    ///
    /// `pulsaciones` es el `clickCount` del ejemplo publicado, que vale 1 para una pulsación
    /// simple. Para un `movido` no significa nada y se puede pasar 0.
    public static func mouse(tipo: TipoDeRaton, x: Int, y: Int,
                             boton: BotonDelRaton, pulsaciones: Int = 1) -> String {
        ToolJSONOutput.object([
            "type": "input_mouse",
            "eventType": tipo.rawValue,
            "x": x,
            "y": y,
            "button": boton.rawValue,
            "clickCount": pulsaciones,
        ])
    }

    /// Una tecla. `tecla` es el nombre de la tecla (`"a"`, `"Enter"`, `"Backspace"`) y `texto`
    /// es el carácter que esa tecla inserta, vacío para las teclas que no insertan nada. Los dos
    /// van siempre, incluso vacío `texto`: el ejemplo publicado lleva los cuatro campos y aquí no
    /// se depende de ningún valor por omisión del demonio.
    ///
    /// NI `tecla` NI `texto` SE REGISTRAN, y tampoco el JSON que los contiene. Es la restricción
    /// de arriba y es el motivo de que esta función no tenga ninguna rama de error: no hay dónde
    /// escribir un mensaje que los reprodujera.
    public static func keyboard(tipo: TipoDeTeclado, tecla: String, texto: String) -> String {
        ToolJSONOutput.object([
            "type": "input_keyboard",
            "eventType": tipo.rawValue,
            "key": tecla,
            "text": texto,
        ])
    }

    /// Un punto de un gesto táctil, en coordenadas del viewport remoto.
    ///
    /// La forma de un punto es INFERENCIA, y la única de este fichero: el ejemplo publicado manda
    /// la lista vacía (`"touchPoints": []`), así que `{x, y}` sale de la especificación de
    /// `Input.dispatchTouchEvent` de CDP —cuyo `TouchPoint` solo exige `x` e `y`— y de que el
    /// demonio llama a ese método (su literal está en el binario instalado). No está verificado
    /// contra un demonio en marcha.
    ///
    /// En `fin` la lista va VACÍA: `touchPoints` son los puntos que siguen activos, y al acabar
    /// el toque no queda ninguno. Es la única rama de este fichero donde el tipo de evento cambia
    /// la forma del mensaje y no solo un valor.
    public static func touch(tipo: TipoTactil, x: Int, y: Int) -> String {
        let puntos: [[String: Int]] = tipo == .fin ? [] : [["x": x, "y": y]]
        return ToolJSONOutput.object([
            "type": "input_touch",
            "eventType": tipo.rawValue,
            "touchPoints": puntos,
        ])
    }

    // MARK: el tope del relé

    /// Si este mensaje sobrevive al tope del relé.
    ///
    /// POR QUÉ LO COMPRUEBA EL CLIENTE. Lo que pasa el tope se descarta **en silencio**
    /// (`relay.py:655`, y su propio comentario dice que eso no es un fallo sino el diseño), así
    /// que un mensaje demasiado grande desaparece sin error y el usuario solo ve que no pasó
    /// nada. Nadie va a avisar: la comprobación es de aquí. Un pegado largo se parte en varios
    /// mensajes de teclado.
    ///
    /// POR QUÉ BYTES Y NO CARACTERES. El relé compara `len(text)` de un `str` de Python, que
    /// cuenta PUNTOS DE CÓDIGO, no bytes; el plan de esta tarea decía «bytes». En UTF-8
    /// `bytes ≥ puntos de código` siempre, así que contar bytes es *más estricto* que el relé y
    /// es correcto en la dirección que importa: si esto dice que sí, el relé no lo descarta. La
    /// promesa del nombre se cumple. La dirección contraria no se puede prometer, porque lo que
    /// haya aguas abajo del relé cuenta bytes y no se puede medir desde aquí. El hueco entre los
    /// dos criterios solo lo alcanza un `texto` de miles de caracteres no-ASCII en un solo
    /// mensaje, que es justo el pegado largo que hay que partir. Comprobar las dos cosas sería
    /// redundante —`bytes ≤ 4096` implica `puntos ≤ 4096`— y dejaría una condición que ninguna
    /// prueba puede matar por separado. El razonamiento entero está en la nota.
    ///
    /// Y el aviso: `String.count` de Swift cuenta GRAFEMAS. `"é"` compuesta es 1 grafema, 2
    /// escalares y 3 bytes. Para hablar de este tope hay que usar `.utf8.count`.
    public static func cabeEnElTope(_ json: String) -> Bool {
        json.utf8.count <= topeDelRele
    }
}
