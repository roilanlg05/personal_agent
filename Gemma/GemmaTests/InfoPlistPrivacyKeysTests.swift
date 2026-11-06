import XCTest
@testable import Gemma

/// Defecto 7: llamar a una API protegida sin su clave de uso en el Info.plist termina
/// el proceso inmediatamente. Esta prueba vigila las claves de las APIs que los tools
/// usan de verdad; se lee el fichero fuente porque es lo que el target compila como
/// `INFOPLIST_FILE`.
final class InfoPlistPrivacyKeysTests: XCTestCase {

    private func appInfoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GemmaTests
            .deletingLastPathComponent()   // Gemma (raíz del proyecto Xcode)
            .appendingPathComponent("AppInfo.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    func test_required_usage_descriptions_are_present() throws {
        let plist = try appInfoPlist()
        let required = [
            // EventKit: en iOS 17+ el acceso completo tiene su propia clave, y la antigua
            // sigue haciendo falta para macOS y para el camino de compatibilidad.
            "NSCalendarsFullAccessUsageDescription",
            "NSCalendarsUsageDescription",
            // CoreLocation: get_current_location, save_place, get_weather.
            "NSLocationWhenInUseUsageDescription",
            // CoreMotion (CMMotionActivityManager): get_current_activity.
            "NSMotionUsageDescription",
            // Ya presentes antes de este encargo; se vigilan para que no desaparezcan.
            "NSContactsUsageDescription",
            "NSAppleMusicUsageDescription",
            "NSAppleEventsUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
            "NSLocalNetworkUsageDescription"
        ]
        for key in required {
            let value = plist[key] as? String
            XCTAssertNotNil(value, "Falta la clave de uso \(key) en AppInfo.plist.")
            XCTAssertFalse((value ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                           "La clave \(key) necesita un texto que explique el motivo al usuario.")
        }
    }

    func test_keys_for_the_apis_that_alarms_and_reminders_use() throws {
        let plist = try appInfoPlist()
        // Sin estas claves el proceso se termina al pedir el permiso, así que su
        // ausencia no es un aviso: es una caída en el dispositivo del usuario.
        for key in ["NSAlarmKitUsageDescription", "NSRemindersFullAccessUsageDescription"] {
            let value = plist[key] as? String
            XCTAssertFalse(
                (value ?? "").isEmpty,
                "Falta \(key): create_alarm y create_reminder usan esas APIs."
            )
        }
    }

    func test_no_usage_keys_for_apis_no_tool_uses() throws {
        let plist = try appInfoPlist()
        // Ningún tool usa cámara, fotos, salud ni Bluetooth: pedir esos permisos sería
        // mentirle al usuario sobre lo que la app necesita.
        for key in [
            "NSCameraUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSHealthShareUsageDescription",
            "NSBluetoothAlwaysUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription"
        ] {
            XCTAssertNil(plist[key], "Sobra la clave \(key): ningún tool usa esa API.")
        }
    }
}
