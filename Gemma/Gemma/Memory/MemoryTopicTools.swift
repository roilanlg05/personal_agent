import Foundation

/// Las herramientas con las que el agente consulta la memoria por temas y justifica lo
/// que cree.
///
/// Estaban escritas en prosa libre en inglés (`"memory unavailable"`, `"no topics yet"`,
/// `"nothing remembered about X"`) y sin contrato `status`. Lo que estaba roto:
///
/// 1. **«No se pudo mirar» se decía igual que «no hay nada».** El `catch` de las tres
///    devolvía la misma frase que el camino sin memoria configurada, y
///    `recall_by_topic` contestaba `nothing remembered about "finanzas"` tanto si el tema
///    estaba vacío como si el servidor había fallado. El modelo le decía al usuario «no
///    tengo nada de ese tema» cuando la verdad era «no lo sé».
/// 2. **`recall_by_topic` prometía TODO y recortaba en silencio.** Su descripción le dice
///    al modelo que devuelve «EVERYTHING you remember about one topic» y el resultado se
///    cortaba con `.prefix(4000)` sin decirlo; `list_topics` hacía lo mismo con
///    `.prefix(2000)`. Una enumeración que se presenta como completa y no lo es miente
///    sobre lo que el usuario tiene guardado.
/// 3. **`why` no distinguía los tres casos que importan.** «No encontré esa creencia»,
///    «la tengo pero sin fuentes» y «no pude consultar» caían en frases que el modelo
///    podía resumir como un «porque sí». Justificar una creencia sin fuentes es
///    exactamente lo que `why` existe para no hacer.
enum MemoryQuerySupport {

    /// Cuando la memoria no está disponible. Es un fallo de infraestructura, no una
    /// memoria vacía: si esto dijera `empty` el modelo le contestaría al usuario que
    /// Gemma no recuerda nada de él.
    static func memoryUnavailable(_ action: String) -> String {
        ToolJSONOutput.object([
            "status": "memory_unavailable",
            "message": "La memoria de Gemma no está disponible ahora mismo, así que no se pudo \(action). Dile al usuario que NO pudiste consultar tu memoria — no que no recuerdes nada."
        ])
    }

    static func failed(_ action: String, _ error: Error) -> String {
        ToolJSONOutput.object([
            "status": "failed",
            "message": "No se pudo \(action): \(error.localizedDescription). Dile al usuario que no pudiste consultar tu memoria; NO le digas que no hay nada guardado."
        ])
    }

    static func missingField(_ name: String, _ what: String) -> String {
        ToolJSONOutput.object([
            "status": "missing_fields",
            "required": [name],
            "message": "Falta '\(name)': \(what)."
        ])
    }

    /// Techos de lo que cabe en la respuesta de un tool.
    ///
    /// Antes se recortaba por número de caracteres (`.prefix(4000)`), que parte una fila
    /// por la mitad y no deja rastro. Ahora se recorta por filas y el recorte se declara
    /// con `truncated`, `total` y un aviso, para que el modelo sepa que no vio todo.
    enum Caps {
        static let topics = 200
        static let memories = 150
        static let messages = 200
        static let facts = 60
        static let summaries = 20
        static let recentTurns = 12
    }

    static func row(_ node: MemoryClient.TopicNode) -> [String: Any] {
        ([
            "kind": node.kind,
            "label": node.label,
            "detail": node.body.isEmpty || node.body == node.label ? nil : node.body
        ] as [String: Any?]).compactMapValues { $0 }
    }

    /// Recorta a `cap` filas declarando el recorte. Devuelve las filas y el aviso.
    static func cap<T>(_ items: [T], to cap: Int, noun: String) -> (shown: [T], warning: String?) {
        guard items.count > cap else { return (items, nil) }
        return (Array(items.prefix(cap)),
                "Se muestran \(cap) de \(items.count) \(noun): la lista viene recortada, así que NO le digas al usuario que esto es todo.")
    }
}

/// list_topics — el inventario de temas sobre los que Gemma recuerda algo.
struct ListTopicsTool: AgentTool {
    static let name = "list_topics"
    static let description = """
    Enumera los temas sobre los que tienes recuerdos del usuario (para «¿de qué cosas \
    mías te acuerdas?», «¿qué sabes de mí?»). No lleva argumentos. Lee 'status': 'ok' = \
    los temas vienen en 'topics'; 'empty' = Gemma todavía no ha formado ningún tema \
    (dilo tal cual: la consolidación aún no ha agrupado nada, no que no sepas nada del \
    usuario); 'memory_unavailable' o 'failed' = NO se pudo consultar la memoria, que no \
    es lo mismo que no tener temas — dile que no pudiste mirar. Si viene 'truncated': \
    true, la lista está recortada y no es el inventario completo.
    """
    static let parameters: [AgentToolParam] = []

    func run(argsJSON: String) async -> String {
        if MemoryToolbox.turnScope != nil { return "A scoped topic index is unavailable." }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else {
                return MemoryQuerySupport.memoryUnavailable("consultar los temas")
            }
            do {
                let tags = try await mem.memoryTags()
                let (shown, warning) = MemoryQuerySupport.cap(tags, to: MemoryQuerySupport.Caps.topics, noun: "temas")
                return ToolJSONOutput.object([
                    "status": tags.isEmpty ? "empty" : "ok",
                    "topics": shown,
                    "count": shown.count,
                    "total": tags.count,
                    "truncated": warning != nil ? true : nil,
                    "warnings": warning.map { [$0] },
                    "message": tags.isEmpty
                        ? "Gemma todavía no ha agrupado ningún tema. Dile que aún no ha formado temas, no que no sepa nada de él."
                        : "\(tags.count) tema(s). Para ver todo lo de uno, llama a recall_by_topic con ese tema."
                ])
            } catch {
                return MemoryQuerySupport.failed("consultar los temas", error)
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// recall_by_topic — todo lo que Gemma recuerda de UN tema (filtrado por etiqueta).
struct RecallByTopicTool: AgentTool {
    static let name = "recall_by_topic"
    static let description = """
    Devuelve todo lo que recuerdas de un tema concreto («finanzas», «trabajo», «salud»), \
    no solo lo que ya tienes delante. Úsalo cuando el usuario pida todo lo que sabes de \
    un asunto. Lee 'status': 'ok' = lee 'context' si aparece. Si no, 'memories' y 'total' indican \
    cuántos hay en total; 'empty' = ese tema existe pero no tiene nada dentro; \
    'unknown_topic' = ese tema no está en la memoria, ofrécele list_topics para ver los \
    que sí hay en vez de afirmar que no sabes nada del asunto; 'memory_unavailable' o \
    'failed' = NO se pudo consultar, que no es lo mismo que no recordar nada. Si viene \
    'truncated': true, falta parte: dilo, no presentes la lista como completa.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "topic", type: .string, description: "The topic/theme to enumerate, e.g. \"finanzas\".", required: true),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let topic = ((obj["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return MemoryQuerySupport.missingField("topic", "el tema que hay que enumerar") }
        if let scope = MemoryToolbox.turnScope {
            return scope.isTyped ? await scope.lookup(topic) : "Scoped topic search unavailable."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: topic) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else {
                return MemoryQuerySupport.memoryUnavailable("consultar el tema «\(topic)»")
            }
            do {
                let r = try await mem.recallByTopic(topic: topic)
                // Etiqueta vacía = el servidor no supo resolver el tema a ninguna de las
                // que conoce. No es un tema vacío: es un tema que no existe, y el modelo
                // tiene que poder ofrecer los que sí hay.
                guard !r.tag.isEmpty else {
                    return ToolJSONOutput.object([
                        "status": "unknown_topic",
                        "requested": topic,
                        "message": "«\(topic)» no es un tema que Gemma tenga en su memoria. Llama a list_topics y ofrécele al usuario los que sí hay; no afirmes que no sabes nada de ese asunto."
                    ])
                }
                let (shown, warning) = MemoryQuerySupport.cap(
                    r.nodes, to: MemoryQuerySupport.Caps.memories, noun: "recuerdos"
                )
                return ToolJSONOutput.object([
                    "status": r.nodes.isEmpty ? "empty" : "ok",
                    "topic": r.tag,
                    "requested": topic,
                    "memories": shown.map { MemoryQuerySupport.row($0) },
                    "count": shown.count,
                    "total": r.nodes.count,
                    "truncated": warning != nil ? true : nil,
                    "warnings": warning.map { [$0] },
                    "message": r.nodes.isEmpty
                        ? "El tema «\(r.tag)» existe pero no tiene ningún recuerdo dentro."
                        : "\(r.nodes.count) recuerdo(s) sobre «\(r.tag)»."
                ])
            } catch {
                return MemoryQuerySupport.failed("consultar el tema «\(topic)»", error)
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// why — justifica una creencia recorriendo el grafo de procedencia hasta sus fuentes.
struct WhyTool: AgentTool {
    static let name = "why"
    static let description = """
    Explica POR QUÉ crees algo sobre el usuario, rastreándolo hasta los recuerdos de los \
    que sale. Úsalo cuando pregunte por qué piensas eso o en qué te basas. Pásale la \
    creencia. Lee 'status': 'ok' = lee 'context' como referencia o cita las fuentes exactas de 'sources'; \
    'no_sources' = tienes la creencia pero sin ningún recuerdo que la respalde — dile \
    exactamente eso y NO te inventes una razón; 'not_found' = no encontraste esa \
    creencia en tu memoria, dilo en vez de justificar algo que no crees; \
    'memory_unavailable' o 'failed' = no se pudo consultar la procedencia, que no es lo \
    mismo que no tenerla.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "claim", type: .string, description: "The belief/claim to justify, e.g. \"the user trades options\".", required: true),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let claim = ((obj["claim"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty else { return MemoryQuerySupport.missingField("claim", "la creencia que hay que justificar") }
        if let scope = MemoryToolbox.turnScope {
            return scope.isTyped ? await scope.lookup(claim) : "Scoped memory explanation unavailable."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: claim) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else {
                return MemoryQuerySupport.memoryUnavailable("rastrear de dónde sale esa creencia")
            }
            do {
                let r = try await mem.why(claim: claim)
                guard !r.insight.isEmpty else {
                    return ToolJSONOutput.object([
                        "status": "not_found",
                        "claim": claim,
                        "message": "Gemma no tiene esa creencia registrada, así que no hay nada que justificar. Dile al usuario que no cree eso (o que no lo tiene guardado); no construyas una razón."
                    ])
                }
                guard !r.sources.isEmpty else {
                    // El caso peligroso: la creencia existe y la tentación es rellenar el
                    // «porque» con cualquier cosa plausible.
                    return ToolJSONOutput.object([
                        "status": "no_sources",
                        "claim": claim,
                        "insight": r.insight,
                        "sources": [],
                        "message": "Gemma cree «\(r.insight)» pero no tiene ningún recuerdo guardado que lo respalde. Dile al usuario exactamente eso: que lo tiene anotado pero sin fuente. No te inventes la justificación."
                    ])
                }
                let (shown, warning) = MemoryQuerySupport.cap(
                    r.sources, to: MemoryQuerySupport.Caps.memories, noun: "fuentes"
                )
                return ToolJSONOutput.object([
                    "status": "ok",
                    "claim": claim,
                    "insight": r.insight,
                    "sources": shown.map { MemoryQuerySupport.row($0) },
                    "count": shown.count,
                    "total": r.sources.count,
                    "truncated": warning != nil ? true : nil,
                    "warnings": warning.map { [$0] },
                    "message": "Gemma cree «\(r.insight)» por \(r.sources.count) recuerdo(s). Cita los de 'sources'; no añadas razones que no estén ahí."
                ])
            } catch {
                return MemoryQuerySupport.failed("rastrear de dónde sale «\(claim)»", error)
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
