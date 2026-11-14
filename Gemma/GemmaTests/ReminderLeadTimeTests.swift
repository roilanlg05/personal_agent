import XCTest
import CoreLocation
@testable import Gemma

final class StubTravelEstimator: TravelTimeEstimating, @unchecked Sendable {
    var seconds: TimeInterval?
    var errorToThrow: Error?
    private(set) var requestedDestinations: [String] = []

    init(seconds: TimeInterval? = nil, errorToThrow: Error? = nil) {
        self.seconds = seconds
        self.errorToThrow = errorToThrow
    }

    func travelTime(to destination: ReminderDestination) async throws -> TimeInterval {
        requestedDestinations.append(destination.name)
        if let errorToThrow { throw errorToThrow }
        guard let seconds else { throw ReminderLeadTimeError.routeUnavailable(destination.name) }
        return seconds
    }
}

/// Un recordatorio avisa tarde si avisa a la hora del compromiso: el usuario ya llega
/// tarde. Estas pruebas fijan cuándo tiene que avisar Gemma.
final class ReminderLeadTimeTests: XCTestCase {

    /// 2026-11-06 08:30 en UTC, la hora de llegar al trabajo del ejemplo del usuario.
    private var due: Date {
        ISO8601Dates.parse("2026-11-06T08:30:00Z")!
    }

    /// El "ahora" de todas las pruebas, dos horas y media antes del compromiso.
    ///
    /// Tiene que ser explícito: con el `Date()` por omisión, estas pruebas pasaban hasta
    /// que el reloj real cruzaba las 08:30 UTC del 6 de noviembre de 2026 y a partir de
    /// ahí fallaban todas con `dueDateInThePast`. Una prueba que depende de la hora en
    /// que se ejecuta no prueba nada.
    private var now: Date {
        ISO8601Dates.parse("2026-11-06T06:00:00Z")!
    }

    private func calculator(travel: TimeInterval?) -> ReminderLeadTimeCalculator {
        ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: travel))
    }

    // MARK: - Con lugar: hora de salida más margen

    func test_conLugarAvisaConMargenAntesDeLaHoraDeSalida() async throws {
        // 15 minutos de viaje: hay que salir a las 08:15, así que el aviso entra 15
        // minutos antes de salir, a las 08:00.
        let plan = try await calculator(travel: 15 * 60).plan(
            due: due,
            destination: ReminderDestination(name: "Trabajo"),
            now: now
        )

        XCTAssertEqual(plan.leaveBy, ISO8601Dates.parse("2026-11-06T08:15:00Z"))
        XCTAssertEqual(plan.alertAt, ISO8601Dates.parse("2026-11-06T08:00:00Z"))
        XCTAssertEqual(plan.travelTime, 15 * 60)
        XCTAssertEqual(plan.basis, .travelTime)
    }

    func test_elMensajeDiceLaHoraDeSalidaYLaDeLlegada() async throws {
        let plan = try await calculator(travel: 15 * 60).plan(
            due: due,
            destination: ReminderDestination(name: "Trabajo"),
            now: now
        )

        let message = plan.message(title: "trabajo", timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(message.contains("08:15"), "Falta la hora de salida: \(message)")
        XCTAssertTrue(message.contains("08:30"), "Falta la hora de llegada: \(message)")
    }

    func test_unViajeLargoAdelantaElAviso() async throws {
        let plan = try await calculator(travel: 60 * 60).plan(
            due: due,
            destination: ReminderDestination(name: "Aeropuerto"),
            now: now
        )

        XCTAssertEqual(plan.leaveBy, ISO8601Dates.parse("2026-11-06T07:30:00Z"))
        XCTAssertEqual(plan.alertAt, ISO8601Dates.parse("2026-11-06T07:15:00Z"))
    }

    // MARK: - Sin lugar: una hora antes

    func test_sinLugarAvisaUnaHoraAntes() async throws {
        let plan = try await calculator(travel: nil).plan(due: due, destination: nil, now: now)

        XCTAssertEqual(plan.alertAt, ISO8601Dates.parse("2026-11-06T07:30:00Z"))
        XCTAssertNil(plan.leaveBy)
        XCTAssertNil(plan.travelTime)
        XCTAssertEqual(plan.basis, .fixedHourBefore)
    }

    func test_siNoHayRutaCaeALaHoraAntesYLoDice() async throws {
        // Un destino que el mapa no sabe resolver no debe dejar al usuario sin aviso.
        let plan = try await calculator(travel: nil).plan(
            due: due,
            destination: ReminderDestination(name: "Sitio inexistente"),
            now: now
        )

        XCTAssertEqual(plan.alertAt, ISO8601Dates.parse("2026-11-06T07:30:00Z"))
        XCTAssertEqual(plan.basis, .fixedHourBefore)
        XCTAssertNil(plan.leaveBy)
    }

    func test_elMensajeSinLugarNoHablaDeSalir() async throws {
        let plan = try await calculator(travel: nil).plan(due: due, destination: nil, now: now)
        let message = plan.message(title: "la reunión", timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertFalse(message.lowercased().contains("salir"))
        XCTAssertTrue(message.contains("08:30"))
    }

    // MARK: - Casos límite

    func test_siElAvisoYaPasoSeAvisaDeInmediato() async throws {
        // El usuario crea a las 08:20 un recordatorio para las 08:30 con 15 minutos de
        // viaje: la hora de salida ya pasó. Callarse sería dejarle llegar tarde.
        let now = ISO8601Dates.parse("2026-11-06T08:20:00Z")!
        let plan = try await calculator(travel: 15 * 60).plan(
            due: due,
            destination: ReminderDestination(name: "Trabajo"),
            now: now
        )

        XCTAssertEqual(plan.alertAt, now)
        XCTAssertTrue(plan.isLate, "El aviso llega después de la hora de salida.")
    }

    func test_unCompromisoYaPasadoSeRechaza() async {
        let now = ISO8601Dates.parse("2026-11-06T09:00:00Z")!
        do {
            _ = try await calculator(travel: nil).plan(due: due, destination: nil, now: now)
            XCTFail("Un recordatorio para una hora que ya pasó no tiene sentido.")
        } catch let error as ReminderLeadTimeError {
            XCTAssertEqual(error, .dueDateInThePast)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func test_elMargenYElAdelantoSonConfigurables() async throws {
        let calculator = ReminderLeadTimeCalculator(
            estimator: StubTravelEstimator(seconds: 10 * 60),
            departureBuffer: 5 * 60,
            fallbackLeadTime: 30 * 60
        )

        let withPlace = try await calculator.plan(due: due, destination: ReminderDestination(name: "Gym"), now: now)
        XCTAssertEqual(withPlace.alertAt, ISO8601Dates.parse("2026-11-06T08:15:00Z"))

        let withoutPlace = try await calculator.plan(due: due, destination: nil, now: now)
        XCTAssertEqual(withoutPlace.alertAt, ISO8601Dates.parse("2026-11-06T08:00:00Z"))
    }

    func test_elDestinoPuedeVenirYaConCoordenadas() async throws {
        let estimator = StubTravelEstimator(seconds: 20 * 60)
        let destination = ReminderDestination(
            name: "Trabajo",
            coordinate: CLLocationCoordinate2D(latitude: 25.76, longitude: -80.19)
        )
        let plan = try await ReminderLeadTimeCalculator(estimator: estimator)
            .plan(due: due, destination: destination, now: now)

        XCTAssertEqual(plan.leaveBy, ISO8601Dates.parse("2026-11-06T08:10:00Z"))
        XCTAssertEqual(estimator.requestedDestinations, ["Trabajo"])
    }
}
