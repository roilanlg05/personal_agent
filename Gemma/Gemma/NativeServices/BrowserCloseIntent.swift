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
/// LA NEGACIÓN GANA SIEMPRE. «No cierres el navegador hasta que yo te avise» contiene la palabra
/// cerrar y es exactamente la orden contraria. Por eso las negaciones se comprueban primero y
/// cortan: ante una frase que contiene las dos cosas, la lectura segura es la que deja la página
/// en pie.
public enum BrowserCloseIntent {

    /// Formas en que el usuario PROHÍBE cerrar. Se comprueban antes que nada y devuelven `false`
    /// aunque la frase contenga también una forma afirmativa.
    private static let prohibiciones: [String] = [
        "no cierres", "no lo cierres", "no la cierres", "no me lo cierres", "no me la cierres",
        "no cierre", "no cerrar", "sin cerrar", "nunca cierres", "no cierras",
        "dejalo abierto", "dejala abierta", "dejame abierto", "dejame abierta",
        "deja el navegador abierto", "deja la pagina abierta", "deja la pestana abierta",
        "mantenlo abierto", "mantenla abierta", "manten el navegador abierto",
        // El apóstrofo llega de tres maneras según el teclado: recto, tipográfico, o ninguno.
        "dont close", "don't close", "don\u{2019}t close", "do not close", "never close",
        "keep it open", "keep the browser open", "keep the page open", "leave it open",
        "leave the browser open", "leave the page open",
    ]

    /// Formas en que el usuario PIDE cerrar. Cada una nombra el objeto o lo lleva pegado al
    /// verbo (`ciérralo`): un «cierra» suelto no basta, porque se usa para otras cosas.
    private static let peticiones: [String] = [
        "cierra el navegador", "cierra la pagina", "cierra la pestana", "cierra la ventana",
        "cierrame el navegador", "cierrame la pagina", "cierrame la pestana",
        "cierralo", "cierrala", "cierralo ya", "cierrala ya",
        "puedes cerrar", "ya puedes cerrar", "ya puedes cerrarlo", "ya puedes cerrarla",
        "cerra el navegador", "cerra la pagina", "cerralo", "cerrala",
        "close the browser", "close the page", "close the tab", "close the window",
        "you can close", "you may close", "close it now", "please close",
    ]

    /// Minúsculas y sin diacríticos, para que «ciérralo» y «cierralo» sean la misma cosa y para
    /// que un acento de más o de menos no decida si se destruye lo que el usuario está mirando.
    static func normaliza(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    /// `true` solo si el texto pide cerrar y no lo prohíbe. Ante la duda, `false`.
    public static func userAskedToClose(_ text: String) -> Bool {
        let t = normaliza(text)
        if prohibiciones.contains(where: t.contains) { return false }
        return peticiones.contains(where: t.contains)
    }
}
