import Foundation
import XCTest
@testable import Gemma

@MainActor
final class FormBrokerTests: XCTestCase {
    private func spec(_ titulo: String = "T") -> FormSpec {
        FormSpec(title: titulo, description: nil, submitLabel: nil,
                 fields: [FormField(id: "a", label: "A", kind: .text)])
    }

    /// Cede el hilo principal hasta que el broker tenga algo pendiente (o falle la prueba).
    private func esperaPendiente(_ broker: FormBroker) async throws -> FormBroker.PendingForm {
        for _ in 0..<200 {
            if let p = broker.pendiente { return p }
            await Task.yield()
        }
        XCTFail("el broker nunca mostró el formulario")
        throw CancellationError()
    }

    func test_presenta_se_reanuda_al_enviar_con_los_valores() async throws {
        let broker = FormBroker()
        let t = Task { try await broker.presenta(spec()) }
        let p = try await esperaPendiente(broker)
        broker.envia(id: p.id, valores: ["a": "hola"])
        let r = try await t.value
        XCTAssertEqual(r, FormResponse(status: .submitted, values: ["a": "hola"]))
    }

    func test_cancela_devuelve_status_cancelled() async throws {
        let broker = FormBroker()
        let t = Task { try await broker.presenta(spec()) }
        let p = try await esperaPendiente(broker)
        broker.cancela(id: p.id)
        let r = try await t.value
        XCTAssertEqual(r, FormResponse(status: .cancelled, values: [:]))
    }

    func test_el_plazo_devuelve_timeout_sin_esperar_de_verdad() async throws {
        // `dormir` vuelve al instante: si el plazo no existiera, esto colgaría hasta el
        // timeout de la prueba en vez de devolver .timeout.
        let broker = FormBroker(plazo: .seconds(600), dormir: { _ in })
        let r = try await broker.presenta(spec())
        XCTAssertEqual(r, FormResponse(status: .timeout, values: [:]))
        XCTAssertNil(broker.pendiente)
    }

    func test_el_plazo_recibe_la_duracion_configurada() async throws {
        let visto = DuracionVista()
        let broker = FormBroker(plazo: .seconds(42), dormir: { d in await visto.guarda(d) })
        _ = try await broker.presenta(spec())
        let d = await visto.valor
        XCTAssertEqual(d, .seconds(42))
    }

    func test_un_segundo_presenta_mientras_hay_uno_abierto_lanza_yaHayUnoAbierto_y_no_toca_el_primero() async throws {
        let broker = FormBroker()
        let primero = Task { try await broker.presenta(spec("uno")) }
        let p = try await esperaPendiente(broker)
        do {
            _ = try await broker.presenta(spec("dos"))
            XCTFail("debía lanzar")
        } catch let e as FormBrokerError {
            XCTAssertEqual(e, .yaHayUnoAbierto)
        }
        // El primero sigue abierto, intacto y resoluble.
        XCTAssertEqual(broker.pendiente, p)
        XCTAssertEqual(broker.pendiente?.spec.title, "uno")
        broker.envia(id: p.id, valores: ["a": "x"])
        let r = try await primero.value
        XCTAssertEqual(r.status, .submitted)
    }

    func test_envia_con_un_id_que_no_es_el_pendiente_se_ignora() async throws {
        let broker = FormBroker()
        let t = Task { try await broker.presenta(spec()) }
        let p = try await esperaPendiente(broker)
        broker.envia(id: "otro", valores: ["a": "mal"])
        broker.cancela(id: "otro")
        XCTAssertEqual(broker.pendiente, p, "un id ajeno no debe resolver el abierto")
        broker.envia(id: p.id, valores: ["a": "bien"])
        let r = try await t.value
        XCTAssertEqual(r.values, ["a": "bien"])
    }

    func test_tras_resolver_pendiente_vuelve_a_nil_y_se_puede_presentar_otro() async throws {
        let broker = FormBroker()
        let t1 = Task { try await broker.presenta(spec("uno")) }
        let p1 = try await esperaPendiente(broker)
        broker.cancela(id: p1.id)
        _ = try await t1.value
        XCTAssertNil(broker.pendiente)

        let t2 = Task { try await broker.presenta(spec("dos")) }
        let p2 = try await esperaPendiente(broker)
        XCTAssertNotEqual(p1.id, p2.id, "cada presentación lleva su propio id")
        // Un envío tardío con el id viejo no puede resolver el nuevo.
        broker.envia(id: p1.id, valores: ["a": "viejo"])
        XCTAssertEqual(broker.pendiente, p2)
        broker.envia(id: p2.id, valores: ["a": "nuevo"])
        let r = try await t2.value
        XCTAssertEqual(r.values, ["a": "nuevo"])
    }

    func test_cancelaTodo_reanuda_con_cancelled() async throws {
        let broker = FormBroker()
        let t = Task { try await broker.presenta(spec()) }
        _ = try await esperaPendiente(broker)
        broker.cancelaTodo()
        let r = try await t.value
        XCTAssertEqual(r.status, .cancelled)
        XCTAssertNil(broker.pendiente)
        broker.cancelaTodo() // sin nada abierto: no hace nada ni revienta
    }

    func test_si_el_llamador_se_cancela_se_limpia_pendiente_y_se_reanuda() async throws {
        let broker = FormBroker()
        let t = Task { try await broker.presenta(spec()) }
        _ = try await esperaPendiente(broker)
        t.cancel()
        let r = try await t.value
        XCTAssertEqual(r.status, .cancelled)
        XCTAssertNil(broker.pendiente, "un turno cancelado no debe dejar el formulario colgado")
    }

    // MARK: revisión final — I3: cada turno cierra solo SU formulario

    /// El fin tardío de un turno viejo (cancelado, que acaba después de que empezara el nuevo) no
    /// puede cerrar el formulario que pidió el turno nuevo.
    func test_cerrar_por_turno_no_cierra_el_formulario_de_otro_turno() async throws {
        let broker = FormBroker()
        let viejo = UUID(), nuevo = UUID()
        broker.turnoVigente = nuevo
        let t = Task { try await broker.presenta(spec(), turno: nuevo) }
        let p = try await esperaPendiente(broker)
        broker.cancela(turno: viejo)
        XCTAssertEqual(broker.pendiente, p, "el turno viejo cerró el formulario del turno nuevo")
        broker.cancela(turno: nuevo)
        let r = try await t.value
        XCTAssertEqual(r.status, .cancelled)
        XCTAssertNil(broker.pendiente)
    }

    /// Un turno que ya no es el vigente no puede ocupar el hueco: si lo hiciera, el turno nuevo
    /// recibiría `yaHayUnoAbierto` por un formulario que ya nadie espera.
    func test_un_turno_que_no_es_el_vigente_no_abre_formulario() async throws {
        // Plazo instantáneo: si el formulario se abriera, la prueba sale roja con `timeout` en vez
        // de colgarse diez minutos.
        let broker = FormBroker(dormir: { _ in })
        let viejo = UUID(), nuevo = UUID()
        broker.turnoVigente = nuevo
        let r = try await broker.presenta(spec(), turno: viejo)
        XCTAssertEqual(r.status, .cancelled)
        XCTAssertNil(broker.pendiente)
        // Sin turno vigente (se acaba de detener o de mandar otro mensaje) tampoco.
        broker.turnoVigente = nil
        let r2 = try await broker.presenta(spec(), turno: viejo)
        XCTAssertEqual(r2.status, .cancelled)
        XCTAssertNil(broker.pendiente)
    }

    /// Un llamador ya cancelado no llega a ocupar el hueco ni un instante: el segundo `presenta`,
    /// que corre justo detrás en el hilo principal, encuentra el hueco libre.
    func test_un_llamador_ya_cancelado_no_ocupa_el_hueco() async throws {
        let broker = FormBroker()
        let cancelado = Task { try await broker.presenta(spec("viejo")) }
        cancelado.cancel()
        let vigente = Task { try await broker.presenta(spec("nuevo")) }
        let r1 = try await cancelado.value
        XCTAssertEqual(r1.status, .cancelled)
        let p = try await esperaPendiente(broker)
        XCTAssertEqual(p.spec.title, "nuevo")
        broker.envia(id: p.id, valores: ["a": "x"])
        let r2 = try await vigente.value
        XCTAssertEqual(r2.status, .submitted, "el turno nuevo no debe recibir yaHayUnoAbierto")
    }

    func test_carrera_entre_envio_y_plazo_resuelve_una_sola_vez() async throws {
        // Muchas rondas: el plazo (instantáneo) y el envío compiten por la misma
        // continuación. Si se reanudara dos veces, CheckedContinuation abortaría el proceso.
        for _ in 0..<50 {
            let broker = FormBroker(plazo: .seconds(1), dormir: { _ in await Task.yield() })
            let t = Task { try await broker.presenta(spec()) }
            // No se espera a ver el formulario: el plazo puede ganar antes de que lo veamos, y
            // justo ese es el solape que se quiere provocar. Se envía si todavía está abierto.
            await Task.yield()
            let id = broker.pendiente?.id
            if let id { broker.envia(id: id, valores: ["a": "v"]) }
            let r = try await t.value
            XCTAssertTrue(r.status == .submitted || r.status == .timeout)
            XCTAssertNil(broker.pendiente)
            // Y los intentos tardíos de las otras vías no hacen nada.
            if let id { broker.cancela(id: id) }
            broker.cancelaTodo()
        }
    }
}

private actor DuracionVista {
    private(set) var valor: Duration?
    func guarda(_ d: Duration) { valor = d }
}
