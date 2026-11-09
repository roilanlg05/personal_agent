import CoreGraphics
import Foundation

/// El mapa de un punto de la pantalla del usuario a una coordenada del viewport de la página
/// remota.
///
/// POR QUÉ EXISTE. El agente conduce un navegador en el servidor doméstico y tiene prohibido
/// teclear contraseñas, así que para entrar en una cuenta el usuario toma el volante desde el
/// teléfono: toca la imagen del stream, escribe su contraseña y lo devuelve. `BrowserInputEvents`
/// ya sabe construir el mensaje, pero toma coordenadas **del viewport remoto**, y lo que el
/// teléfono tiene es un punto en un marco de SwiftUI. Traducir el uno en el otro es esto.
///
/// POR QUÉ LA DIRECCIÓN SEGURA ES `nil`, Y QUÉ SIGNIFICA `nil`. **`nil` significa «no mandes
/// nada», no «manda un cero».** El error natural de quien llame a esto es tratar el `nil` como
/// `.zero`, y eso es exactamente el fallo que este fichero existe para evitar: la página que
/// hay al otro lado tiene la sesión del usuario abierta, así que una coordenada equivocada
/// pulsa otro botón de su propia cuenta, y (0, 0) es la esquina de arriba a la izquierda, donde
/// casi todas las páginas ponen el logotipo y muchas el menú. Un toque perdido es una molestia;
/// un toque mal mapeado es daño. Ante cualquier dimensión ausente, ilegible o absurda, aquí no
/// sale coordenada.
///
/// POR QUÉ ES PURO Y SIN ESTADO, igual que su vecino `BrowserInputEvents`: no abre sockets, no
/// guarda nada y no decide cuándo se manda algo. Solo acierta la aritmética. Quién tiene el
/// volante y a qué ritmo se muestrea un gesto son decisiones de la capa de arriba.
///
/// AQUÍ NO SE REGISTRA NADA, Y NO ES NEGOCIABLE. El mapa no ve la tecla, pero sí ve **dónde**
/// toca el usuario, y un rastro de coordenadas sobre un teclado en pantalla reconstruye una
/// contraseña igual de bien. Este fichero no tiene ningún camino —ni de error— que escriba un
/// valor de entrada en ninguna parte. Lo afirma una prueba que LEE ESTE FUENTE
/// (`BrowserInputMapperTests.test_el_mapa_solo_usa_identificadores_permitidos`, que es
/// una lista BLANCA de identificadores: una lista negra solo prueba que no está lo que se te
/// ocurrió nombrar, y la que había aquí dejaba pasar seis fugas reales en verde), porque una ausencia no se puede
/// observar ejecutando código.
///
///
/// # LAS TRES ESCALAS, Y DE DÓNDE SALE CADA UNA
///
/// Entre el dedo del usuario y el píxel de la página hay tres cambios de tamaño encadenados, y
/// confundirlos es el fallo silencioso de esta tarea. Cada uno tiene una procedencia distinta y
/// ninguno es una constante:
///
/// **Escala 1 — del viewport de la página al fotograma que el servidor produce.** El demonio
/// escala el screencast para que quepa en los topes del `compose`. Medido con
/// `agent-browser 0.41.2`: viewport 1280×720 → JPEG 1080×608. Misma proporción (1.7778 contra
/// 1.7763), así que **hoy es una escala, no un recorte** — comprobado, no heredado del spec. El
/// tamaño del viewport llega por el cable, en los campos `viewport_width` y `viewport_height`
/// del mensaje `frame`, que son **enteros a propósito** (Swift decodifica por tipo y un `Int`
/// revienta con `1280.0`). El relé manda los dos lados o ninguno, nunca uno solo; aun así este
/// mapa no confía en eso, porque un cliente que asume el invariante del servidor se rompe el
/// día que el servidor cambie.
///
/// **Escala 2 — del fotograma que el servidor produce al JPEG que llega.** Es el mismo
/// fotograma, salvo que algo cambie por debajo, y por eso **se lee del tamaño de la imagen
/// decodificada y NUNCA de una constante**. Poner aquí un 1080×608 literal es precisamente el
/// error que el spec ya cometió una vez: el día que los topes del `compose` cambien, o que el
/// demonio sirva otra resolución, la constante sigue compilando, sigue pasando las pruebas, y
/// el usuario empieza a pulsar botones que no quería sin que nada se ponga rojo.
///
/// **Escala 3 — del JPEG al marco en el que SwiftUI lo dibuja.** `BrowserPanelView` usa
/// `.resizable().scaledToFit()`, así que la imagen se dibuja CENTRADA, lo más grande que quepa y
/// con la proporción intacta. Cuando el marco y la imagen no comparten proporción quedan bandas
/// —arriba y abajo, o a los lados— y **un punto sobre la banda no está sobre la página**: ése es
/// el `nil` que se calcula al píxel aquí abajo. El marco depende del teléfono, de la rotación y
/// de si el panel está expandido, así que tampoco es una constante: lo mide quien dibuja.
///
///
/// # LO QUE NO SE SUMA, Y ES LA PARTE CONTRAINTUITIVA
///
/// **El scroll no viaja por el cable y no se suma.** El demonio expone `scrollOffsetX` y
/// `scrollOffsetY` en su `metadata` y el implementador de la Tarea 2 los dejó fuera del cable a
/// propósito, con la medición hecha: al desplazar 900 px, `scrollOffsetY` pasó de 0 a 900
/// mientras las dimensiones **y el JPEG** no cambiaron. El fotograma retrata siempre el
/// viewport, y el demonio quiere coordenadas **del viewport**. Sumar el scroll serían 900 px de
/// error, es decir un clic en otro botón. Si algún día algo parece desplazado, el arreglo no es
/// sumar el scroll.
///
/// **`pageScaleFactor` tampoco viaja**: medido 1.0, y el subcomando `set` no está en
/// `cli.ALLOWED_SUBCOMMANDS`, así que por esta superficie no puede divergir. `offsetTop` medido
/// 0.0: no hay cromo que descontar.
public enum BrowserInputMapper {

    /// Las dos dimensiones del viewport remoto, tal como llegan en el mensaje `frame`
    /// (`viewport_width` y `viewport_height`, enteros). Opcional en la firma de abajo porque un
    /// fotograma puede no traerlas: el relé empezó a mandarlas en la Tarea 2 y un servidor sin
    /// desplegar no las manda.
    public struct DimensionesDelCable: Equatable {
        public let anchoDelViewport: Int
        public let altoDelViewport: Int
        public init(anchoDelViewport: Int, altoDelViewport: Int) {
            self.anchoDelViewport = anchoDelViewport
            self.altoDelViewport = altoDelViewport
        }
    }

    /// Cuántos píxeles de imagen se le perdonan a la proporción antes de declarar que lo que ha
    /// llegado no es el viewport escalado.
    ///
    /// NO ES COSMÉTICA. 1080/1280 × 720 = 607.5 y el demonio manda 608: medio píxel de
    /// desajuste, medido, porque el tamaño del fotograma es entero. Exigir proporción exacta
    /// dejaría el panel sin mandar nunca nada — el `nil` inútil, que también es un fallo, solo
    /// que silencioso. Un recorte de verdad se va por decenas.
    ///
    /// POR QUÉ 3 Y NO 2, QUE ES EL VALOR CON EL QUE ESTO NACIÓ. Porque **la medida de error de
    /// este guarda es asimétrica** y 2 dejaba mudo al único cliente real que hay, que es el
    /// teléfono. La escala del servidor se estima **solo con el ancho**, y el error que se
    /// compara está en píxeles de **alto**; si `δw` y `δh` son los dos redondeos que hace el
    /// servidor al pasar cada lado a entero, lo que mide el guarda es:
    ///
    ///     error = δh − δw · (altoDelViewport / anchoDelViewport)
    ///
    /// El redondeo del alto entra tal cual, pero **el del ancho entra multiplicado por la
    /// proporción del viewport**. Con el viewport apaisado del escritorio (720/1280 = 0.5625)
    /// eso es benigno. Con un viewport de teléfono, que es más alto que ancho, un solo píxel de
    /// redondeo del ancho se convierte en dos o tres píxeles de error medido, y el guarda
    /// rechaza una imagen que es una foto perfectamente correcta del viewport:
    ///
    ///     viewport 414×896 (iPhone), imagen 280×608  →  error +2.010  →  con 2.0, MUDO
    ///     viewport 390×844 (iPhone), imagen 280×608  →  error +2.051  →  con 2.0, MUDO
    ///     viewport 1280×720 (hoy),   imagen 1080×608 →  error  +0.50  →  pasa con las dos
    ///
    /// Diez milésimas de píxel separaban «el usuario teclea su contraseña» de «el panel se ve
    /// perfecto y el teléfono no manda ni un toque, sin un mensaje de error en ninguna parte».
    /// Las dos imágenes de teléfono de ahí arriba se desvían un 0.33 % de la proporción: son
    /// invisibles al ojo y correctas. Con 3 pasan.
    ///
    /// Y POR QUÉ NO MÁS DE 3. El margen existe para detectar algo, y hay un caso realista que
    /// **tiene** que seguir cayendo: si la tubería de codificación alinea el ancho a un múltiplo
    /// de 8 o de 16 —que es lo que hace cualquier codificador de vídeo—, 1080 se iría a 1088 o a
    /// 1072 y el error sería de 4 o de 5 píxeles. Eso NO es el viewport escalado y no se puede
    /// mapear, así que el mando se queda mudo entero, a propósito y documentado. Ese día el
    /// arreglo no es subir esta constante: es mirar la forma relativa del guarda (comparar las
    /// dos escalas por eje con tolerancia en tanto por ciento), que es un rediseño y cambia una
    /// prueba. Las pruebas de este fichero clavan la constante en el intervalo medido
    /// **[2.052, 4.0)**: por debajo de 2.052 los dos teléfonos se quedan mudos, y a partir de
    /// 4.0 pasa el caso de alineación a múltiplo de 16.
    public static let toleranciaDeProporcion: Double = 3.0

    /// La coordenada del viewport remoto que corresponde a un punto de la vista, o `nil` si no
    /// se puede saber con certeza.
    ///
    /// - Parameters:
    ///   - punto: el punto tocado, en el espacio de coordenadas del marco donde se dibuja la
    ///     imagen del stream (origen arriba a la izquierda del marco, no de la pantalla).
    ///   - tamañoDeLaVista: el tamaño de ese marco, medido por quien dibuja. Escala 3.
    ///   - tamañoDeLaImagen: el tamaño del JPEG **decodificado**, en píxeles. Escala 2, leída de
    ///     la imagen y nunca de una constante.
    ///   - dimensionesDelCable: las dimensiones del viewport que trajo el mensaje `frame`.
    ///     Escala 1.
    /// - Returns: la coordenada del viewport, con las dos componentes **enteras** y dentro de
    ///   `0…ancho-1` × `0…alto-1`; o `nil`, que significa **no mandes nada** y nunca `.zero`.
    public static func paginaDesde(punto: CGPoint,
                                   tamañoDeLaVista: CGSize,
                                   tamañoDeLaImagen: CGSize,
                                   dimensionesDelCable: DimensionesDelCable?) -> CGPoint? {

        // ── Escala 1: el viewport. Sin él no hay nada que calcular.
        guard let cable = dimensionesDelCable else { return nil }
        // NINGUNA PRUEBA PUEDE MATAR ESTE GUARDA POR SEPARADO, y es demostrable, no una
        // observación de una corrida concreta: cuando se llega al guarda de «la imagen no es
        // mayor que el viewport», el guarda del tamaño de la imagen ya garantiza
        // `anchoDeLaImagen >= 1` y `altoDeLaImagen >= 1`; si cualquiera de los dos lados del
        // viewport es <= 0, entonces `imagen >= 1 > 0 >= viewport` en ese eje y aquel guarda
        // devuelve `nil`. Y como el cable es `Int`, no hay valores intermedios entre 0 y 1 por
        // los que escapar. El resultado observable es el mismo con y sin esta línea.
        //
        // SE QUEDA, por dos motivos que no caducan. Dice el contrato (`viewport_width >= 1`)
        // donde se lee. Y es lo único que seguiría protegiendo si alguien reordenara los guardas
        // o tocara el de más abajo — y lo que sale de esta función sin los dos no es un cero
        // inocuo: con `anchoDelViewport = 0`, el recorte final `min(max(x, 0), ancho - 1)`
        // produce **−1**, una coordenada negativa. Las cifras de las mutaciones están en el
        // informe de la tarea, que lleva fecha; aquí queda solo el argumento.
        guard cable.anchoDelViewport >= 1, cable.altoDelViewport >= 1 else { return nil }
        let anchoDelViewport = Double(cable.anchoDelViewport)
        let altoDelViewport = Double(cable.altoDelViewport)

        // ── Escala 2: la imagen decodificada. Un tamaño de menos de un píxel, negativo o no
        // finito no se puede invertir, y pasa de verdad: el panel suelta el JPEG al plegarse y
        // al cerrarse la conexión, y un decodificador que falla puede dar un tamaño vacío sin
        // lanzar.
        guard tamañoDeLaImagen.width.isFinite, tamañoDeLaImagen.height.isFinite,
              tamañoDeLaImagen.width >= 1, tamañoDeLaImagen.height >= 1 else { return nil }
        let anchoDeLaImagen = Double(tamañoDeLaImagen.width)
        let altoDeLaImagen = Double(tamañoDeLaImagen.height)

        // El servidor escala el fotograma hacia ABAJO para que quepa en los topes del `compose`,
        // nunca hacia arriba. Una imagen mayor que el viewport contradice la premisa, y lo que
        // no se sabe entonces es si el dato roto es la imagen o el viewport.
        guard anchoDeLaImagen <= anchoDelViewport,
              altoDeLaImagen <= altoDelViewport else { return nil }

        // Y tiene que ser una escala UNIFORME, no un recorte. Por el cable no viaja ningún
        // desplazamiento, así que un recorte no se puede corregir: multiplicar por una
        // proporción lo estiraría y el usuario pulsaría otra cosa, en silencio. Lo único que se
        // puede hacer es detectarlo y callarse.
        //
        // LO QUE ESTE GUARDA DETECTA, Y LO QUE **NO** PUEDE DETECTAR. Esto es media protección y
        // hay que leerlo entero, porque la versión corta —«la huella que deja un recorte es que
        // la proporción de la imagen deja de ser la del viewport»— es FALSA para el recorte más
        // probable, y una promesa falsa en un comentario es peor que ningún comentario: el
        // siguiente construye encima de ella.
        //
        //   SÍ detecta el recorte que CAMBIA la proporción (un recorte no uniforme, o cualquier
        //   región cuya forma no sea la del viewport). Ése se va por decenas de píxeles de
        //   error medido y cae.
        //
        //   NO detecta el recorte que CONSERVA la proporción, y ése es justamente el que
        //   produciría la caja de topes de hoy, porque los topes (1080×608) tienen ya la
        //   proporción del viewport (1.776 contra 1.778). Si el demonio dejara de escalar y
        //   recortara una región centrada de 1080×608 de un viewport de 1280×720, por el cable
        //   llegaría EXACTAMENTE lo que llega hoy —cable 1280×720, imagen 1080×608—, el error
        //   medido sería 0.5 px y este guarda lo dejaría pasar. El punto (0, 0) se mapearía a
        //   (0, 0) cuando la verdad es (100, 56): cien píxeles de error horizontal, en
        //   silencio, con todo verde.
        //
        // ESE AGUJERO NO SE PUEDE CERRAR DESDE AQUÍ, y no es una excusa: es una consecuencia de
        // lo que viaja por el cable. Para distinguir un recorte conservador de una escala hace
        // falta el ORIGEN del fotograma, y el mensaje `frame` no lo trae (la Tarea 2 dejó fuera
        // `scrollOffsetX`/`scrollOffsetY` a propósito, y no hay ningún campo de origen del
        // recorte). Cerrarlo exige dos campos nuevos en el cable, o sea tocar el relé, que es
        // una decisión que no es de esta función. Queda escrito aquí como riesgo conocido: si
        // algún día alguien hace que el demonio recorte, este mapa NO avisará.
        let escalaDelServidor = anchoDeLaImagen / anchoDelViewport
        let altoQueTocaria = escalaDelServidor * altoDelViewport
        guard abs(altoDeLaImagen - altoQueTocaria) <= toleranciaDeProporcion else { return nil }

        // ── Escala 3: el rectángulo que SwiftUI dibuja de verdad dentro del marco.
        // `.scaledToFit()` = lo más grande que quepa con la proporción intacta, centrado.
        //
        // ESTE GUARDA Y EL DE LA ESCALA DE DIBUJO SE TAPAN CASI DEL TODO EL UNO AL OTRO, y
        // «casi» es la palabra que importa. Ninguna prueba mata a uno de los dos por separado,
        // porque el que queda atrapa los casos del otro: una vista de 0 o negativa da una escala
        // de dibujo no positiva; una vista `NaN` o `+∞` en un solo eje deja pasar la escala
        // —ojo, `Swift.min(1, NaN)` devuelve **1**, porque está definido como `y < x ? y : x`—
        // pero entonces el margen de ese eje sale `NaN` o `∞` y el recorte al rectángulo
        // dibujado rechaza el punto. Quitar los dos a la vez sí rompe, y con la peor salida
        // posible: vista 0×0 con el punto en el origen da `CGPoint(NaN, NaN)`, que no es `nil`
        // y que el llamante mandaría como coordenada.
        //
        // Y EL DE LA ESCALA DE DIBUJO NO ES EQUIVALENTE, aunque sobreviva. La etiqueta honesta
        // es «no distinguible por ninguna entrada ALCANZABLE», que es más débil, y la entrada
        // que lo distingue existe: punto 5e-311, vista 1e-310 × 1e-310, imagen y cable 1e18 ×
        // 1e18. Ahí `1e-310 / 1e18` **subdesborda a 0** sin que ninguno de los dos operandos sea
        // cero ni no finito, así que la vista pasa su propio guarda y la escala de dibujo vale 0;
        // sin esta línea el rectángulo dibujado es 0×0, el punto cae dentro, y sale
        // `CGPoint(NaN, NaN)`. No es alcanzable —SwiftUI no da vistas subnormales y el cable no
        // trae viewports de 10^18— pero no es lo mismo que ser equivalente.
        //
        // SE QUEDAN LOS DOS, y el subdesbordamiento es la razón de que sea redundancia útil y no
        // duplicado: cada uno cubre un subdominio que el otro no cubre del todo. Así la
        // seguridad de esta función no depende de que las comparaciones con `NaN` sean todas
        // falsas, que es verdad pero es un detalle que nadie recuerda al editar.
        guard tamañoDeLaVista.width.isFinite, tamañoDeLaVista.height.isFinite,
              tamañoDeLaVista.width > 0, tamañoDeLaVista.height > 0 else { return nil }
        let anchoDeLaVista = Double(tamañoDeLaVista.width)
        let altoDeLaVista = Double(tamañoDeLaVista.height)

        let escalaDeDibujo = min(anchoDeLaVista / anchoDeLaImagen, altoDeLaVista / altoDeLaImagen)
        guard escalaDeDibujo.isFinite, escalaDeDibujo > 0 else { return nil }
        let anchoDibujado = anchoDeLaImagen * escalaDeDibujo
        let altoDibujado = altoDeLaImagen * escalaDeDibujo
        let margenIzquierdo = (anchoDeLaVista - anchoDibujado) / 2
        let margenSuperior = (altoDeLaVista - altoDibujado) / 2

        // El punto, relativo al rectángulo dibujado. Fuera de él está la banda, y la banda no es
        // la página: no se manda nada. Los bordes SÍ cuentan, porque son las cuatro esquinas de
        // la página. Un punto que no es un número cae aquí también, sin comprobación aparte: las
        // comparaciones con `NaN` son todas falsas.
        let xRelativa = Double(punto.x) - margenIzquierdo
        let yRelativa = Double(punto.y) - margenSuperior
        guard xRelativa >= 0, xRelativa <= anchoDibujado,
              yRelativa >= 0, yRelativa <= altoDibujado else { return nil }

        // Deshacer la escala 3 para llegar al píxel del JPEG…
        let xDeLaImagen = xRelativa / escalaDeDibujo
        let yDeLaImagen = yRelativa / escalaDeDibujo

        // …y la escala 2+1 para llegar al píxel del viewport. CADA EJE POR SEPARADO, y es un
        // aviso explícito del implementador de la Tarea 2: con los tamaños medidos las dos
        // proporciones casi coinciden (1280/1080 = 1.1852 contra 720/608 = 1.1842), así que una
        // sola escala para los dos ejes se equivoca en menos de un píxel y el fallo NO SE VE.
        // Con un fotograma más pequeño el mismo desajuste de redondeo pasa de los tres píxeles.
        // Sin sumar scroll, y sin dividir por ninguna escala de página.
        let xDelViewport = xDeLaImagen * (anchoDelViewport / anchoDeLaImagen)
        let yDelViewport = yDeLaImagen * (altoDelViewport / altoDeLaImagen)

        // Al píxel, y dentro de la página.
        //
        // REDONDEAR AQUÍ Y NO EN EL LLAMANTE: `BrowserInputEvents.mouse`/`touch` toman `Int`, e
        // `Int(_:)` de un `CGFloat` **trunca**. Un 639.9999 salido de la coma flotante se
        // mandaría como 639, un píxel a la izquierda de donde el usuario tocó.
        //
        // RECORTAR DESPUÉS DE REDONDEAR, Y A ancho-1: `viewport_width` es un RECUENTO de
        // columnas, así que las direccionables son 0…ancho-1 y x=ancho está FUERA de la página
        // — no cae en el contenido, cae en la nada o en la barra de desplazamiento. La esquina
        // de abajo a la derecha de una página de 1280×720 es (1279, 719). Y al recortar después
        // de redondear, la componente ya es un entero exacto dentro del rango, así que ninguna
        // conversión del llamante —`Int()`, `rounded()`, `floor()`— puede salirse.
        let x = min(max(xDelViewport.rounded(), 0), anchoDelViewport - 1)
        let y = min(max(yDelViewport.rounded(), 0), altoDelViewport - 1)
        return CGPoint(x: x, y: y)
    }
}
