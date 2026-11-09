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

    /// LA ÚNICA DE LAS OCHENTA HERRAMIENTAS DEL REGISTRO QUE NO DECLARABA `status`, Y ESO ERAN
    /// DOS DEFECTOS DEL MISMO TAMAÑO.
    ///
    ///  1. **La fila mentía por omisión.** `ToolLogRow.summarize` enumera el FALLO y no el
    ///     éxito, así que un objeto sin `status` no entraba en ninguna rama conocida, caía en
    ///     `case nil` y se resumía «listo» con tilde verde. No era falso, pero escondía el dato
    ///     que el usuario había pedido. Esa mitad la arregla la entrada `.battery` de
    ///     `ToolLogRow.table`, que pinta el porcentaje.
    ///  2. **Su éxito nunca reiniciaba el presupuesto de fallos del turno.**
    ///     `Agent.reiniciaElPresupuesto` exige un `status` de `Agent.estadosDeExito`, así que
    ///     preguntar por la batería NO borraba los fallos anteriores: cuatro fallos + una
    ///     consulta de batería correcta + un fallo mataban el turno. Es la peor de las dos
    ///     porque no se ve en ninguna pantalla.
    ///
    /// SE DECLARA `success` Y NO UN VERBO PROPIO (`ok`). `ok` es hoy un éxito HUÉRFANO en
    /// veintiuna herramientas del registro —está fuera de `Agent.estadosDeExito`— y meterlo en
    /// el conjunto por su nombre es exactamente lo que el hallazgo de `cancelled` prohíbe: el
    /// nombre de un estado no basta para decidir qué significa. `success` ya está en el conjunto
    /// y significa esto mismo en el resto del registro.
    ///
    /// Y EL CONTRATO SE AÑADE, NO SUSTITUYE: las siete claves que ya emitía siguen intactas,
    /// `battery_percent` incluida con su ausencia significativa (ver `battery_level_known`).
    /// Lo mide `ElFalloPintadoComoExitoTests`.
    public func run(argsJSON: String) async -> String {
        let status = await service.checkStatus()

        return ToolJSONOutput.object([
            "status": "success",
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
