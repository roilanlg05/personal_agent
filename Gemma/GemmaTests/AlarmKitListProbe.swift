import XCTest
@testable import Gemma
#if os(iOS)
import AlarmKit
#endif

/// Sonda temporal: ¿qué alarmas tiene registradas la app ahora mismo en el iPhone?
///
/// El usuario dice que la alarma que Gemma reportó como puesta no aparece. Antes de
/// tocar nada hay que saber si el sistema la tiene registrada y no se ve, o si nunca
/// llegó a quedar registrada.
final class AlarmKitListProbe: XCTestCase {

    func test_probe_list_alarms() async throws {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { throw XCTSkip("iOS 26.") }
        let manager = AlarmManager.shared
        print("PROBE auth = \(manager.authorizationState)")
        let alarms = try manager.alarms
        print("PROBE total = \(alarms.count)")
        for alarm in alarms {
            print("PROBE alarm id=\(alarm.id) state=\(alarm.state) schedule=\(String(describing: alarm.schedule)) countdown=\(String(describing: alarm.countdownDuration))")
        }
        #else
        throw XCTSkip("Solo iOS.")
        #endif
    }
}
