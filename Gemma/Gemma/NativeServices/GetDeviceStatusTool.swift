import Foundation

public final class GetDeviceStatusTool: AgentTool, Sendable {
    public static let name = "get_device_status"
    public static let description = """
    Consulta el estado del dispositivo (iPhone o Mac): nivel de batería, si está \
    cargando, modo de bajo consumo y advertencia de batería baja. Si \
    'battery_level_known' es false no hay campo 'battery_percent': el sistema no ha \
    reportado el nivel y NO debes dar ninguna cifra.
    """
    public static let parameters: [AgentToolParam] = []

    private let service: DeviceStatusService

    public init(service: DeviceStatusService = DeviceStatusService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let status = await service.checkStatus()

        return ToolJSONOutput.object([
            "device": status.deviceType,
            "battery_level_known": status.batteryPercent != nil,
            "battery_percent": status.batteryPercent,
            "is_charging": status.isCharging,
            "is_low_power_mode": status.isLowPowerMode,
            "low_battery_warning": status.lowBatteryWarning,
            "summary": status.summary
        ])
    }
}
