import Foundation

/// ¿Pidió el usuario, con sus propias palabras y en este turno, que se cierre el navegador?
///
/// POR QUÉ ESTO EXISTE. El modelo cerraba la página del usuario por su cuenta. Se intentó
/// arreglar en el prompt dos veces —primero quitando la orden incondicional de cerrar, luego
/// haciendo que la nota de resultado cediera ante lo que el usuario hubiera dicho— y las dos
/// veces el modelo cerró igual. La tercera vez el usuario pidió «ábreme la Wikipedia con la
/// página de anatomía PARA LEERLA» y el modelo la cerró al acabar el turno: la página era el
/// entregable y el modelo la destruyó. Un prompt es una petición, no un candado. Si lo que hay
/// que impedir es que el modelo destruya lo que el usuario está mirando, lo tiene que impedir la
/// app.
///
/// POR QUÉ AQUÍ SÍ SE LEEN LAS PALABRAS DEL USUARIO, cuando en la puerta de compra se decidió
/// que NUNCA se harían coincidir palabras clave. La diferencia es la dirección del error, y es
/// la que manda:
///
///   - En la puerta de compra, un falso positivo GASTA DINERO del usuario y no se deshace. Por
///     eso allí la autorización no puede salir de un texto: tiene que ser un acto explícito.
///   - Aquí el valor por defecto es NO CERRAR. Un falso negativo deja una página abierta, que no
///     cuesta nada y se arregla pidiéndolo otra vez. Un falso positivo cierra una página, que se
///     vuelve a abrir. Ninguno de los dos destruye nada irrecuperable.
///
/// Dicho de otro modo: esto no autoriza una acción peligrosa a partir de un texto, sino que
/// LEVANTA un candado para una acción barata. El candado es el valor por defecto, y el texto solo
/// puede abrirlo. Si algún día cerrar el navegador llegara a tener un coste real (perder una
/// sesión autenticada, por ejemplo, que es justo lo que traerá el perfil persistente), este
/// razonamiento deja de valer y hay que volver a un acto explícito del usuario en la interfaz.
///
/// CORRECCIÓN, tras la primera prueba real. La primera versión de este candado trataba el falso
/// negativo como gratis. No lo es. El usuario pidió cerrar, el candado lo rechazó varias veces, y
/// el agente le contestó que «el usuario no ha pedido que se cierre el navegador» cuando acababa
/// de pedirlo: eso es una avería a la vista, y peor que cerrar algo de más. De los dos errores,
/// el único que se arregla solo es el falso positivo (se reabre la página). Por eso la regla pasó
/// de una lista de frases hechas a una regla sobre el VERBO de cerrar: acierta en cualquier
/// manera de pedirlo, a cambio de dispararse alguna vez de más.
///
/// LA NEGACIÓN GANA SIEMPRE. «No cierres el navegador hasta que yo te avise» contiene la palabra
/// cerrar y es exactamente la orden contraria. Por eso las negaciones se comprueban primero y
/// cortan: ante una frase que contiene las dos cosas, la lectura segura es la que deja la página
/// en pie.
public enum BrowserCloseIntent {

    /// Formas en que el usuario PROHÍBE cerrar. Se comprueban antes que nada y devuelven `false`
    /// aunque la frase contenga también el verbo cerrar.
    private static let prohibiciones: [String] = [
        "no cierres", "no lo cierres", "no la cierres", "no me lo cierres", "no me la cierres",
        "no cierre", "no cerrar", "sin cerrar", "nunca cierres", "no cierras", "no lo cierre",
        "no hace falta cerrar", "no cierres nada",
        "dejalo abierto", "dejala abierta", "dejame abierto", "dejame abierta",
        "deja el navegador abierto", "deja la pagina abierta", "deja la pestana abierta",
        "mantenlo abierto", "mantenla abierta", "manten el navegador abierto",
        // El apóstrofo llega de tres maneras según el teclado: recto, tipográfico, o ninguno.
        "dont close", "don't close", "don\u{2019}t close", "do not close", "never close",
        "keep it open", "keep the browser open", "keep the page open", "leave it open",
        "leave the browser open", "leave the page open",
    ]

    /// El verbo de cerrar, en las formas que de verdad escribe alguien. Se comparan TOKENS
    /// enteros, no subcadenas: así «closed» («the shop is closed») no cuenta como una orden, y
    /// «ciérralo» sí, porque es su propio token.
    ///
    /// POR QUÉ ESTO DEJÓ DE SER UNA LISTA DE FRASES. La primera versión exigía frases completas
    /// («cierra el navegador», «ciérralo», «ya puedes cerrar»…). El usuario pidió cerrar, el
    /// candado lo rechazó varias veces, y el agente le contestó que «el usuario no ha pedido que
    /// se cierre el navegador» cuando sí lo había pedido. Una lista de frases hechas acierta solo
    /// en las maneras de decirlo que a mí se me ocurrieron, y la gente dice las cosas de muchas
    /// maneras. El verbo, en cambio, lo lleva cualquier forma de pedirlo.
    ///
    /// Y CAMBIA EL CÁLCULO DEL ERROR que justificaba la lista estrecha. Se escribió asumiendo que
    /// un falso negativo era gratis («deja una página abierta, no cuesta nada»). No lo es: deja
    /// al agente diciéndole al usuario que no pidió lo que acaba de pedir, que es una avería a la
    /// vista. Un falso positivo cierra una página que se vuelve a abrir. Así que la regla se
    /// abre, a sabiendas de que «cierra el trato con ese proveedor» cerrará el navegador: ese
    /// error se arregla reabriendo, y el otro no se arregla, se sufre.
    private static let verbos: Set<String> = [
        "cierra", "cierre", "cierres", "cierro", "cierralo", "cierrala", "cierralos", "cierralas",
        "cierrame", "cierramelo", "cierramela", "cerrar", "cerrarlo", "cerrarla", "cerrarlos",
        "cerrarlas", "cerremos", "cerramos",
        // Variante rioplatense/imperativa sin diptongo, por si acaso.
        "cerra", "cerralo", "cerrala", "cerrame",
        "close", "closing",
    ]

    /// Verbos que solo cuentan si además se nombra lo que hay que cerrar: «apaga» o «quita» a
    /// secas son demasiadas otras cosas («apaga la luz»), pero «apaga el navegador» no.
    private static let verbosConObjeto: Set<String> = [
        "apaga", "apagalo", "apagala", "quita", "quitalo", "quitala",
        "termina", "terminalo", "terminala", "sal", "salte",
    ]

    private static let objetos: Set<String> = [
        "navegador", "pagina", "pestana", "ventana", "browser", "page", "tab", "window",
    ]

    /// Minúsculas y sin diacríticos, para que «ciérralo» y «cierralo» sean la misma cosa y para
    /// que un acento de más o de menos no decida si se destruye lo que el usuario está mirando.
    static func normaliza(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    /// Las palabras del texto, en minúsculas y sin diacríticos. Se parte por todo lo que no es
    /// una letra, así que la puntuación y los emoji no pegan dos palabras ni parten una.
    static func palabras(_ text: String) -> [String] {
        normaliza(text)
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }

    /// `true` si el texto pide cerrar y no lo prohíbe. La prohibición se comprueba primero y
    /// corta: ante una frase que dice las dos cosas, la lectura segura deja la página en pie.
    public static func userAskedToClose(_ text: String) -> Bool {
        if prohibiciones.contains(where: normaliza(text).contains) { return false }
        let tokens = Set(palabras(text))
        if !tokens.isDisjoint(with: verbos) { return true }
        return !tokens.isDisjoint(with: verbosConObjeto) && !tokens.isDisjoint(with: objetos)
    }
}
