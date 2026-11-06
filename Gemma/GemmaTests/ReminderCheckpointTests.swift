import XCTest
@testable import Gemma

/// El escenario exacto que describió el usuario: una cita a las 16:15, 15 minutos de
/// viaje, y tiempo para prepararse antes de salir. Gemma no avisa una vez: acompaña.
final class ReminderCheckpointTests: XCTestCase {

    private var due: Date { ISO8601Dates.parse("2026-11-06T16:15:00Z")! }
    private let utc = TimeZone(identifier: "UTC")!

    private func checkpoints(
        travel: TimeInterval? = 15 * 60,
        prep: TimeInterval = 45 * 60,
        now: String = "2026-11-06T12:00:00Z"
    ) -> [ReminderCheckpoint] {
        ReminderCheckpointPlanner(preparationTime: prep).checkpoints(
            due: due,
            travelTime: travel,
            now: ISO8601Dates.parse(now)!
        )
    }

    private func checkpoint(_ kind: ReminderCheckpointKind, in list: [ReminderCheckpoint]) -> ReminderCheckpoint? {
        list.first { $0.kind == kind }
    }

    // MARK: - El reparto de avisos

    func test_hayTresAvisosPrepararseComprobarYSalir() {
        let list = checkpoints()
        XCTAssertEqual(list.map(\.kind), [.headsUp, .preparationCheck, .leaveNow])
    }

    func test_elPrimerAvisoAbreLaVentanaDePreparacion() {
        // Viaje 15 min: salida 16:00. Con 45 min de preparación, el primer aviso entra
        // a las 15:15.
        let headsUp = checkpoint(.headsUp, in: checkpoints())
        XCTAssertEqual(headsUp?.at, ISO8601Dates.parse("2026-11-06T15:15:00Z"))
    }

    func test_laComprobacionVaAMitadDeLaPreparacion() {
        // El usuario lo pidió así: "dentro de media hora me preguntas, ¿ya te
        // preparaste?".
        let check = checkpoint(.preparationCheck, in: checkpoints())
        XCTAssertEqual(check?.at, ISO8601Dates.parse("2026-11-06T15:37:30Z"))
    }

    func test_elUltimoAvisoEsLaHoraDeSalida() {
        let leave = checkpoint(.leaveNow, in: checkpoints())
        XCTAssertEqual(leave?.at, ISO8601Dates.parse("2026-11-06T16:00:00Z"))
    }

    // MARK: - Lo que dice cada aviso

    func test_elPrimerAvisoDiceLaHoraYCuantoQuedaParaPrepararse() {
        let headsUp = try? XCTUnwrap(checkpoint(.headsUp, in: checkpoints()))
        let message = headsUp?.message(title: "la cita", timeZone: utc) ?? ""

        XCTAssertTrue(message.contains("16:15"), "Falta la hora de la cita: \(message)")
        XCTAssertTrue(message.contains("45"), "Falta el tiempo de preparación: \(message)")
    }

    func test_laComprobacionPreguntaYDiceCuantoFaltaParaSalir() {
        let check = checkpoint(.preparationCheck, in: checkpoints())
        let message = check?.message(title: "la cita", timeZone: utc) ?? ""

        XCTAssertTrue(message.contains("?"), "Tiene que preguntar: \(message)")
        XCTAssertTrue(message.contains("22"), "Faltan los minutos hasta salir: \(message)")
    }

    func test_elAvisoDeSalidaDiceSalirYLaHoraDeLlegada() {
        let leave = checkpoint(.leaveNow, in: checkpoints())
        let message = leave?.message(title: "la cita", timeZone: utc) ?? ""

        XCTAssertTrue(message.lowercased().contains("sal"))
        XCTAssertTrue(message.contains("16:15"))
    }

    // MARK: - Sin lugar

    func test_sinViajeSoloHayUnAvisoUnaHoraAntes() {
        let list = checkpoints(travel: nil)
        XCTAssertEqual(list.map(\.kind), [.headsUp])
        XCTAssertEqual(list.first?.at, ISO8601Dates.parse("2026-11-06T15:15:00Z"))
    }

    func test_sinViajeElMensajeNoHablaDeSalir() {
        let message = checkpoints(travel: nil).first?.message(title: "la reunión", timeZone: utc) ?? ""
        XCTAssertFalse(message.lowercased().contains("salir"))
    }

    // MARK: - Puntos que ya pasaron

    func test_losAvisosYaPasadosNoSeProgramanDeNuevo() {
        // Son las 15:40: la preparación y su comprobación ya pasaron, solo queda salir.
        let list = checkpoints(now: "2026-11-06T15:40:00Z")
        XCTAssertEqual(list.map(\.kind), [.leaveNow])
    }

    func test_siLaSalidaYaPasoAvisaDeInmediatoYLoDice() {
        let now = ISO8601Dates.parse("2026-11-06T16:05:00Z")!
        let list = ReminderCheckpointPlanner().checkpoints(due: due, travelTime: 15 * 60, now: now)

        XCTAssertEqual(list.map(\.kind), [.leaveNow])
        XCTAssertEqual(list.first?.at, now)
        XCTAssertEqual(list.first?.isLate, true)
        let message = list.first?.message(title: "la cita", timeZone: utc) ?? ""
        XCTAssertTrue(message.lowercased().contains("ya"), "Debe urgir: \(message)")
    }

    func test_unaCitaYaPasadaNoGeneraAvisos() {
        let now = ISO8601Dates.parse("2026-11-06T17:00:00Z")!
        XCTAssertTrue(ReminderCheckpointPlanner().checkpoints(due: due, travelTime: 15 * 60, now: now).isEmpty)
    }

    // MARK: - Ventana corta

    func test_siNoCabeLaPreparacionSeRecortaSinPerderLaSalida() {
        // Son las 15:50 y hay que salir a las 16:00: no hay 45 minutos de preparación,
        // pero el aviso de salir sigue siendo imprescindible.
        let list = checkpoints(now: "2026-11-06T15:50:00Z")
        XCTAssertTrue(list.contains { $0.kind == .leaveNow })
        XCTAssertFalse(list.contains { $0.kind == .headsUp })
    }

    func test_laPreparacionEsConfigurable() {
        let list = checkpoints(prep: 2 * 60 * 60)
        XCTAssertEqual(checkpoint(.headsUp, in: list)?.at, ISO8601Dates.parse("2026-11-06T14:00:00Z"))
    }
}
