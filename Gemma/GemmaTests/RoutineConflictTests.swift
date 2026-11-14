import XCTest
@testable import Gemma

/// Pruebas de `RoutineHelper.findRoutineConflicts`, el detector de choques entre lo que
/// se va a agendar y el horario habitual del usuario.
///
/// Es la pieza de la que depende SP1 para no agendarle al usuario algo encima de su
/// turno de trabajo. Tenía dos fallos que la dejaban ciega justo en los casos que más
/// importan: los eventos de varios días y los que cruzan la medianoche.
final class RoutineConflictTests: XCTestCase {

    private let calendar = Calendar.current

    /// Una fecha concreta, para que las pruebas no dependan del día en que se ejecuten.
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Double {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!.timeIntervalSince1970
    }

    /// Una rutina estructurada, tal como la deja `set_routine` en `extra`.
    ///
    /// Se construye decodificando JSON porque `MemoryClient.Node` existe para decodificar
    /// la respuesta del servicio y no tiene inicializador propio: así la prueba usa el
    /// mismo camino que el código real.
    private func routine(
        _ title: String,
        days: [Int],
        startMinutes: Int,
        endMinutes: Int,
        kind: String = "routine"
    ) -> MemoryClient.Node {
        let extra: [String: Any] = [
            "title": title,
            "days": days,
            "startMinutes": startMinutes,
            "endMinutes": endMinutes
        ]
        let extraText = String(data: try! JSONSerialization.data(withJSONObject: extra), encoding: .utf8)!
        let node: [String: Any] = [
            "id": UUID().uuidString,
            "kind": kind,
            "label": title,
            "body": "Rutina de prueba",
            "extra": extraText
        ]
        let data = try! JSONSerialization.data(withJSONObject: node)
        return try! JSONDecoder().decode(MemoryClient.Node.self, from: data)
    }

    // 2026-11-10 es martes. 11 miércoles, 12 jueves, 13 viernes, 14 sábado.

    func test_detecta_el_choque_en_un_evento_de_un_solo_dia() {
        // Martes 10, de 09:00 a 11:00, contra una rutina de los martes de 10:00 a 12:00.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 10, 11, 0),
            nodes: [routine("Gimnasio", days: [3], startMinutes: 10 * 60, endMinutes: 12 * 60)]
        )
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertTrue(conflicts[0].contains("Gimnasio"))
    }

    func test_no_inventa_un_choque_que_no_existe() {
        // Mismo martes, pero la rutina es de los jueves.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 10, 11, 0),
            nodes: [routine("Gimnasio", days: [5], startMinutes: 10 * 60, endMinutes: 12 * 60)]
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    func test_un_viaje_de_varios_dias_se_comprueba_contra_todos_sus_dias() {
        // ÉSTE ES EL FALLO QUE MOTIVÓ ESTAS PRUEBAS. El viaje va del martes 10 al sábado
        // 14. La rutina es de los jueves, o sea el día 12, que cae dentro del viaje.
        // Antes solo se miraba el día de la semana de la fecha de INICIO (martes), así
        // que los días 2 al 5 no se comprobaban nunca: el usuario podía quedar agendado
        // encima de su turno de trabajo del jueves y Gemma decía que estaba libre.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 14, 18, 0),
            nodes: [routine("Turno en Amazon", days: [5], startMinutes: 5 * 60, endMinutes: 16 * 60 + 30)]
        )
        XCTAssertEqual(conflicts.count, 1, "La rutina del jueves cae dentro del viaje.")
        XCTAssertTrue(conflicts[0].contains("Turno en Amazon"))
    }

    func test_dice_en_que_dia_del_viaje_esta_el_choque() {
        // Saber que hay conflicto no basta: el usuario necesita saber qué día, porque la
        // decisión («muevo el vuelo» / «pido el día libre») depende de eso.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 14, 18, 0),
            nodes: [routine("Turno en Amazon", days: [5], startMinutes: 5 * 60, endMinutes: 16 * 60 + 30)]
        )
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertTrue(conflicts[0].contains("12"),
                      "El mensaje tiene que nombrar el día 12: \(conflicts[0])")
    }

    func test_los_dias_intermedios_de_un_viaje_se_miran_completos() {
        // El día 1 empieza a las 23:00 y el último acaba a las 01:00, pero el miércoles
        // de por medio está ocupado entero: una rutina de media mañana del miércoles
        // choca aunque no coincida con esas horas de los extremos.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 23, 0),
            endEpoch: date(2026, 11, 12, 1, 0),
            nodes: [routine("Clase de inglés", days: [4], startMinutes: 10 * 60, endMinutes: 11 * 60)]
        )
        XCTAssertEqual(conflicts.count, 1)
    }

    func test_un_evento_que_cruza_la_medianoche_no_se_recorta_a_una_hora() {
        // Del martes 20:00 al miércoles 06:00. Antes, al ser la hora de fin (06:00)
        // menor que la de inicio (20:00), se sustituía la duración por una hora fija:
        // 20:00–21:00. Una rutina de las 22:00 del martes quedaba fuera y no se veía.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 20, 0),
            endEpoch: date(2026, 11, 11, 6, 0),
            nodes: [routine("Dormir", days: [3], startMinutes: 22 * 60, endMinutes: 23 * 60)]
        )
        XCTAssertEqual(conflicts.count, 1)
    }

    func test_un_evento_sin_duracion_no_inventa_una_hora_de_ocupacion() {
        // "Llámame a las 10:00" no ocupa de 10:00 a 11:00. Antes sí: se le añadía una
        // hora, y eso producía choques con rutinas que empezaban más tarde.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 10, 0),
            endEpoch: date(2026, 11, 10, 10, 0),
            nodes: [routine("Gimnasio", days: [3], startMinutes: 10 * 60 + 30, endMinutes: 11 * 60)]
        )
        XCTAssertTrue(conflicts.isEmpty, "Las 10:00 no están dentro de 10:30–11:00.")
    }

    func test_un_evento_sin_duracion_dentro_de_la_rutina_si_choca() {
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 10, 45),
            endEpoch: date(2026, 11, 10, 10, 45),
            nodes: [routine("Gimnasio", days: [3], startMinutes: 10 * 60 + 30, endMinutes: 11 * 60)]
        )
        XCTAssertEqual(conflicts.count, 1, "Las 10:45 sí caen dentro de 10:30–11:00.")
    }

    func test_una_rutina_que_choca_varios_dias_se_reporta_una_sola_vez() {
        // Un viaje de cinco días contra una rutina de lunes a viernes choca cuatro
        // veces. Repetir el mismo aviso cuatro veces no informa de nada nuevo.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 14, 18, 0),
            nodes: [routine("Turno en Amazon", days: [2, 3, 4, 5, 6], startMinutes: 5 * 60, endMinutes: 16 * 60 + 30)]
        )
        XCTAssertEqual(conflicts.count, 1)
    }

    func test_una_rutina_sin_dias_no_produce_choque() {
        // `parseDays` devuelve vacío cuando no entiende los días. Una rutina así no se
        // puede comprobar, y suponerle unos días es justo la invención que se quitó.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 10, 11, 0),
            nodes: [routine("Rutina sin días", days: [], startMinutes: 10 * 60, endMinutes: 12 * 60)]
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    func test_un_rango_absurdamente_largo_no_cuelga_y_encuentra_el_choque() {
        // Un evento mal fechado de cinco años no puede hacer iterar 1800 días. Como las
        // rutinas son semanales, con una semana ya se han visto todos los días.
        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2031, 11, 10, 9, 0),
            nodes: [routine("Turno en Amazon", days: [5], startMinutes: 5 * 60, endMinutes: 16 * 60 + 30)]
        )
        XCTAssertEqual(conflicts.count, 1)
    }

    func test_ventanas_por_dia_de_un_viaje() {
        let windows = RoutineHelper.dayWindows(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 12, 18, 0)
        )
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].fromMins, 9 * 60)
        XCTAssertEqual(windows[0].toMins, 24 * 60, "El primer día queda ocupado hasta el final.")
        XCTAssertEqual(windows[1].fromMins, 0)
        XCTAssertEqual(windows[1].toMins, 24 * 60, "El día de en medio está ocupado entero.")
        XCTAssertEqual(windows[2].fromMins, 0)
        XCTAssertEqual(windows[2].toMins, 18 * 60, "El último día acaba a su hora.")
    }

    func test_ventana_de_un_solo_dia() {
        let windows = RoutineHelper.dayWindows(
            startEpoch: date(2026, 11, 10, 9, 0),
            endEpoch: date(2026, 11, 10, 11, 0)
        )
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].fromMins, 9 * 60)
        XCTAssertEqual(windows[0].toMins, 11 * 60)
    }
}
