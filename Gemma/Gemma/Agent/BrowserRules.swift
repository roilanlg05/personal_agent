//
//  BrowserRules.swift
//  Gemma
//
//  NUESTRAS reglas del navegador: la UNICA fuente de las reglas que este proyecto le impone
//  al modelo cuando conduce una pagina. Se renderizan en DOS sitios y los dos salen de aqui:
//
//    1. `Agent.systemPromptText`, donde esta la linea del navegador: las reglas viajan en el
//       prompt del sistema, presentes desde el primer token del turno.
//    2. `Agent.browserGuideBlock()`, pegadas DELANTE de la guia oficial del CLI
//       (`BrowserCoreSkill.text`) con una frase que dice que, si las dos se contradicen,
//       manda la nuestra.
//
//  POR QUE EN DOS SITIOS, Y POR QUE NO SOLO EN LA GUIA INYECTADA. Que no se "simplifique"
//  esto borrando la renderizacion del prompt del sistema: seria un fallo de seguridad, no una
//  limpieza. La guia se inyecta con el RESULTADO de la primera herramienta de navegador del
//  turno, o sea DESPUES de que el modelo ya haya decidido y ejecutado esa primera accion.
//  «Nunca teclees una contrasena» hay que saberlo ANTES de llamar a `browser_fill`, no
//  despues: si viviera solo en la guia, el modelo podria teclear la contrasena del usuario en
//  su primer movimiento y leer la prohibicion a continuacion. Lo mismo con el candado de
//  `browser_close` y con que la pagina abierta suele ser el entregable. Estas reglas gobiernan
//  la DECISION de actuar, asi que tienen que estar presentes desde el primer token.
//
//  Y POR QUE UNA SOLA CONSTANTE. El riesgo de tener las reglas escritas en dos sitios no es
//  la repeticion: es que DIVERJAN. Mientras las dos renderizaciones se generen de esta
//  constante, no pueden divergir. `BrowserCoreSkillTests` lo clava afirmando que el texto de
//  esta constante aparece LITERAL en las dos renderizaciones: si alguien forkea una copia a
//  mano, la copia deja de coincidir y el test se pone rojo.
//
//  En ingles, como el prompt del sistema y las notas del bucle de herramientas: mezclar
//  idiomas en el prompt vivo sale peor que la regla de espanol del proyecto, que aplica a lo
//  que ve el usuario.
//
//  Una sola LINEA logica (las continuaciones `\` del literal multilinea borran los saltos):
//  dos tests del prompt localizan estas reglas partiendo el prompt por saltos de linea y
//  buscando la que contiene `browser_open(url)`, y esperan encontrarlas TODAS en esa linea.
//

enum BrowserRules {
    /// El candado de cierre, aparte porque se renderiza en TRES sitios: dentro de `text` (y
    /// por tanto en el prompt del sistema y en la guia inyectada) y ademas en la nota de
    /// resultado de cada herramienta de navegador (`Agent.toolResultNote`), que es lo ULTIMO
    /// que el modelo lee antes de decidir el paso siguiente y por eso gana sobre el prompt.
    ///
    /// Estaba escrito dos veces con palabras distintas —una en el prompt, otra en la nota—, que
    /// es exactamente la divergencia que esta constante impide.
    ///
    /// El candado de verdad NO es esta frase: vive en la app (`BrowserCloseIntent` +
    /// `BrowserCloseTool`), que no cierra nada si el usuario no lo ha pedido en el turno. Esto
    /// solo le explica al modelo por que su `refused` es la respuesta correcta, para que no
    /// entre en un bucle de reintentos contra un candado que nunca va a ceder.
    static let closeRule = "You do NOT close the browser. The open page is usually the thing the user asked for (a video playing, a page to read, a cart or form to review), so leaving it open is the normal ending, not an oversight. `browser_close` is gated by the app: it works only when the user asked to close in this turn, and otherwise returns `refused` with the page still open. That refusal is correct behaviour, not an error to retry."

    /// Las reglas enteras, como UNA sola linea de prompt.
    static let text = """
    For tasks that need interacting with a page rather than reading it (forms, buttons, results that appear after a click), use the loop: `browser_open(url)` → `browser_snapshot` (lists the elements with `@eN` references) → act on an `@eN` reference with `browser_click`, `browser_fill` or `browser_press` → `browser_snapshot` again to see the new state. The `@eN` references change after every action, so NEVER reuse an old one. \(closeRule) When you are done, just say what is on screen. \
    The browser you drive is the user's own machine at home, and the accounts in it are the user's or your own. Typing the user's email address, name, phone number or shipping address into a form is ordinary clerical work on their own data: just do it. An email address is NOT a secret. \
    What you must not type is a password, an API key or an access token — not even one the user hands you, because a value that travels through the chat is a value that ends up in a log. If a page needs a password, do everything else on the page, then name the ONE step that needs them and ask them to do that step. Never answer "I cannot sign in for you" and stop there: that refuses the whole task over one field. \
    A verification code is different from a password: you may read and type a code that arrived in YOUR OWN inbox or phone, for an account of yours. Never ask the user to paste a code of theirs into the chat. \
    You are not a gatekeeper, and you never need to withhold a step in order to be safe: the limits that matter are enforced by the app, not by your judgement — you cannot complete a purchase without the app's own confirmation. So when a request looks unwise, say so in ONE short line and then do what was asked. Advice, not refusal. \
    And never dress a failure as a refusal: if a tool failed or a page would not load, say which step failed and why, in those words.
    """
}
