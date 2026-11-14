import SwiftUI

/// Lo que dice una fila de herramienta plegada.
///
/// Regla del usuario: contar es honesto, interpretar no; y cuando la herramienta
/// devuelve un dato concreto (un precio, un host), ese dato sí se ve.
public nonisolated enum ToolRowSummary: Equatable {
    case ok
    case value(String)
    case count(Int, String)
    case failure(String)
    /// La herramienta no pudo seguir y espera algo del usuario (un permiso, una
    /// confirmación, una elección). No es éxito ni fallo: icono y color propios.
    case needsYou
}

/// Fila del registro de chat para una llamada a herramienta. Plegada enseña el
/// estado, el nombre y un resumen; abierta, el resultado recortado.
public struct ToolLogRow: View {
    @Binding var entry: ChatLogEntry

    public init(entry: Binding<ChatLogEntry>) {
        self._entry = entry
    }

    /// Tope de caracteres que se pintan al abrir la fila. Un `browser_get html`
    /// de una página real son cientos de kB y un `Text` de ese tamaño cuelga la
    /// interfaz (sobre todo en el teléfono); 4000 caben en varias pantallas de
    /// lectura y se pintan al instante.
    public nonisolated static let detailLimit = 4_000

    // MARK: - Lógica pura

    /// Tope del mensaje de un estado no fallido: el resumen es una línea.
    public nonisolated static let messageLimit = 120

    /// Frase fija de la fila "te pide algo". Nunca el `message` de la herramienta:
    /// esos mensajes están redactados para el modelo (segunda persona, con
    /// instrucciones) y no deben pintarse en la cara del usuario.
    public nonisolated static let needsYouText = "necesita algo de ti"

    /// Estados que piden algo al usuario: ni éxito ni fallo. Cerrado y enumerado
    /// a propósito; añadir uno exige una prueba.
    private nonisolated static let needsYouStatuses: Set<String> = [
        "permission_required", "confirmation_required", "needs_criteria",
        "needs_time", "ambiguous", "conflict", "location_unknown",
        "no_forecast", "unknown",
    ]

    /// Los únicos estados que pintan la fila en rojo. Las herramientas devuelven
    /// ~70 estados distintos y solo una minoría es "success", así que tratar «no
    /// success» como fallo pintaría en rojo la mayoría de los retornos correctos
    /// ("ok", "created", "deleted", "found"…). La polaridad va al revés: se
    /// enumera el fallo, no el éxito. Además, todo estado con prefijo `invalid_`
    /// es fallo.
    ///
    /// CÓMO SE HACE EL CENSO. Este grep ve también los estados que se CONSTRUYEN
    /// en código en vez de escribirse como literal dentro de un objeto:
    ///
    ///     grep -rhoE '(status|"status")[ :=]+"[a-z_]+"' --include='*.swift' Gemma/Gemma \
    ///       | grep -oE '"[a-z_]+"$' | sort -u
    ///
    /// El grep estrecho `"status" *: *"[a-z_]+"` (solo forma de objeto) se perdía
    /// `refused` y `not_available`, que las nueve herramientas del navegador
    /// construyen en `AgentBrowserToolOutput.resolve(_:extra:)` con
    /// `status = "refused"`; un `browser_open` rechazado salía con tilde verde.
    /// Medición de referencia: docs/superpowers/notes/2026-11-08-medicion-nitidez-panel.md
    /// Interno y no privado a propósito: `AgentTests
    /// .test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` lo recorre entero para
    /// clavar la coherencia con `Agent.estadosDeFallo`, y
    /// `ToolLogRowTests.test_cada_estado_de_fallo_tiene_su_frase_fija_…` exige que ninguno se
    /// quede sin frase. Un censo que no se puede recorrer desde una prueba se queda a medias.
    nonisolated static let failureStatuses: Set<String> = [
        "failed", "error", "timeout", "unavailable", "memory_unavailable",
        "permission_denied", "rejected", "not_found", "contact_not_found",
        "place_not_found", "not_in_catalog", "unknown_topic", "unsupported",
        "unsupported_kind", "limit_reached", "missing_fields", "name_taken",
        "no_phone_number", "period_in_past", "refused", "not_available",
        "dry_run",
        // `play_music`, Y ES UN FALLO QUE SALÍA CON TILDE VERDE. Este conjunto tenía
        // `not_available` —el de `ShortcutRunOutcome`— y NO `app_unavailable`, que es otro
        // estado, de otra familia y de otra herramienta: lo construye
        // `MusicPlaybackOutcome.appUnavailable` desde su `rawValue`, así que NINGÚN censo de
        // literales lo ve (ni el grep de arriba ni el recorrido por el cuerpo de `run`; hay que
        // leer el enum a mano). «La app de música no está instalada» se resumía «listo»: nada
        // sonó y el usuario leía que sí, que es la peor de las dos direcciones en las que esta
        // fila puede mentir. Lo mide `ElFalloPintadoComoExitoTests
        // .test_la_app_de_musica_que_no_esta_sale_con_cruz_roja_y_no_con_un_listo`.
        "app_unavailable",
    ]

    /// LA FRASE DE LA APP CON LA QUE SE RESUME UN FALLO. Una por estado, fija, en español y
    /// escrita para el USUARIO.
    ///
    /// EL DEFECTO QUE ARREGLA, MEDIDO. La rama de fallo de `summarize` pintaba el `message` de
    /// la herramienta, y esos textos están redactados para el MODELO: segunda persona y con
    /// instrucciones. El caso que esta rama introdujo lo deja a la vista: cuando el modelo
    /// alucina el nombre de una herramienta —el error más común que comete—, el bucle contesta
    /// con `Agent.resultadoDeHerramientaInexistente`, y sus primeros 120 caracteres son «No
    /// existe ninguna herramienta llamada 'X'. **No la vuelvas a llamar: usa una de las
    /// herramientas que tienes disponibles**, o…». O sea una orden dirigida a otro, en la
    /// pantalla del usuario. Es el mismo defecto que ya costó una rama entera
    /// (`ToolSyntaxStreamGate`), entrando por otra puerta.
    ///
    /// Y NO DEJA AL USUARIO SIN PISTA: la pista es el estado traducido al castellano, y el
    /// motivo íntegro sigue a un toque de distancia en el detalle de la fila
    /// (`detail(resultJSON:)`, 4.000 caracteres) y sigue viajando ENTERO al modelo en la nota
    /// de resultado. No se pierde nada; cambia para quién está escrito lo que se lee de un
    /// vistazo.
    ///
    /// Es el patrón que este fichero ya usa dos veces: `needsYouText` para los estados que
    /// piden algo, y la rama `case nil` de `summarize` con su «listo».
    ///
    /// POR QUÉ `not_available` NO DICE «el navegador no está instalado», que es lo que pedía
    /// de entrada el arreglo: el estado NO es solo del navegador. `ShortcutRunOutcome
    /// .notAvailable` lo emite también `run_shortcut`, `play_music` y `send_message` cuando la
    /// app Atajos no está disponible en el dispositivo, así que nombrar el navegador ahí sería
    /// mentir en tres herramientas para acertar en nueve. «no está disponible» es cierto en las
    /// doce.
    private nonisolated static let frasesDeFallo: [String: String] = [
        // El contrato de las nueve herramientas del navegador (`AgentBrowserToolOutput`).
        // `refused` sí es solo del navegador (censado): lo construyen `AgentBrowserToolOutput
        // .resolve` y el candado de `BrowserCloseTool`.
        "refused": "el navegador no lo hizo",
        "not_available": "no está disponible",
        "error": "falló",
        // Infraestructura y «no pude» del resto del registro.
        "failed": "no se pudo hacer",
        "timeout": "tardó demasiado",
        "unavailable": "el servicio no respondió",
        "memory_unavailable": "la memoria no respondió",
        "permission_denied": "sin permiso",
        "rejected": "no se aceptó",
        "not_found": "no se encontró",
        "contact_not_found": "ese contacto no está",
        "place_not_found": "ese sitio no está",
        "not_in_catalog": "no está en el catálogo",
        "unknown_topic": "ese tema no está",
        "unsupported": "eso no se puede hacer",
        "unsupported_kind": "ese tipo no se puede",
        "limit_reached": "se llegó al límite",
        "missing_fields": "faltan datos",
        "name_taken": "ese nombre ya existe",
        "no_phone_number": "no hay número de teléfono",
        "period_in_past": "esa fecha ya pasó",
        // `play_music`. Aquí SÍ se puede nombrar la app de música, al contrario que en
        // `not_available`: ese estado lo emiten doce herramientas y nombrar una sería mentir en
        // tres para acertar en nueve, mientras que `app_unavailable` es exclusivo de
        // `MusicPlaybackOutcome` —censado con un grep sobre todo el árbol— y por tanto solo de
        // `play_music`. Decirle «no está disponible» sobre la música sería cierto pero inútil:
        // lo que tiene que saber es que le falta la app, porque eso es lo que puede arreglar.
        "app_unavailable": "la app de música no está instalada",
        // A to Z. EL MODO SIMULADO ES OPT-IN: viene DESACTIVADO de fábrica —`AtoZSettings.load`
        // lo lee como `?? false` y `SettingsView` lo declara `= false`—, así que el camino
        // normal de una aceptación de turno es el REAL y la petición sí llega a Amazon. Este
        // estado es el camino del usuario que ENCENDIÓ la simulación en Ajustes: se validó
        // todo y no se envió nada. Ni «listo» —el turno no se cogió— ni «falló» —no se rompió
        // nada—: cuando la simulación está encendida, el único texto honesto sobre la
        // herramienta que le coge turnos de trabajo es que no pasó de verdad, y que eso lo
        // cambia él en Ajustes. La premisa la clava `TresCorreccionesDelStatusTests
        // .test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica`.
        "dry_run": "no se hizo de verdad: era una prueba",
    ]

    /// La frase de la app para un estado de fallo. Nunca vacía: un estado sin frase propia cae
    /// en «falló», que dice menos pero no miente, y los `invalid_*` —que son una familia
    /// abierta, no un censo— llevan la suya.
    public nonisolated static func fraseDeFallo(status: String) -> String {
        if let frase = frasesDeFallo[status] { return frase }
        if status.hasPrefix("invalid_") { return "los datos no valían" }
        return "falló"
    }

    /// EL TERCER TEXTO DE LA FILA: «se hizo algo, pero NO lo que el usuario pidió».
    ///
    /// No es un fallo —no se rompió nada y pintarlo en rojo diría que sí— y no es «listo»
    /// —«listo» afirma que la cosa ocurrió, y no ocurrió—. Es el hueco entre los dos, y la fila
    /// ya lo tenía abierto para un caso (`cierreRechazadoText`, el candado de `browser_close`);
    /// esto lo convierte en una tabla.
    ///
    /// EL DEFECTO QUE ARREGLA, MEDIDO. `play_music` devuelve `search_opened` cuando solo
    /// consiguió abrir el BUSCADOR de la app (el usuario tiene que elegir un resultado y nada
    /// suena) y `launching` cuando la app aceptó el enlace profundo pero NO se pudo comprobar
    /// que la reproducción arrancara. La descripción de la propia herramienta se lo dice al
    /// modelo con estas palabras —«Informa al usuario exactamente lo que dice 'status': no
    /// afirmes que la música suena si es 'search_opened'»— y la fila del usuario decía
    /// **«listo»** en los dos casos. O sea que el modelo estaba advertido y el usuario no.
    ///
    /// SE INDEXA POR EL PAR (HERRAMIENTA, ESTADO), Y ESO ES LA LECCIÓN DE `cancelled`. El
    /// repositorio ya tiene medido que el NOMBRE de un estado no basta para decidir qué
    /// significa: `cancelled` es un éxito en `cancel_events` y `cancel_alarm` y significa «el
    /// usuario lo descartó y NO se ejecutó» en `run_shortcut` y `send_message`. Los tres estados
    /// de `MusicPlaybackOutcome` son hoy exclusivos de `play_music` (grep sobre todo el árbol),
    /// así que una tabla por nombre funcionaría hoy; se escribe por par para que no sea una
    /// trampa el día en que otra herramienta estrene un `launching` que signifique otra cosa.
    /// Lo clava `ElFalloPintadoComoExitoTests
    /// .test_la_frase_es_del_par_y_no_del_nombre_del_estado_suelto`.
    ///
    /// Y LAS FRASES SON DE LA APP, no el `message` de la herramienta: ese texto está redactado
    /// para el MODELO y ningún texto escrito para el modelo llega a la pantalla del usuario, que
    /// es la regla que este fichero existe para sostener.
    private nonisolated static let frasesDeEstadoAMedias: [String: [String: String]] = [
        PlayMusicTool.name: [
            // Se abrió el buscador de la app con el término dentro: el usuario tiene que elegir.
            "search_opened": "se abrió el buscador: no está sonando",
            // La app aceptó el enlace, pero sin controlador de la app no hay forma de verificar
            // la reproducción (en macOS la hay por Apple Events y entonces el estado es
            // `playing`; en iOS no existe equivalente). Afirmar que suena sería inventarlo.
            "launching": "se abrió en la app: no está sonando aún",
        ],
    ]

    /// La frase de la app para un par (herramienta, estado) que quedó a medias, o `nil` si ese
    /// par no es uno de ellos. Interna y no privada a propósito: la prueba la recorre desde
    /// producción para que la fila y la tabla no puedan decir cosas distintas.
    public nonisolated static func fraseDeEstadoAMedias(toolName: String, status: String) -> String? {
        frasesDeEstadoAMedias[toolName]?[status]
    }

    /// Lo que la fila dice de un `browser_close` que el candado de la app rechazó.
    ///
    /// NO ES UN FALLO Y NO SE PINTA COMO TAL. El candado rechaza todo cierre que el usuario no
    /// haya pedido en este turno, y eso es la conducta correcta: muchas veces la página abierta
    /// ES lo que el usuario pidió (ver `BrowserCloseTool`). Una cruz roja ahí le dice que algo
    /// se rompió cuando lo que pasó es que la app lo protegió.
    public nonisolated static let cierreRechazadoText = "la página sigue abierta"

    /// Cierra la fila de una herramienta: rellena el `toolDetail` de la última
    /// fila abierta con ese nombre. Se busca de atrás hacia delante porque puede
    /// haber dos llamadas a la misma herramienta en el mismo turno y la que se
    /// cierra es la última abierta. Si no hay ninguna (un `finished` sin su
    /// `started`), se añade una fila nueva para no perder el resultado.
    public nonisolated static func closeRow(in log: inout [ChatLogEntry], toolName: String, result: String) {
        if let i = log.lastIndex(where: { $0.role == "tool" && $0.toolName == toolName && $0.toolDetail == nil }) {
            log[i].toolDetail = result
        } else {
            log.append(ChatLogEntry(role: "tool", text: "", toolName: toolName, toolDetail: result))
        }
    }

    /// Qué herramientas devuelven un dato. Es el único sitio donde se decide;
    /// las que no aparecen aquí se resumen como `.ok`.
    ///
    /// LA REGLA QUE DECIDE QUIÉN ENTRA, porque esta tabla ya costó una rama en este proyecto:
    /// **ningún texto escrito para el modelo llega a la pantalla del usuario**. Entra el DATO
    /// que el usuario pidió y sobre cuyo significado no cabe duda (un host, un recuento, una
    /// hora); no entra el `message`, que está redactado en segunda persona y con instrucciones
    /// para el modelo.
    ///
    /// `get_current_time` → `.localTime`: EL DEFECTO QUE ARREGLA. La herramienta empezó a hablar
    /// `status` —antes devolvía la fecha a pelo y la fila la pintaba con CRUZ ROJA, porque lo
    /// que no es un objeto JSON cae en la rama de fallo— pero no tenía entrada aquí, así que
    /// caía en `case nil`: el usuario preguntaba qué hora es y leía «listo». `local_time` es el
    /// dato que pidió, formateado por `DateFormatter` con el idioma y el formato del sistema.
    /// `get_device_status` → `.battery`: EL SEGUNDO CASO DEL MISMO DEFECTO QUE `get_current_time`.
    /// El usuario pregunta cuánta batería le queda y la fila le contesta «listo». Un porcentaje
    /// de batería cumple los dos lados de la regla de arriba: es el dato que pidió, y sobre su
    /// significado no cabe ninguna duda. Lo que NO entra es el `summary` («Tu iPhone tiene 73%
    /// de batería (sin cargar). Carga baja, te recomiendo conectar tu iPhone pronto.»), que está
    /// redactado para el modelo.
    private nonisolated enum Kind { case host, lines, valueOrCount, chars, count, localTime, battery }
    private nonisolated static let table: [String: Kind] = [
        "browser_open": .host,
        "browser_snapshot": .lines,
        "browser_get": .valueOrCount,
        "read_webpage": .chars,
        "web_search": .count,
        "get_current_time": .localTime,
        "get_device_status": .battery,
    ]

    public nonisolated static func summarize(toolName: String, resultJSON: String) -> ToolRowSummary {
        guard let data = resultJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            let t = resultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(clip(t.isEmpty ? "resultado vacío o ilegible" : t))
        }
        let status = obj["status"] as? String
        // UN CIERRE RECHAZADO POR EL CANDADO NO ES UN FALLO Y VA ANTES QUE LA RAMA DE FALLO.
        // Ver `cierreRechazadoText`. La excepcion es de un PAR (herramienta, estado): un
        // `browser_open` rechazado sigue siendo un fallo —el usuario no vio la pagina que
        // pidio— y un `browser_close` con `error` tambien.
        if toolName == BrowserCloseTool.name, status == "refused" {
            return .value(cierreRechazadoText)
        }
        if let status, failureStatuses.contains(status) || status.hasPrefix("invalid_") {
            // LA FRASE DE LA APP, NO EL `message` DE LA HERRAMIENTA. Ver `fraseDeFallo(status:)`
            // para el caso medido: el `message` esta escrito para el MODELO, y lo que llegaba a
            // la pantalla del usuario eran sus instrucciones en segunda persona. El motivo
            // entero sigue en el detalle de la fila y sigue viajando entero al modelo.
            return .failure(fraseDeFallo(status: status))
        }
        if let status, needsYouStatuses.contains(status) { return .needsYou }
        // «SE ABRIÓ, PERO NO ES LO QUE PEDISTE»: ni fallo ni «listo». Ver
        // `frasesDeEstadoAMedias`. Va DESPUÉS de los dos censos globales, que siguen teniendo
        // prioridad: un par que alguien metiera aquí y que además fuera un fallo censado se
        // seguiría pintando en rojo, que es la dirección segura.
        if let status, let frase = fraseDeEstadoAMedias(toolName: toolName, status: status) {
            return .value(frase)
        }
        switch table[toolName] {
        case .host:
            if let s = obj["url"] as? String, let host = URL(string: s)?.host { return .value(host) }
            return .ok
        case .lines:
            guard let s = obj["snapshot"] as? String else { return .ok }
            let n = s.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
            return .count(n, "objetos")
        case .valueOrCount:
            // Forma real, BrowserInspectionTools.swift (`browser_get`, rama
            // `what == "count"`, ~l.142): {"status":"success","what":"count","value":<Int>}.
            // El número va en `value` como Int; el resto de `what` lo trae como String.
            if let n = obj["value"] as? Int { return .count(n, "elementos") }
            if let v = obj["value"] as? String { return .value(v) }
            return .ok
        case .chars:
            guard let s = obj["content"] as? String else { return .ok }
            return .count(s.count, "caracteres")
        case .count:
            guard let n = obj["count"] as? Int else { return .ok }
            return .count(n, "resultados")
        case .localTime:
            // Forma real, CurrentTimeTool.swift: {"status":"success","local_time":"…",
            // "message":"Ahora son las …"}. Se pinta `local_time` —el dato— y NUNCA el
            // `message`, que está escrito para el modelo. Sin el dato se cae a «listo», que
            // dice menos pero no inventa ninguna hora.
            guard let s = obj["local_time"] as? String, !s.isEmpty else { return .ok }
            return .value(clip(s))
        case .battery:
            // Forma real, GetDeviceStatusTool.swift: {"status":"success","battery_percent":73,
            // "battery_level_known":true,…,"summary":"Tu iPhone tiene 73% de batería (…)"}. Se
            // pinta `battery_percent` —el dato— y NUNCA el `summary`, que está escrito para el
            // modelo. Cuando el sistema no ha reportado el nivel la clave NO viene (el propio
            // `run` la omite a propósito: ver `DeviceStatusHonestyTests`, defecto 9, «la batería
            // desconocida no se convierte en 100%»), y entonces la fila cae a «listo», que dice
            // menos pero no inventa ningún porcentaje.
            guard let n = obj["battery_percent"] as? Int else { return .ok }
            return .value("\(n)%")
        case nil:
            // Herramienta sin dato propio: «listo». El `message` NO se enseña: está
            // escrito para el modelo, no para el usuario; quien quiera el detalle
            // abre la fila.
            return .ok
        }
    }

    /// Recorte único de todo texto de una línea de resumen: `messageLimit`
    /// caracteres y «…» si se pasa.
    private nonisolated static func clip(_ s: String) -> String {
        s.count > messageLimit ? String(s.prefix(messageLimit)) + "…" : s
    }

    /// Texto que se ve al abrir la fila, recortado a `detailLimit`.
    public nonisolated static func detail(resultJSON: String) -> String {
        guard resultJSON.count > detailLimit else { return resultJSON }
        return String(resultJSON.prefix(detailLimit - 1)) + "…"
    }

    // MARK: - Vista

    private var summary: ToolRowSummary? {
        guard let name = entry.toolName, let detail = entry.toolDetail else { return nil }
        return Self.summarize(toolName: name, resultJSON: detail)
    }

    private var summaryText: String {
        switch summary {
        case nil: return "…"
        case .ok: return "listo"
        case .value(let v): return v
        case .count(let n, let what): return "\(n) \(what)"
        case .failure(let m): return m
        case .needsYou: return Self.needsYouText
        }
    }

    private var isFailure: Bool {
        if case .failure = summary { return true }
        return false
    }

    private var needsYou: Bool { summary == .needsYou }

    private var statusIcon: String {
        if summary == nil { return "ellipsis.circle" }
        if isFailure { return "xmark.circle.fill" }
        if needsYou { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        isFailure ? .red : (needsYou ? .orange : .secondary)
    }

    public var body: some View {
        let hasDetail = entry.toolDetail != nil
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    guard hasDetail else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { entry.isToolExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(entry.toolName ?? "tool").font(.caption.monospaced())
                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                            .lineLimit(entry.isToolExpanded ? nil : 2)
                        if hasDetail {
                            Image(systemName: entry.isToolExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                if entry.isToolExpanded, let d = entry.toolDetail {
                    Text(Self.detail(resultJSON: d))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }
}
