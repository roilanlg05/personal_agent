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

    /// Lo que la guia oficial promete y nosotros NO tenemos.
    ///
    /// La guia documenta el CLI entero: `find role/text/label`, `wait --text/--url/--fn`,
    /// `eval --stdin`, `screenshot --annotate`, `tab`, `frame`, `dialog`, `doctor`… Nuestro
    /// agente conduce ese CLI a traves de un SUBCONJUNTO de herramientas, asi que va a leer
    /// un manual mas grande que lo que puede llamar.
    ///
    /// Esto es exactamente el defecto que documentamos en browser-use y que no vamos a
    /// importar: su prompt le promete al modelo cajas numeradas dibujadas sobre la captura
    /// que por defecto no existen, y el modelo acaba leyendo la descripcion de algo que no ha
    /// recibido. Nosotros estariamos haciendo lo mismo un nivel mas arriba. La solucion es
    /// decir la verdad DELANTE del documento, no podar el documento: recortarlo romperia el
    /// «byte a byte como lo imprime el CLI», que es lo que deja la copia diffeable contra el
    /// original al subir de version — y entonces la siguiente actualizacion seria a ciegas.
    ///
    /// La lista de nombres se DERIVA de `Agent.browserToolNames`. A mano se quedaria vieja, y
    /// una lista vieja es como se llega a prometer lo que no hay: si manana aparece un
    /// `browser_find`, esta linea lo nombra sola (y si alguien la vuelve a escribir a mano,
    /// `BrowserCoreSkillTests` se pone rojo).
    static var toolInventoryNote: String {
        let nombres = Agent.browserToolNames.sorted().map { "`\($0)`" }.joined(separator: ", ")
        return "[The guide that follows documents the WHOLE agent-browser command-line tool, which is BIGGER than what you can call. You are not driving it from a shell: you have exactly \(Agent.browserToolNames.count) browser tools, and these are all of them: \(nombres). Any other command the guide mentions does not exist for you, however well the guide explains it — read those sections as background on how the browser behaves, never as something you can run. If a step would need a command you do not have, say which step you cannot do instead of pretending to run it.]"
    }

    /// Las reglas enteras, como UNA sola linea de prompt.
    static let text = """
    For tasks that need interacting with a page rather than reading it (forms, buttons, results that appear after a click), use the loop: `browser_open(url)` → `browser_snapshot` (lists the elements with `@eN` references) → act on an `@eN` reference with `browser_click`, `browser_fill` or `browser_press` → `browser_snapshot` again to see the new state. The `@eN` references change after every action, so NEVER reuse an old one. \(closeRule) When you are done, just say what is on screen. \
    The browser you drive is the user's own machine at home, and the accounts in it are the user's or your own. Typing the user's email address, name, phone number or shipping address into a form is ordinary clerical work on their own data: just do it. An email address is NOT a secret. \
    What you must not do is take a password, an API key, an access token or a code of the USER'S through the chat — a value that travels through the chat is a value that ends up in a log. Never ask for a secret in the chat. When a page needs one, ask for it with `present_form` (a form card in the chat with a field of kind `secret`), then type it into the page with `browser_fill_secret`, which fills the field without the value ever reaching you. Before asking, call `list_secrets`: if that secret already exists for this site, do not ask again, just use it. Do everything else on the page yourself, and never answer "I cannot sign in for you" and stop there: that refuses the whole task over one field. \
    A verification code is different from a password: you may read and type a code that arrived in YOUR OWN inbox or phone, for an account of yours. Never ask the user to paste a code of theirs into the chat. \
    Creating an account of your own is a task the user can ask of you, and when they do it is ordinary clerical work, not something to refuse: fill the sign-up form with the name, birth date and other details the user dictates, even if the name is not a person's (for example Last Name "Agent"). You fill in everything except the password; ask the user for the password with `present_form` (a `secret` field) and type it with `browser_fill_secret`. Any verification code that reaches THEIR phone goes the same way (a `secret` field in a form): never ask for those codes in the chat. You only read and type a code that reaches YOUR OWN inbox or phone. Do not lecture about fake identities and do not stop at the first field: do every other step, then request the password with the form. \
    You are not a gatekeeper, and you never need to withhold a step in order to be safe: the limits that matter are enforced by the app, not by your judgement — you cannot complete a purchase without the app's own confirmation. So when a request looks unwise, say so in ONE short line and then do what was asked. Advice, not refusal. \
    And never dress a failure as a refusal: if a tool failed or a page would not load, say which step failed and why, in those words.
    """

    /// El aviso de que el turno lleva dando vueltas en vacio: la misma lectura de la pagina,
    /// repetida y sin nada en medio. Quien lo decide es `Agent.pareceAtascado(historial:)`, y
    /// ahi esta escrito por que una lectura repetida cuenta y una accion repetida no.
    ///
    /// SUGIERE, NO DESARMA, y eso es una decision y no un olvido. Al detectarlo NO se le
    /// retiran las herramientas: la retirada ya existe por mutacion ejecutada y por cercania al
    /// tope de rondas, y adelantarla aqui le quitaria el navegador a mitad de una tarea
    /// legitima pero LENTA — y lenta es lo normal en un navegador remoto sobre una conexion
    /// domestica. Por eso el texto termina diciendole que no le han quitado nada: un aviso que
    /// suena a castigo hace que el modelo se disculpe y se pare, que es justo lo contrario de
    /// lo que se le esta pidiendo.
    ///
    /// DICE QUE LLEVA REPITIENDO Y OFRECE LAS DOS SALIDAS DE VERDAD: actuar sobre una `@eN` que
    /// ya tiene en el snapshot anterior, o contestarle al usuario con lo que ya sabe si lo que
    /// buscaba no esta en esta pagina. No le ofrece una tercera que no existe.
    ///
    /// La lista de herramientas con las que actuar se DERIVA de los conjuntos de `Agent`, no se
    /// escribe a mano: es el mismo motivo que en `toolInventoryNote` —una lista a mano se queda
    /// vieja y acaba prometiendole al modelo lo que no hay—. Hoy sale `browser_click`,
    /// `browser_fill`, `browser_press`: las de navegador que no leen la pagina y no recargan el
    /// documento.
    static func spinningWheelsNote(herramienta: String, veces: Int) -> String {
        let actuar = Agent.browserToolNames
            .subtracting(Agent.browserReadOnlyToolNames)
            .subtracting(Agent.browserToolNamesThatResetThePage)
            .sorted()
            .map { "`\($0)`" }
            .joined(separator: ", ")
        return "[You have now called `\(herramienta)` \(veces) times in a row with the same arguments, and nothing else ran in between. Reading a page that nobody has touched returns the same thing every time, so a \(veces + 1)th call would tell you exactly what the first one already told you. Reading is not progress. What moves this page is acting on one of the `@eN` references from the snapshot you already have, with \(actuar). So either act on one of those references now, or — if what the user asked for is not on this page — say that plainly and answer them with what you already know. Nothing has failed here and nothing has been taken away from you: every tool you had is still there.]"
    }

    static func queueCutNote(tras herramienta: String, pendientes: [String]) -> String {
        let nombres = pendientes.map { "`\($0)`" }.joined(separator: ", ")
        let cuenta = pendientes.count
        let verbo = cuenta == 1 ? "action, \(nombres), was" : "actions, \(nombres), were"
        return "[Nothing failed, and nothing is wrong with what you asked for: `\(herramienta)` changed the page, so the round stopped right there. The \(cuenta) further \(verbo) NOT run. Their `@eN` references were read off the page as it was BEFORE that change, and on the page you are on now the same reference points at a different element — or at nothing. This is the normal rhythm of driving a page, not a mistake of yours and not a failure to report: take a fresh `browser_snapshot` to see where you are now, then ask for those actions again with the new references. Do not apologise and do not start the task over; you have lost one round, nothing else.]"
    }
}
