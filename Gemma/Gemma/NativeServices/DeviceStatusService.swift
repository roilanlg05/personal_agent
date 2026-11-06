import Foundation
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

public struct DeviceStatus: Codable, Sendable {
    public let deviceType: String
    /// Porcentaje de batería, o `nil` cuando el sistema todavía no lo sabe.
    ///
    /// Es opcional a propósito: `UIDevice.batteryLevel` vale `-1` hasta que la
    /// monitorización está realmente activa (y siempre en el simulador), y el código
    /// convertía cualquier valor negativo en 100. La primera llamada de la vida del
    /// proceso respondía "100% de batería" en un teléfono al 8%.
    public let batteryPercent: Int?
    public let isCharging: Bool
    public let isLowPowerMode: Bool
    public let lowBatteryWarning: Bool
    public let summary: String

    public init(
        deviceType: String,
        batteryPercent: Int?,
        isCharging: Bool,
        isLowPowerMode: Bool,
        lowBatteryWarning: Bool,
        summary: String
    ) {
        self.deviceType = deviceType
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isLowPowerMode = isLowPowerMode
        self.lowBatteryWarning = lowBatteryWarning
        self.summary = summary
    }

    /// Construye el estado y su resumen a partir de los datos crudos, para que el texto
    /// no pueda contradecir a los campos.
    public static func make(
        deviceType: String,
        batteryPercent: Int?,
        isCharging: Bool,
        isLowPowerMode: Bool
    ) -> DeviceStatus {
        let chargingStr = isCharging ? "cargando" : "en batería"
        guard let percent = batteryPercent else {
            return DeviceStatus(
                deviceType: deviceType,
                batteryPercent: nil,
                isCharging: isCharging,
                isLowPowerMode: isLowPowerMode,
                lowBatteryWarning: false,
                summary: "No se pudo leer el nivel de batería de tu \(deviceType) "
                    + "(el sistema aún no lo reporta). Está \(chargingStr)."
            )
        }
        let isLow = percent <= 20 && !isCharging
        let warningStr = isLow ? " Carga baja, te recomiendo conectar tu \(deviceType) pronto." : ""
        return DeviceStatus(
            deviceType: deviceType,
            batteryPercent: percent,
            isCharging: isCharging,
            isLowPowerMode: isLowPowerMode,
            lowBatteryWarning: isLow,
            summary: "Tu \(deviceType) tiene \(percent)% de batería (\(chargingStr)).\(warningStr)"
        )
    }
}

/// `getStatus()` es `async` porque en iOS la lectura real toca `UIDevice.current`, que
/// solo puede consultarse desde el actor principal, y los tools corren fuera de él.
public protocol DeviceStatusProviding: Sendable {
    func getStatus() async -> DeviceStatus
}

public final class MockDeviceStatusProvider: DeviceStatusProviding, @unchecked Sendable {
    public var deviceType: String = "iPhone"
    public var batteryPercent: Int?
    public var isCharging: Bool = false
    public var isLowPowerMode: Bool = false

    public init(deviceType: String = "iPhone", batteryPercent: Int? = 15, isCharging: Bool = false, isLowPowerMode: Bool = false) {
        self.deviceType = deviceType
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isLowPowerMode = isLowPowerMode
    }

    public func getStatus() async -> DeviceStatus {
        DeviceStatus.make(
            deviceType: deviceType,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            isLowPowerMode: isLowPowerMode
        )
    }
}

public final class SystemDeviceStatusProvider: DeviceStatusProviding, Sendable {
    public init() {}

    public func getStatus() async -> DeviceStatus {
        #if canImport(UIKit)
        return await Self.readFromMainActor()
        #elseif os(macOS)
        let (percent, isCharging) = Self.macBatteryInfo()
        return DeviceStatus.make(
            deviceType: "Mac",
            batteryPercent: percent,
            isCharging: isCharging,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        #else
        return DeviceStatus.make(
            deviceType: "Dispositivo",
            batteryPercent: nil,
            isCharging: false,
            isLowPowerMode: false
        )
        #endif
    }

    #if canImport(UIKit)
    /// Activa la monitorización antes de leer y, si el nivel sigue siendo desconocido,
    /// lo reporta como desconocido en lugar de inventar un número.
    @MainActor
    private static func readFromMainActor() async -> DeviceStatus {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
            // Tras activarla, `batteryLevel` puede seguir en -1 durante un instante.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        var level = device.batteryLevel
        if level < 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            level = device.batteryLevel
        }

        let percent: Int? = level >= 0 ? Int((level * 100.0).rounded()) : nil
        let state = device.batteryState
        return DeviceStatus.make(
            deviceType: device.model,
            batteryPercent: percent,
            isCharging: state == .charging || state == .full,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
    #endif

    #if os(macOS)
    /// `nil` cuando no hay fuente de alimentación legible (por ejemplo un Mac de
    /// sobremesa): antes se devolvía 100% y "cargando", que es falso.
    private static func macBatteryInfo() -> (percent: Int?, isCharging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false)
        }

        for ps in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] {
                let current = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
                let max = desc[kIOPSMaxCapacityKey] as? Int ?? -1
                let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                if current >= 0 && max > 0 {
                    let pct = Int((Double(current) / Double(max) * 100.0).rounded())
                    return (pct, isCharging)
                }
            }
        }
        return (nil, false)
    }
    #endif
}

public final class DeviceStatusService: Sendable {
    private let provider: any DeviceStatusProviding

    public init(provider: any DeviceStatusProviding = SystemDeviceStatusProvider()) {
        self.provider = provider
    }

    public func checkStatus() async -> DeviceStatus {
        await provider.getStatus()
    }
}
