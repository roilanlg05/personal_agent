import XCTest
@testable import Gemma
#if os(iOS)
import AlarmKit
import SwiftUI
#endif

/// Pruebas contra AlarmKit de verdad. Solo corren en un iPhone con iOS 26+; en macOS y
/// en el simulador se saltan.
///
/// ## Por qué existen
///
/// AlarmKit no valida nada en tiempo de compilación: una configuración inválida compila
/// igual y falla en el teléfono con `com.apple.AlarmKit.Alarm error 0`, userInfo vacío y
/// sin error subyacente. No hay forma de ver desde una prueba de escritorio si la
/// configuración que se arma es aceptable.
///
/// El fallo real que motivó esto: la presentación de la alarma incluía un bloque
/// `countdown`, que solo es válido para temporizadores. El sistema rechazaba **todas**
/// las alarmas, y el usuario veía "No se pudo poner la alarma".
///
/// Correr estas pruebas: `xcodebuild test -destination 'id=<udid-del-iphone>'
/// -only-testing:GemmaTests/AlarmKitDeviceTests`
final class AlarmKitDeviceTests: XCTestCase {

    /// El caso que fallaba: una alarma con repetición semanal y otra de un solo día.
    func test_el_sistema_acepta_las_alarmas_que_arma_gemma() async throws {
        #if os(iOS)
        let scheduler = try await authorizedScheduler()

        for daysOfWeek in [[], [2, 3, 4, 5, 6]] {
            let alarm = GemmaAlarm(
                title: "Prueba de Gemma",
                hour: 7,
                minute: 30,
                daysOfWeek: daysOfWeek
            )
            do {
                try await scheduler.schedule(alarm: alarm)
            } catch {
                let ns = error as NSError
                XCTFail("AlarmKit rechazó la alarma (días: \(daysOfWeek)): \(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            }
            try? scheduler.cancel(id: alarm.id)
        }
        #else
        throw XCTSkip("AlarmKit solo existe en iOS.")
        #endif
    }

    func test_el_sistema_acepta_los_temporizadores_que_arma_gemma() async throws {
        #if os(iOS)
        let scheduler = try await authorizedScheduler()
        let timer = GemmaTimer(label: "Prueba de Gemma", durationSeconds: 300)

        do {
            try await scheduler.scheduleCountdown(timer: timer)
        } catch {
            let ns = error as NSError
            XCTFail("AlarmKit rechazó el temporizador: \(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
        }
        try? scheduler.cancel(id: timer.id)
        #else
        throw XCTSkip("AlarmKit solo existe en iOS.")
        #endif
    }

    #if os(iOS)
    /// Salta la prueba si no hay permiso, en vez de fallar: un permiso denegado es una
    /// decisión del usuario, no un defecto del código.
    private func authorizedScheduler() async throws -> any SystemAlarmScheduling {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("AlarmKit requiere iOS 26.")
        }
        let scheduler: any SystemAlarmScheduling = AlarmKitScheduler()
        guard await scheduler.requestAuthorization() else {
            throw XCTSkip("Sin permiso de alarmas en este dispositivo.")
        }
        return scheduler
    }
    #endif
}
