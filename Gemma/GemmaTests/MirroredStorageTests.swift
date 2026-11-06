import XCTest
@testable import Gemma

// MARK: - Doble del servicio de memoria

/// Servidor de memoria de mentira. `MemoryClient` es una clase concreta, así que el
/// espejo habla con `MirrorBackend` y aquí se finge.
@MainActor
final class FakeMirrorBackend: MirrorBackend {
    struct Stored {
        var id: String
        var kind: String
        var label: String
        var body: String
        var extra: String
        var lastSeenAt: Double
    }

    var stored: [Stored] = []
    /// Cuando está a `true`, toda petición falla como si no hubiera red.
    var offline = false
    /// Segundos que tarda cada petición, para probar que leer no espera a la red.
    var latency: Double = 0

    private(set) var saveCount = 0
    private(set) var forgotten: [String] = []
    private var counter = 0

    func mirrorSave(kind: String, label: String, body: String, extra: String) async throws -> String {
        try await gate()
        saveCount += 1
        counter += 1
        let id = "srv-\(counter)"
        stored.append(Stored(id: id, kind: kind, label: label, body: body, extra: extra,
                             lastSeenAt: Date().timeIntervalSince1970))
        return id
    }

    func mirrorList(limit: Int, offset: Int) async throws -> (rows: [MirrorRow], total: Int) {
        try await gate()
        let all = stored.map { MirrorRow(id: $0.id, extra: $0.extra, lastSeenAt: $0.lastSeenAt) }
        return (Array(all.dropFirst(offset).prefix(limit)), all.count)
    }

    func mirrorForget(id: String) async throws {
        try await gate()
        forgotten.append(id)
        stored.removeAll { $0.id == id }
    }

    /// Inserta una fila como si la hubiera escrito otro dispositivo.
    @discardableResult
    func seed(kind: String, record: MirrorRecord, lastSeenAt: Double = Date().timeIntervalSince1970) -> String {
        counter += 1
        let id = "seed-\(counter)"
        let extra = MirrorEnvelope(kind: kind, record: record, device: "otro").json() ?? ""
        stored.append(Stored(id: id, kind: kind, label: record.label, body: record.body,
                             extra: extra, lastSeenAt: lastSeenAt))
        return id
    }

    private func gate() async throws {
        if latency > 0 { try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if offline { throw URLError(.notConnectedToInternet) }
    }
}

// MARK: - Herramientas de prueba

private func freshDefaults(_ tag: String) -> UserDefaults {
    UserDefaults(suiteName: "gemma.tests.mirror.\(tag).\(UUID().uuidString)")!
}

@MainActor
private func makeSyncer(outbox: MirrorOutbox, defaults: UserDefaults,
                        backend: FakeMirrorBackend?) -> MirrorSyncer {
    MirrorSyncer(outbox: outbox, defaults: defaults, deviceName: "test",
                 backendProvider: { backend })
}

// MARK: - Las tres propiedades obligatorias

final class MirroredStorageTests: XCTestCase {

    // 1. Escribir nunca falla por estar sin red.

    @MainActor
    func test_guardarUnaNotaSinRedNoFallaYQuedaPendiente() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("offline"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        backend.offline = true
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("offline-s"), backend: backend)

        // La nota se guarda sin que la red intervenga.
        let saved = try await store.saveNote(GemmaNote(title: "Comprar pan", content: "en la esquina"))
        XCTAssertEqual(saved.title, "Comprar pan")
        let notesCount = await store.allNotes().count
        XCTAssertEqual(notesCount, 1)

        // Y queda apuntada para subirla.
        XCTAssertTrue(outbox.isPending(kind: MirrorKind.note, recordId: saved.id))

        let report = await syncer.flush()
        XCTAssertTrue(report.offline)
        XCTAssertEqual(report.uploaded, 0)
        XCTAssertEqual(outbox.pendingCount(), 1, "sin red la operación tiene que seguir en la cola")
        let notesCountTrasElIntento = await store.allNotes().count
        XCTAssertEqual(notesCountTrasElIntento, 1, "la nota sigue estando en el dispositivo")
    }

    @MainActor
    func test_loPendienteSeSubeCuandoVuelveLaRed_yNoSeDuplica() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("retry"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        backend.offline = true
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("retry-s"), backend: backend)

        _ = try await store.saveNote(GemmaNote(title: "Llamar a Marcos", content: "por la tarde"))
        await syncer.flush()
        XCTAssertEqual(backend.saveCount, 0)

        backend.offline = false
        let first = await syncer.flush()
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(backend.saveCount, 1)
        XCTAssertEqual(outbox.pendingCount(), 0)

        // Vaciar otra vez no vuelve a subir nada: la cola está vacía.
        let second = await syncer.flush()
        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(backend.saveCount, 1, "subir dos veces crearía un nodo duplicado")
    }

    // 2. El servidor es la verdad.

    @MainActor
    func test_hidratarTraeDelServidorLoQueElDispositivoNoTiene() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("hydrate"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let note = GemmaNote(title: "Receta de la abuela", content: "harina, huevo, azúcar")
        backend.seed(kind: MirrorKind.note, record: NoteStore.record(for: note))

        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("hydrate-s"), backend: backend)
        syncer.register(store)

        let notesCount = await store.allNotes().count
        XCTAssertEqual(notesCount, 0, "el dispositivo arranca vacío, como tras reinstalar")
        let report = await syncer.hydrate()
        XCTAssertTrue(report.ok)

        let notes = await store.allNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Receta de la abuela")
        XCTAssertEqual(notes.first?.content, "harina, huevo, azúcar")
    }

    @MainActor
    func test_siElServidorNoContestaNoSeTocaLaCacheLocal() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("nohydrate"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        _ = try await store.saveNote(GemmaNote(title: "Idea", content: "una idea"))

        let backend = FakeMirrorBackend()
        backend.offline = true
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("nohydrate-s"), backend: backend)
        syncer.register(store)

        let report = await syncer.hydrate()
        XCTAssertFalse(report.ok)
        let notesCount = await store.allNotes().count
        XCTAssertEqual(notesCount, 1, "vaciar la caché por no poder preguntar sería peor")
    }

    // 3. Leer sigue siendo inmediato.

    @MainActor
    func test_resolverUnAliasNoEsperaALaRed() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("read"))
        let aliases = ContactAliasStore(defaults: freshDefaults("read-d"), outbox: outbox)
        let backend = FakeMirrorBackend()
        backend.latency = 3   // el servidor tarda una eternidad
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("read-s"), backend: backend)

        aliases.setAlias(relationship: "mi jefe", contactTarget: "Carlos Pérez")
        let subiendo = Task { await syncer.flush() }

        let start = Date()
        let resolved = aliases.resolve(aliasOrName: "mi jefe")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(resolved, "Carlos Pérez")
        XCTAssertLessThan(elapsed, 0.2, "resolver un alias en mitad de un turno no puede esperar a la red")
        subiendo.cancel()
    }

    @MainActor
    func test_buscarNotasNoEsperaALaRed() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("readnotes"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        backend.latency = 3
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("readnotes-s"), backend: backend)

        _ = try await store.saveNote(GemmaNote(title: "Reunión del lunes", content: "con el equipo"))
        let subiendo = Task { await syncer.flush() }

        let start = Date()
        let found = await store.searchNotes(query: "reunion")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(found.count, 1, "busca sin acentos igual que antes")
        XCTAssertLessThan(elapsed, 0.2)
        subiendo.cancel()
    }
}

// MARK: - Actualizar, borrar y los casos de dos dispositivos

final class MirrorSyncBehaviourTests: XCTestCase {

    @MainActor
    func test_editarUnaNotaReemplazaElNodoEnVezDeDejarDos() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("update"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("update-s"), backend: backend)

        let note = GemmaNote(title: "Lista", content: "pan")
        _ = try await store.saveNote(note)
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)
        let firstId = backend.stored[0].id

        var edited = note
        edited.content = "pan y leche"
        edited.updatedAt = Date().addingTimeInterval(10)
        _ = try await store.saveNote(edited)
        await syncer.flush()

        XCTAssertEqual(backend.stored.count, 1, "la edición no puede dejar dos nodos del mismo registro")
        XCTAssertTrue(backend.forgotten.contains(firstId),
                      "el nodo viejo se borra: el save del servidor refuerza pero no actualiza body ni extra")
        let env = MirrorEnvelope.from(backend.stored[0].extra)
        let payload = env.flatMap { MirrorCodec.decode($0.mirror.payload, as: GemmaNote.self) }
        XCTAssertEqual(payload?.content, "pan y leche")
    }

    @MainActor
    func test_borrarUnaNotaLlegaAlServidorYNoReaparece() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("delete"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("delete-s"), backend: backend)
        syncer.register(store)

        let saved = try await store.saveNote(GemmaNote(title: "Borrable", content: "x"))
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)

        let didDelete = try await store.deleteNote(id: saved.id)
        XCTAssertTrue(didDelete)
        let report = await syncer.flush()
        XCTAssertEqual(report.deleted, 1)
        XCTAssertEqual(backend.stored.count, 0, "borrar en el dispositivo tiene que borrar en el servidor")

        await syncer.hydrate()
        let notesCount = await store.allNotes().count
        XCTAssertEqual(notesCount, 0, "la nota borrada no puede volver al hidratar")
    }

    @MainActor
    func test_borrarSinRedTambienLlegaAlServidorCuandoVuelve() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("deloff"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("deloff-s"), backend: backend)
        syncer.register(store)

        let saved = try await store.saveNote(GemmaNote(title: "Temporal", content: "x"))
        await syncer.flush()
        let serverId = backend.stored[0].id

        backend.offline = true
        _ = try await store.deleteNote(id: saved.id)
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1, "sin red el borrado sigue pendiente")

        backend.offline = false
        await syncer.flush()
        XCTAssertTrue(backend.forgotten.contains(serverId))
        XCTAssertEqual(backend.stored.count, 0)
    }

    @MainActor
    func test_loQueOtroDispositivoBorroDesapareceAquiAlHidratar() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("remote-del"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("remote-del-s"), backend: backend)
        syncer.register(store)

        let saved = try await store.saveNote(GemmaNote(title: "Compartida", content: "x"))
        await syncer.flush()
        XCTAssertNotNil(outbox.serverId(kind: MirrorKind.note, recordId: saved.id))

        // El otro dispositivo la borra: el nodo deja de estar en el servidor.
        backend.stored.removeAll()

        await syncer.hydrate()
        let notesCount = await store.allNotes().count
        XCTAssertEqual(notesCount, 0,
                       "se subió una vez y ya no está: es un borrado de otro dispositivo")
    }

    @MainActor
    func test_loLocalQueNuncaSeSubioNoSeBorraAlHidratar() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("adopt"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("adopt-s"), backend: backend)
        syncer.register(store)

        // Nota creada antes de que existiera el espejo: está en local y no tiene id del
        // servidor apuntado. Se simula vaciando la cola a mano.
        let saved = try await store.saveNote(GemmaNote(title: "Antigua", content: "x"))
        for op in outbox.pending() { outbox.resolve(op) }
        XCTAssertEqual(outbox.pendingCount(), 0)

        let report = await syncer.hydrate()
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.adopted, 1)
        let notesCount = await store.allNotes().count
        XCTAssertEqual(notesCount, 1, "nunca se subió: no es un borrado, es una adopción")
        XCTAssertTrue(outbox.isPending(kind: MirrorKind.note, recordId: saved.id))

        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)
    }

    @MainActor
    func test_loPendienteGanaSobreElServidorAlHidratar() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("pendingwins"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("pendingwins-s"), backend: backend)
        syncer.register(store)

        let note = GemmaNote(title: "Precio", content: "10 euros")
        _ = try await store.saveNote(note)
        await syncer.flush()

        // El usuario edita sin red.
        backend.offline = true
        var edited = note
        edited.content = "12 euros"
        edited.updatedAt = Date().addingTimeInterval(60)
        _ = try await store.saveNote(edited)
        backend.offline = false

        await syncer.hydrate()
        let notes = await store.allNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.content, "12 euros",
                       "lo pendiente de subir es más nuevo que el servidor por definición")
    }

    @MainActor
    func test_dosNodosDelMismoRegistroSeColapsanEnElMasNuevo() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("dupes"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("dupes-s"), backend: backend)
        syncer.register(store)

        // Una subida que llegó dos veces porque la respuesta se perdió.
        var note = GemmaNote(title: "Dos veces", content: "vieja")
        backend.seed(kind: MirrorKind.note, record: NoteStore.record(for: note))
        note.content = "nueva"
        note.updatedAt = Date().addingTimeInterval(120)
        backend.seed(kind: MirrorKind.note, record: NoteStore.record(for: note))
        XCTAssertEqual(backend.stored.count, 2)

        let report = await syncer.hydrate()
        XCTAssertEqual(report.duplicatesRemoved, 1)
        XCTAssertEqual(backend.stored.count, 1)
        let notes = await store.allNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.content, "nueva")
    }

    @MainActor
    func test_unNodoViejoSeRenuevaParaQueLaPurgaDelServidorNoSeLoLleve() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("renew"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("renew-s"), backend: backend)
        syncer.register(store)

        let note = GemmaNote(title: "Vieja", content: "sigue valiendo")
        let old = Date().timeIntervalSince1970 - MirrorSyncer.renewAfterSeconds - 1
        backend.seed(kind: MirrorKind.note, record: NoteStore.record(for: note), lastSeenAt: old)

        await syncer.hydrate()
        XCTAssertTrue(outbox.isPending(kind: MirrorKind.note, recordId: note.id),
                      "un nodo que el servidor no ha visto en meses se vuelve a escribir antes de que decaiga")

        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)
        XCTAssertGreaterThan(backend.stored[0].lastSeenAt, old)
    }
}

// MARK: - Migración de lo que ya había en el dispositivo

final class MirrorMigrationTests: XCTestCase {

    @MainActor
    func test_loQueYaHabiaEnLocalSeSubeUnaSolaVezAunqueLaAppSeAbraCincoVeces() async throws {
        let outboxDefaults = freshDefaults("migr-o")
        let syncerDefaults = freshDefaults("migr-s")
        let outbox = MirrorOutbox(defaults: outboxDefaults)
        let store = NoteStore(fileURL: nil, outbox: nil)   // sin cola: datos "de antes"
        _ = try await store.saveNote(GemmaNote(title: "Vieja 1", content: "a"))
        _ = try await store.saveNote(GemmaNote(title: "Vieja 2", content: "b"))
        XCTAssertEqual(outbox.pendingCount(), 0)

        let backend = FakeMirrorBackend()
        for _ in 0..<5 {
            let syncer = makeSyncer(outbox: outbox, defaults: syncerDefaults, backend: backend)
            syncer.register(store)
            await syncer.bootstrap()
        }

        XCTAssertEqual(backend.stored.count, 2, "cinco arranques no pueden dejar diez nodos")
        XCTAssertEqual(outbox.pendingCount(), 0)
    }

    @MainActor
    func test_laMigracionSinRedDejaTodoEncoladoYNadaSePierde() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("migroff-o"))
        let store = NoteStore(fileURL: nil, outbox: nil)
        _ = try await store.saveNote(GemmaNote(title: "Dictada en el coche", content: "sin cobertura"))

        let backend = FakeMirrorBackend()
        backend.offline = true
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("migroff-s"), backend: backend)
        syncer.register(store)
        await syncer.bootstrap()

        XCTAssertEqual(outbox.pendingCount(), 1)
        let notesCount = await store.allNotes().count
        XCTAssertEqual(notesCount, 1)

        backend.offline = false
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)
    }
}

// MARK: - Los otros almacenes

final class MirroredStoresCoverageTests: XCTestCase {

    @MainActor
    func test_unAtajoAprendidoViajaAlServidorYVuelve() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("sc-o"))
        let registry = ShortcutRegistry(defaults: freshDefaults("sc-d"), outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("sc-s"), backend: backend)
        syncer.register(registry)

        registry.remember(ShortcutEntry(name: "Abrir Garaje", purpose: "abre la puerta del garaje"))
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)

        // Dispositivo nuevo: registro vacío, mismo servidor.
        let fresh = ShortcutRegistry(defaults: freshDefaults("sc-d2"), outbox: MirrorOutbox(defaults: freshDefaults("sc-o2")))
        let syncer2 = makeSyncer(outbox: MirrorOutbox(defaults: freshDefaults("sc-o3")),
                                 defaults: freshDefaults("sc-s2"), backend: backend)
        syncer2.register(fresh)
        await syncer2.hydrate()

        XCTAssertEqual(fresh.entry(named: "abrir garaje")?.purpose, "abre la puerta del garaje")
    }

    @MainActor
    func test_unAliasOlvidadoSeBorraTambienEnElServidor() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("al-o"))
        let aliases = ContactAliasStore(defaults: freshDefaults("al-d"), outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("al-s"), backend: backend)
        syncer.register(aliases)

        aliases.setAlias(relationship: "mi jefe", contactTarget: "Carlos Pérez")
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)

        aliases.forgetAlias(relationship: "mi jefe")
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 0)
    }

    @MainActor
    func test_unLugarGuardadoSobreviveAUnaReinstalacion() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("pl-o"))
        let places = PlaceStore(storageURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("pl-s"), backend: backend)
        syncer.register(places)

        places.save(place: KnownPlace(name: "Casa de Marcos", latitude: 25.76, longitude: -80.19))
        await syncer.flush()

        // Contenedor nuevo y vacío: es lo que pasó al cambiar el identificador de la app.
        let reinstalled = PlaceStore(storageURL: nil, outbox: MirrorOutbox(defaults: freshDefaults("pl-o2")))
        let syncer2 = makeSyncer(outbox: MirrorOutbox(defaults: freshDefaults("pl-o3")),
                                 defaults: freshDefaults("pl-s2"), backend: backend)
        syncer2.register(reinstalled)
        await syncer2.hydrate()

        let recovered = reinstalled.place(named: "casa de marcos")
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.latitude ?? 0, 25.76, accuracy: 0.0001)
    }

    @MainActor
    func test_unaAlarmaPuestaSobreviveAUnaReinstalacion() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("cl-o"))
        let clock = ClockPersistence(defaults: freshDefaults("cl-d"), outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("cl-s"), backend: backend)
        syncer.register(AlarmMirror(persistence: clock))

        clock.add(alarm: GemmaAlarm(title: "Despertarse", hour: 7, minute: 30))
        await syncer.flush()
        XCTAssertEqual(backend.stored.count, 1)

        let reinstalled = ClockPersistence(defaults: freshDefaults("cl-d2"), outbox: MirrorOutbox(defaults: freshDefaults("cl-o2")))
        let syncer2 = makeSyncer(outbox: MirrorOutbox(defaults: freshDefaults("cl-o3")),
                                 defaults: freshDefaults("cl-s2"), backend: backend)
        syncer2.register(AlarmMirror(persistence: reinstalled))
        await syncer2.hydrate()

        XCTAssertEqual(reinstalled.alarms().count, 1)
        XCTAssertEqual(reinstalled.alarms().first?.hour, 7)
    }

    @MainActor
    func test_losKindsDelEspejoNoChocanConLosDelServidor() {
        // `place` a secas lo produce la consolidación; un pin con coordenadas fusionado
        // con uno de esos perdería las coordenadas.
        XCTAssertNotEqual(MirrorKind.place, "place")
        XCTAssertEqual(Set(MirrorKind.all).count, MirrorKind.all.count, "no puede haber dos almacenes con el mismo kind")
    }
}

// MARK: - Honestidad

final class MirrorHonestyTests: XCTestCase {

    @MainActor
    func test_elSobreLlevaUnaClaveUnicaPorRegistro() {
        // Es lo que impide que el dedup semántico del servidor fusione dos notas
        // tituladas parecido en una sola.
        let a = MirrorEnvelope.dateKey(kind: MirrorKind.note, recordId: "aaa")
        let b = MirrorEnvelope.dateKey(kind: MirrorKind.note, recordId: "bbb")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, MirrorEnvelope.dateKey(kind: MirrorKind.note, recordId: "aaa"),
                       "y es estable, para que una edición vaya al mismo nodo")
    }

    @MainActor
    func test_laHerramientaDiceExactamenteDondeQuedoLaNota() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("honest"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("honest-s"), backend: backend)

        let note = GemmaNote(title: "Pendiente", content: "x")
        _ = try await store.saveNote(note)

        // Recién encolada y con el servidor alcanzable: va de camino, y eso no merece
        // un aviso en cada respuesta.
        XCTAssertEqual(MirrorStatus.describe(kind: MirrorKind.note, recordId: note.id, outbox: outbox),
                       "queued")
        XCTAssertNil(MirrorStatus.note(kind: MirrorKind.note, recordId: note.id, outbox: outbox))

        // Con el servidor inalcanzable sí se avisa: está solo en este dispositivo.
        backend.offline = true
        await syncer.flush()
        XCTAssertEqual(MirrorStatus.describe(kind: MirrorKind.note, recordId: note.id, outbox: outbox),
                       "pending_upload")
        XCTAssertNotNil(MirrorStatus.note(kind: MirrorKind.note, recordId: note.id, outbox: outbox))

        // Y una vez arriba, se dice sin matices.
        backend.offline = false
        await syncer.flush()
        XCTAssertEqual(MirrorStatus.describe(kind: MirrorKind.note, recordId: note.id, outbox: outbox),
                       "synced")
        XCTAssertNil(MirrorStatus.note(kind: MirrorKind.note, recordId: note.id, outbox: outbox))
    }

    @MainActor
    func test_diezEdicionesSinRedSonUnaSolaSubida() async throws {
        let outbox = MirrorOutbox(defaults: freshDefaults("coalesce"))
        let store = NoteStore(fileURL: nil, outbox: outbox)
        let backend = FakeMirrorBackend()
        backend.offline = true
        let syncer = makeSyncer(outbox: outbox, defaults: freshDefaults("coalesce-s"), backend: backend)

        var note = GemmaNote(title: "Lista", content: "0")
        for i in 1...10 {
            note.content = "\(i)"
            note.updatedAt = Date().addingTimeInterval(Double(i))
            _ = try await store.saveNote(note)
        }
        XCTAssertEqual(outbox.pendingCount(), 1, "la cola guarda una operación por registro, no un historial")

        backend.offline = false
        await syncer.flush()
        XCTAssertEqual(backend.saveCount, 1)
        let env = MirrorEnvelope.from(backend.stored[0].extra)
        let payload = env.flatMap { MirrorCodec.decode($0.mirror.payload, as: GemmaNote.self) }
        XCTAssertEqual(payload?.content, "10", "y sube la última versión, no la primera")
    }
}
