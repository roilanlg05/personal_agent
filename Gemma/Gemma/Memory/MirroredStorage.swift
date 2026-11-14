import Foundation

// MARK: - Vocabulario

/// Los `kind` con los que la app guarda en el servicio de memoria lo que antes solo
/// vivía en el contenedor del dispositivo.
///
/// Están todos aquí y en ningún otro sitio. El servidor no valida el `kind` (es una
/// cadena libre en la tabla `node`), así que un literal mal escrito en una herramienta
/// no daría error: produciría registros huérfanos que nada vuelve a encontrar.
///
/// `place` a secas no se usa a propósito. La consolidación ya crea nodos `place`
/// extraídos de la conversación, y el dedup del servidor fusiona nodos del mismo
/// `kind`: un pin con coordenadas fusionado con un "place" del modelo perdería las
/// coordenadas, porque al fusionar gana el `extra` del nodo que ya existía.
public enum MirrorKind {
    public static let note = "note"
    public static let shortcut = "shortcut"
    public static let contactAlias = "contact_alias"
    public static let place = "place_pin"
    public static let alarm = "alarm"
    public static let timer = "timer"
    public static let reminder = "reminder_pin"

    /// Todos los kinds espejados, para recorrerlos sin olvidarse de ninguno.
    public static let all: [String] = [note, shortcut, contactAlias, place, alarm, timer, reminder]
}

/// Un registro de un almacén local, en la forma mínima que necesita el servidor.
///
/// `payload` es el registro completo serializado como JSON (la nota entera, el lugar
/// entero...). `label` y `body` son solo para que el nodo se lea en el inspector del
/// grafo; la verdad del registro está siempre en `payload`.
public struct MirrorRecord: Sendable, Equatable {
    /// Identidad estable del registro dentro de su almacén. Donde hay una clave natural
    /// (el nombre normalizado de un atajo, el parentesco de un alias) se usa esa, para
    /// que dos dispositivos que aprendan lo mismo converjan en un solo nodo. Donde no la
    /// hay (notas, alarmas) es el UUID local.
    public let recordId: String
    public let label: String
    public let body: String
    public let payload: String
    public let updatedAt: Double

    public init(recordId: String, label: String, body: String, payload: String,
                updatedAt: Double = Date().timeIntervalSince1970) {
        self.recordId = recordId
        self.label = label
        self.body = body
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

// MARK: - Sobre (lo que viaja en `extra`)

/// Lo que se guarda en el campo `extra` del nodo del servidor.
///
/// `date` no es una fecha: es la clave que impide que el servidor fusione dos registros
/// distintos. `POST /v1/memory/save` pasa por `upsertMergingSemantic`, que fusiona el
/// nodo entrante con el nodo más parecido del mismo `kind` (distancia coseno ≤ 0,2 sobre
/// el `label`, o misma clave de dedup textual). Dos notas tituladas parecido acabarían
/// siendo una sola, y al fusionar NO se actualizan `body` ni `extra`: la segunda nota
/// se perdería en silencio. La única puerta de escape que ofrece el servidor es
/// `isSameOccurrence`, que rechaza la fusión cuando ambos nodos llevan un `extra.date`
/// distinto. Por eso aquí va una cadena única y estable por registro.
struct MirrorEnvelope: Codable, Sendable {
    var date: String
    var mirror: Box

    struct Box: Codable, Sendable {
        /// Versión del sobre. Un sobre de versión desconocida se ignora al hidratar en
        /// lugar de decodificarse a medias.
        var v: Int
        /// El `kind` espejado al que pertenece el registro. Se guarda aquí además de en
        /// el `kind` del nodo porque la fase `curate` de la consolidación renombra los
        /// kinds que no están en su vocabulario estándar: si algún día convierte `note`
        /// en `fact`, este campo sigue diciendo de qué almacén salió el registro.
        var store: String
        var recordId: String
        var updatedAt: Double
        var payload: String
        /// Etiqueta y cuerpo con los que se creó el nodo. Se repiten aquí porque al
        /// hidratar hay que poder reconstruir el registro entero (para renovarlo o para
        /// volver a subirlo) y el servidor puede haber reforzado el nodo por su cuenta.
        var label: String?
        var body: String?
        /// Qué dispositivo escribió esta versión. Solo informativo.
        var device: String?
    }

    static let version = 1

    static func dateKey(kind: String, recordId: String) -> String {
        "\(kind)#\(recordId)"
    }

    init(kind: String, record: MirrorRecord, device: String?) {
        self.date = MirrorEnvelope.dateKey(kind: kind, recordId: record.recordId)
        self.mirror = Box(v: MirrorEnvelope.version, store: kind, recordId: record.recordId,
                          updatedAt: record.updatedAt, payload: record.payload,
                          label: record.label, body: record.body, device: device)
    }

    /// El registro tal como se subió.
    func record() -> MirrorRecord {
        MirrorRecord(recordId: mirror.recordId, label: mirror.label ?? mirror.recordId,
                     body: mirror.body ?? "", payload: mirror.payload, updatedAt: mirror.updatedAt)
    }

    func json() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func from(_ extra: String?) -> MirrorEnvelope? {
        guard let extra, let data = extra.data(using: .utf8),
              let env = try? JSONDecoder().decode(MirrorEnvelope.self, from: data),
              env.mirror.v == MirrorEnvelope.version,
              !env.mirror.recordId.isEmpty, !env.mirror.store.isEmpty else { return nil }
        return env
    }
}

/// Codificación de los registros que viajan dentro del sobre.
///
/// Fija una estrategia de fechas propia: los almacenes locales no coinciden entre sí
/// (las notas guardan las fechas como número, los lugares como ISO-8601), y el formato
/// del espejo tiene que ser estable aunque mañana cambie el del fichero local.
public enum MirrorCodec {
    public static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode<T: Decodable>(_ json: String, as type: T.Type) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

// MARK: - Cola de pendientes

/// Una subida o un borrado todavía sin hacer.
public struct MirrorOp: Codable, Sendable, Equatable {
    public enum Verb: String, Codable, Sendable { case upsert, delete }

    public var verb: Verb
    public var kind: String
    public var recordId: String
    public var label: String
    public var body: String
    public var payload: String
    public var updatedAt: Double
    /// Cuándo se encoló. Sirve para subir en orden y para no borrar de la cola una
    /// escritura posterior a la que se acaba de subir.
    public var enqueuedAt: Double

    var key: String { "\(kind)/\(recordId)" }

    func record() -> MirrorRecord {
        MirrorRecord(recordId: recordId, label: label, body: body, payload: payload, updatedAt: updatedAt)
    }
}

/// La cola durable de lo que falta subir, más el mapa de qué nodo del servidor
/// corresponde a cada registro local.
///
/// Es el corazón de la propiedad "escribir nunca falla por estar sin red": guardar una
/// nota escribe en el almacén local y encola una operación, las dos cosas en memoria y
/// disco local, sin tocar la red. Subir es asunto de `MirrorSyncer`, después y cuando se
/// pueda.
///
/// La cola es síncrona y con cerrojo a propósito: la llaman almacenes que tienen que
/// seguir respondiendo al instante en mitad de un turno de conversación.
public final class MirrorOutbox: @unchecked Sendable {

    /// Cola única de la app. Los almacenes compartidos (`NoteStore.shared` y compañía)
    /// escriben aquí; los almacenes que se construyen en los tests reciben la suya, para
    /// no ensuciar esta.
    public static let shared = MirrorOutbox(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let opsKey = "gemma.mirror.outbox.v1"
    private let idsKey = "gemma.mirror.serverids.v1"

    private var ops: [MirrorOp]
    private var serverIds: [String: String]
    private var enqueueHook: (@Sendable () -> Void)?
    private var lastUploadFailed = false

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: opsKey),
           let decoded = try? JSONDecoder().decode([MirrorOp].self, from: data) {
            self.ops = decoded
        } else {
            self.ops = []
        }
        self.serverIds = (defaults.dictionary(forKey: idsKey) as? [String: String]) ?? [:]
    }

    /// Qué hacer en cuanto algo entra en la cola. `MirrorSyncer` instala aquí un intento
    /// de subida inmediata, para que lo normal (con red) sea que la cola esté vacía.
    public func setEnqueueHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        enqueueHook = hook
        lock.unlock()
    }

    public func enqueueUpsert(kind: String, record: MirrorRecord) {
        enqueue(MirrorOp(verb: .upsert, kind: kind, recordId: record.recordId,
                         label: record.label, body: record.body, payload: record.payload,
                         updatedAt: record.updatedAt, enqueuedAt: Date().timeIntervalSince1970))
    }

    public func enqueueDelete(kind: String, recordId: String, label: String) {
        enqueue(MirrorOp(verb: .delete, kind: kind, recordId: recordId, label: label,
                         body: "", payload: "", updatedAt: Date().timeIntervalSince1970,
                         enqueuedAt: Date().timeIntervalSince1970))
    }

    /// Encola una operación. Si ya había una para el mismo registro, la sustituye.
    ///
    /// Sustituir y no acumular es lo que garantiza que nada se duplique al subirse: diez
    /// ediciones de la misma nota sin red son una sola subida, y un borrado posterior
    /// reemplaza a la subida que ya no hace falta.
    public func enqueue(_ op: MirrorOp) {
        lock.lock()
        ops.removeAll { $0.key == op.key }
        ops.append(op)
        persistOpsLocked()
        let hook = enqueueHook
        lock.unlock()
        hook?()
    }

    public func pending() -> [MirrorOp] {
        lock.lock()
        defer { lock.unlock() }
        return ops.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    public func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ops.count
    }

    /// Si el último intento de subida se quedó sin llegar al servidor.
    ///
    /// Separa "encolado y de camino" de "encolado y sin poder subir". Sin esa
    /// distinción, una herramienta tendría que decir "pendiente de subir" en todas las
    /// respuestas, porque la subida es asíncrona y nunca ha terminado cuando la
    /// herramienta contesta; y un aviso que sale siempre deja de ser información.
    public func lastUploadDidFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastUploadFailed
    }

    func noteUploadOutcome(failed: Bool) {
        lock.lock()
        lastUploadFailed = failed
        lock.unlock()
    }

    public func isPending(kind: String, recordId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ops.contains { $0.kind == kind && $0.recordId == recordId }
    }

    /// Marca una operación como hecha. Solo la quita si nadie la ha sustituido mientras
    /// se subía: si el usuario editó la nota durante la petición, la operación nueva
    /// tiene otro `enqueuedAt` y se queda para la vuelta siguiente.
    public func resolve(_ op: MirrorOp) {
        lock.lock()
        ops.removeAll { $0.key == op.key && $0.enqueuedAt == op.enqueuedAt }
        persistOpsLocked()
        lock.unlock()
    }

    // MARK: mapa registro local → nodo del servidor

    public func serverId(kind: String, recordId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return serverIds["\(kind)/\(recordId)"]
    }

    public func setServerId(_ id: String, kind: String, recordId: String) {
        lock.lock()
        serverIds["\(kind)/\(recordId)"] = id
        defaults.set(serverIds, forKey: idsKey)
        lock.unlock()
    }

    public func clearServerId(kind: String, recordId: String) {
        lock.lock()
        serverIds.removeValue(forKey: "\(kind)/\(recordId)")
        defaults.set(serverIds, forKey: idsKey)
        lock.unlock()
    }

    private func persistOpsLocked() {
        if let data = try? JSONEncoder().encode(ops) {
            defaults.set(data, forKey: opsKey)
        }
    }
}

// MARK: - Almacenes espejados

/// Lo que tiene que saber hacer un almacén local para que su contenido viva en el
/// servidor: decir qué tiene y aceptar lo que venga de allí.
public protocol MirroredStore: Sendable {
    var mirrorKind: String { get }
    /// Todo lo que hay ahora mismo en la caché local.
    func mirrorRecords() async -> [MirrorRecord]
    /// Sustituye el contenido local por este. Lo llama `MirrorSyncer` con el conjunto ya
    /// resuelto (servidor + lo que aún está pendiente de subir), nunca con media verdad.
    func applyMirror(_ records: [MirrorRecord]) async
}

// MARK: - Acceso remoto

/// Una fila del servidor, en lo poco que el espejo necesita de ella.
struct MirrorRow: Sendable {
    let id: String
    let extra: String?
    /// Cuándo fue la última vez que el servidor "vio" el nodo. Se usa para renovarlo
    /// antes de que la purga por decaimiento lo alcance.
    let lastSeenAt: Double?
}

/// Lo que el espejo usa del servicio de memoria. Existe para poder probar el espejo sin
/// servidor: `MemoryClient` es una clase concreta y no se puede fingir.
@MainActor
protocol MirrorBackend: AnyObject {
    /// Crea un nodo y devuelve su id en el servidor.
    func mirrorSave(kind: String, label: String, body: String, extra: String) async throws -> String
    /// Página de nodos vivos, de los más recientes a los más viejos.
    func mirrorList(limit: Int, offset: Int) async throws -> (rows: [MirrorRow], total: Int)
    func mirrorForget(id: String) async throws
}

extension MemoryClient: MirrorBackend {
    func mirrorSave(kind: String, label: String, body: String, extra: String) async throws -> String {
        // `layer: "episodic"` no es decorativo. Con la capa por omisión (`daily`) el
        // nodo nace con salience 3 y decaimiento de 5 días, y la purga de la
        // consolidación lo borraría a las tres semanas de no mencionarlo: el servidor
        // se comería las notas del usuario. `identity` no decae nunca, pero entra en
        // `coreMemories`, el bloque de 6 líneas que se inyecta en todos los prompts, y
        // cincuenta notas dejarían fuera los hechos de identidad de verdad. `episodic`
        // es la única capa que no decae en menos de un año y no entra en ese bloque;
        // `MirrorSyncer` renueva los nodos mucho antes de que ese año se cumpla.
        let result = try await save(kind: kind, label: label, body: body, extra: extra,
                                   sourceRef: nil, layer: "episodic")
        return result.id
    }

    func mirrorList(limit: Int, offset: Int) async throws -> (rows: [MirrorRow], total: Int) {
        let listed = try await nodes(limit: limit, offset: offset, kind: nil)
        return (listed.nodes.map { MirrorRow(id: $0.id, extra: $0.extra, lastSeenAt: $0.lastSeenAt) },
                listed.total)
    }

    func mirrorForget(id: String) async throws {
        // Siempre por id, nunca por etiqueta: `forgetByLabel` del servidor borra todo
        // nodo cuya etiqueta o cuyo cuerpo CONTENGA el texto buscado, así que borrar la
        // nota "casa" se llevaría por delante media memoria.
        _ = try await forget(label: nil, id: id)
    }
}

// MARK: - El sincronizador

/// Sube lo pendiente y trae lo que hay en el servidor.
///
/// El reparto de papeles, que es lo que hace que las tres propiedades se cumplan a la
/// vez:
///
/// 1. **El servidor es la verdad.** Al arrancar, `hydrate()` sustituye la caché local
///    por lo que hay en el servidor, así que una reinstalación o un teléfono nuevo
///    recuperan todo. Lo único que sobrevive a eso es lo que aún está pendiente de
///    subir, que es más nuevo por definición.
/// 2. **Escribir nunca falla por estar sin red.** Los almacenes escriben en local y
///    encolan; subir es asunto de `flush()`, que reintenta cuando vuelve la red.
/// 3. **Leer sigue siendo inmediato.** Nadie lee del servidor en mitad de un turno: las
///    herramientas leen la caché local, que ya está hidratada.
@MainActor
final class MirrorSyncer {

    static let shared = MirrorSyncer()

    struct FlushReport: Sendable, Equatable {
        var uploaded = 0
        var deleted = 0
        var stillPending = 0
        /// `true` cuando se paró por no poder hablar con el servidor.
        var offline = false
    }

    struct HydrateReport: Sendable, Equatable {
        /// Cuántos registros quedaron en cada almacén.
        var applied: [String: Int] = [:]
        /// Nodos duplicados del mismo registro que se limpiaron en el servidor.
        var duplicatesRemoved = 0
        /// Registros locales que nunca se habían subido y se encolaron.
        var adopted = 0
        /// `false` cuando no se pudo leer el servidor; en ese caso no se tocó nada local.
        var ok = false
    }

    /// A los cuántos segundos sin que el servidor "vea" un nodo se lo renueva.
    ///
    /// Un nodo `episodic` con salience 3 cae por debajo del suelo de olvido (0,05) a los
    /// ~368 días. Renovar a los 90 deja margen de sobra incluso si el usuario no abre la
    /// app en meses.
    static let renewAfterSeconds: Double = 90 * 24 * 3600

    private let outbox: MirrorOutbox
    private let defaults: UserDefaults
    private let backendProvider: @MainActor () async -> (any MirrorBackend)?
    private let deviceName: String?
    private let migratedKey = "gemma.mirror.migrated.v1"

    private var stores: [String: any MirroredStore] = [:]
    private var flushing = false
    private var bootstrapping = false
    /// Para qué servidor ya se hizo el arranque completo en esta ejecución.
    private var bootstrappedFor: String?

    init(outbox: MirrorOutbox = .shared,
         defaults: UserDefaults = .standard,
         deviceName: String? = MirrorSyncer.currentDeviceName(),
         backendProvider: @MainActor @escaping () async -> (any MirrorBackend)? = { MemoryToolbox.shared.memory as (any MirrorBackend)? }) {
        self.outbox = outbox
        self.defaults = defaults
        self.deviceName = deviceName
        self.backendProvider = backendProvider
    }

    nonisolated static func currentDeviceName() -> String? {
        ProcessInfo.processInfo.hostName
    }

    /// Da de alta un almacén. Idempotente: registrar dos veces el mismo `kind` deja uno.
    func register(_ store: any MirroredStore) {
        stores[store.mirrorKind] = store
    }

    /// Da de alta los almacenes compartidos de la app.
    func registerDefaultStores() {
        register(NoteStore.shared)
        register(ShortcutRegistry.shared)
        register(ContactAliasStore.shared)
        register(PlaceStore.shared)
        register(AlarmMirror(persistence: .shared))
        register(TimerMirror(persistence: .shared))
    }

    /// Lo que se llama cada vez que la app (re)construye el cliente de memoria, que es
    /// una vez por turno de conversación.
    ///
    /// Hidratar lee todos los nodos del servidor, así que hacerlo en cada turno sería
    /// caro y además inútil: solo cambia la verdad del servidor cuando otro dispositivo
    /// escribe. Se hidrata una vez por ejecución y por servidor; subir lo pendiente, en
    /// cambio, se intenta siempre, porque no cuesta nada cuando la cola está vacía.
    func start(serverKey: String) {
        registerDefaultStores()
        if bootstrappedFor == serverKey {
            Task { await self.flush() }
        } else {
            Task {
                // Solo se da por hidratado cuando se consiguió leer el servidor. Si la
                // app arrancó sin VPN, el turno siguiente vuelve a intentarlo; darlo por
                // hecho dejaría el dispositivo sin recuperar nada hasta el arranque
                // siguiente, que es justo el caso de una reinstalación.
                let report = await self.bootstrap()
                if report.ok { self.bootstrappedFor = serverKey }
            }
        }
    }

    /// Arranque completo: encolar lo que ya había en local, subirlo y traer el servidor.
    ///
    /// Es seguro llamarlo más de una vez; si ya hay un arranque en curso, no hace nada.
    @discardableResult
    func bootstrap() async -> HydrateReport {
        if bootstrapping { return HydrateReport() }
        bootstrapping = true
        defer { bootstrapping = false }

        outbox.setEnqueueHook { [weak self] in
            Task { @MainActor in await self?.flush() }
        }
        await migrateIfNeeded()
        await flush()
        let report = await hydrate()
        // Lo que la hidratación adoptó o marcó para renovar se sube ahora, no al
        // arranque siguiente.
        if report.ok, outbox.pendingCount() > 0 { await flush() }
        return report
    }

    /// Encola todo lo que haya en los almacenes locales, una sola vez en la vida de la
    /// instalación.
    ///
    /// Es lo que se lleva al servidor lo que el usuario ya tenía cuando este código se
    /// estrenó. La bandera evita que abrir la app cinco veces encole cinco veces; la
    /// sustitución por registro de la cola lo evitaría igual, pero así no se recorre
    /// todo en cada arranque.
    func migrateIfNeeded() async {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        for (kind, store) in stores {
            for record in await store.mirrorRecords() {
                outbox.enqueueUpsert(kind: kind, record: record)
            }
        }
    }

    /// Sube lo pendiente. Nunca lanza: sin red deja la cola como estaba y lo dice en el
    /// informe.
    @discardableResult
    func flush() async -> FlushReport {
        if flushing { return FlushReport(stillPending: outbox.pendingCount()) }
        flushing = true
        defer { flushing = false }

        var report = FlushReport()
        guard let backend = await backendProvider() else {
            report.stillPending = outbox.pendingCount()
            report.offline = true
            outbox.noteUploadOutcome(failed: true)
            return report
        }

        // Índice del servidor por registro, construido solo si hace falta (una
        // operación sin id conocido) y reutilizado para todo el vaciado.
        var index: [String: [String]]?

        for op in outbox.pending() {
            var knownIds: [String] = []
            if let id = outbox.serverId(kind: op.kind, recordId: op.recordId) {
                knownIds = [id]
            } else {
                if index == nil {
                    guard let built = try? await serverIndex(backend) else {
                        report.offline = true
                        break
                    }
                    index = built
                }
                knownIds = index?["\(op.kind)/\(op.recordId)"] ?? []
            }

            do {
                // Un upsert borra primero el nodo anterior del registro y vuelve a
                // guardarlo. No se reenvía sin más porque el `save` del servidor, al
                // encontrar el nodo que ya existe, lo refuerza pero NO actualiza su
                // `body` ni su `extra`: la edición no llegaría nunca.
                for id in knownIds {
                    try await backend.mirrorForget(id: id)
                    outbox.clearServerId(kind: op.kind, recordId: op.recordId)
                }
                switch op.verb {
                case .upsert:
                    let envelope = MirrorEnvelope(kind: op.kind, record: op.record(), device: deviceName)
                    guard let extra = envelope.json() else { outbox.resolve(op); continue }
                    let newId = try await backend.mirrorSave(kind: op.kind, label: op.label,
                                                             body: op.body, extra: extra)
                    outbox.setServerId(newId, kind: op.kind, recordId: op.recordId)
                    index?["\(op.kind)/\(op.recordId)"] = [newId]
                    report.uploaded += 1
                case .delete:
                    index?["\(op.kind)/\(op.recordId)"] = []
                    report.deleted += 1
                }
                outbox.resolve(op)
            } catch {
                // Sin red o con el servidor caído: la operación se queda para después.
                // No se intenta la siguiente, porque fallaría igual.
                report.offline = true
                break
            }
        }

        report.stillPending = outbox.pendingCount()
        outbox.noteUploadOutcome(failed: report.offline)
        return report
    }

    /// Trae del servidor el contenido de todos los almacenes registrados.
    ///
    /// Si el servidor no contesta, no toca nada: la caché local sigue siendo lo último
    /// que se sabía, que es mejor que vaciarla.
    @discardableResult
    func hydrate() async -> HydrateReport {
        var report = HydrateReport()
        guard let backend = await backendProvider() else { return report }
        guard let rows = try? await serverRows(backend) else { return report }

        // Agrupar las filas del servidor por registro.
        var byRecord: [String: [(row: MirrorRow, env: MirrorEnvelope)]] = [:]
        for row in rows {
            guard let env = MirrorEnvelope.from(row.extra) else { continue }
            byRecord["\(env.mirror.store)/\(env.mirror.recordId)", default: []].append((row, env))
        }

        let now = Date().timeIntervalSince1970
        var remote: [String: [String: MirrorRecord]] = [:]   // kind → recordId → registro
        var needsRenewal: Set<String> = []

        for (key, group) in byRecord {
            // Un registro con varios nodos: gana el más nuevo y los demás se borran del
            // servidor. Pasa si una subida llegó pero la respuesta no, y la vuelta
            // siguiente volvió a guardar.
            let sorted = group.sorted { $0.env.mirror.updatedAt > $1.env.mirror.updatedAt }
            guard let winner = sorted.first else { continue }
            for loser in sorted.dropFirst() {
                try? await backend.mirrorForget(id: loser.row.id)
                report.duplicatesRemoved += 1
            }
            let kind = winner.env.mirror.store
            let recordId = winner.env.mirror.recordId
            remote[kind, default: [:]][recordId] = winner.env.record()
            outbox.setServerId(winner.row.id, kind: kind, recordId: recordId)
            if let seen = winner.row.lastSeenAt, now - seen > MirrorSyncer.renewAfterSeconds {
                needsRenewal.insert(key)
            }
        }

        let pending = outbox.pending()

        for (kind, store) in stores {
            var desired = remote[kind] ?? [:]

            // Lo que hay en local y no está en el servidor. Si alguna vez se subió
            // (hay id del servidor apuntado), es que otro dispositivo lo borró: se
            // borra aquí también, que es lo que el usuario pidió. Si nunca se subió, es
            // que este dispositivo lo creó sin red o antes de que existiera el espejo:
            // se queda y se encola.
            let localRecords = await store.mirrorRecords()
            for record in localRecords where desired[record.recordId] == nil {
                if outbox.serverId(kind: kind, recordId: record.recordId) != nil { continue }
                desired[record.recordId] = record
                if !outbox.isPending(kind: kind, recordId: record.recordId) {
                    outbox.enqueueUpsert(kind: kind, record: record)
                    report.adopted += 1
                }
            }

            // Lo pendiente de subir es más nuevo que el servidor por definición.
            for op in pending where op.kind == kind {
                switch op.verb {
                case .upsert: desired[op.recordId] = op.record()
                case .delete: desired.removeValue(forKey: op.recordId)
                }
            }

            // Renovar los nodos que la purga del servidor tiene a tiro. Un upsert los
            // borra y los vuelve a crear con el reloj a cero.
            for recordId in desired.keys where needsRenewal.contains("\(kind)/\(recordId)") {
                if let record = desired[recordId], !outbox.isPending(kind: kind, recordId: recordId) {
                    outbox.enqueueUpsert(kind: kind, record: record)
                }
            }

            let records = Array(desired.values)
            await store.applyMirror(records)
            report.applied[kind] = records.count
        }

        report.ok = true
        return report
    }

    // MARK: lectura paginada

    private func serverRows(_ backend: any MirrorBackend) async throws -> [MirrorRow] {
        var all: [MirrorRow] = []
        var offset = 0
        let page = 200
        while true {
            let result = try await backend.mirrorList(limit: page, offset: offset)
            all.append(contentsOf: result.rows)
            offset += page
            if result.rows.count < page || offset >= result.total || offset > 10_000 { break }
        }
        return all
    }

    private func serverIndex(_ backend: any MirrorBackend) async throws -> [String: [String]] {
        var index: [String: [String]] = [:]
        for row in try await serverRows(backend) {
            guard let env = MirrorEnvelope.from(row.extra) else { continue }
            index["\(env.mirror.store)/\(env.mirror.recordId)", default: []].append(row.id)
        }
        return index
    }
}

// MARK: - Estado para las herramientas

/// Lo que una herramienta puede decir sin mentir sobre dónde quedó lo que acaba de
/// guardar.
///
/// Devolver "guardado" cuando el registro está en una cola local y el servidor no lo ha
/// visto es media verdad, y el modelo repite al usuario lo que la herramienta dice como
/// si fuera un hecho. Así que se distingue.
public enum MirrorStatus {
    /// `"synced"` si el servidor ya lo tiene; `"queued"` si está en la cola y la subida
    /// va camino del servidor; `"pending_upload"` si el último intento no llegó.
    public static func describe(kind: String, recordId: String,
                               outbox: MirrorOutbox = .shared) -> String {
        guard outbox.isPending(kind: kind, recordId: recordId) else { return "synced" }
        return outbox.lastUploadDidFail() ? "pending_upload" : "queued"
    }

    /// Frase corta para el usuario, o `nil` si no hay nada que avisar.
    ///
    /// Solo avisa cuando de verdad hay algo que avisar: que la subida esté en marcha es
    /// lo normal y no merece una frase en cada respuesta.
    public static func note(kind: String, recordId: String,
                           outbox: MirrorOutbox = .shared) -> String? {
        guard describe(kind: kind, recordId: recordId, outbox: outbox) == "pending_upload" else { return nil }
        return "Guardado en este dispositivo; queda pendiente de subir a la memoria de Gemma en cuanto haya conexión."
    }
}
