import XCTest
@testable import Gemma

final class DeviceStatusHonestyTests: XCTestCase {

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "La salida debe ser JSON válido. got: \(out)")
    }

    // MARK: - Defecto 9: la batería desconocida no se convierte en 100%

    func test_unknown_battery_level_is_reported_as_unknown() async throws {
        let provider = MockDeviceStatusProvider(deviceType: "iPhone", batteryPercent: nil, isCharging: true)
        let status = await DeviceStatusService(provider: provider).checkStatus()

        XCTAssertNil(status.batteryPercent, "Nivel desconocido es nil, no 100.")
        XCTAssertFalse(status.summary.contains("100"),
                       "El resumen no puede inventar un número. got: \(status.summary)")
        XCTAssertTrue(status.summary.lowercased().contains("no"),
                      "El resumen debe decir que no se sabe. got: \(status.summary)")
        XCTAssertFalse(status.lowBatteryWarning,
                       "Sin dato no se puede advertir de batería baja.")
    }

    func test_tool_omits_battery_percent_when_unknown() async throws {
        let provider = MockDeviceStatusProvider(deviceType: "iPhone", batteryPercent: nil, isCharging: false)
        let out = await GetDeviceStatusTool(service: DeviceStatusService(provider: provider)).run(argsJSON: "{}")
        let json = try parse(out)

        XCTAssertNil(json["battery_percent"],
                     "Sin medición no se emite un número que el modelo pueda confundir. got: \(out)")
        XCTAssertEqual(json["battery_level_known"] as? Bool, false, "got: \(out)")
    }

    func test_known_battery_level_is_reported_normally() async throws {
        let provider = MockDeviceStatusProvider(deviceType: "iPhone", batteryPercent: 8, isCharging: false)
        let out = await GetDeviceStatusTool(service: DeviceStatusService(provider: provider)).run(argsJSON: "{}")
        let json = try parse(out)

        XCTAssertEqual(json["battery_percent"] as? Int, 8)
        XCTAssertEqual(json["battery_level_known"] as? Bool, true)
        XCTAssertEqual(json["low_battery_warning"] as? Bool, true)
    }

    // MARK: - Defecto 4: el estado del dispositivo se lee desde el actor principal

    func test_system_provider_reads_device_state_off_the_tool_thread() async {
        // Llamado desde un contexto no aislado al MainActor: no debe disparar el
        // comprobador de hilo principal ni caerse.
        let status = await SystemDeviceStatusProvider().getStatus()
        XCTAssertFalse(status.deviceType.isEmpty)
        if let percent = status.batteryPercent {
            XCTAssertTrue((0...100).contains(percent), "got: \(percent)")
        }
    }
}
