import Foundation
import CoreLocation

/// Pronóstico del tiempo para un momento futuro.
///
/// Es un tool aparte de `get_weather` a propósito: lo que devuelve no es una medición
/// sino un rango de varias horas, y mezclar las dos cosas en una sola salida haría que
/// el modelo contara un pronóstico como si fuera el tiempo de ahora mismo.
public final class GetForecastTool: AgentTool, Sendable {
    public static let name = "get_forecast"
    public static let description = """
    Pronostica el tiempo de un momento futuro: dentro de un rato, esta tarde, mañana por \
    la mañana. Para el tiempo de AHORA usa get_weather, no este. 'period' es obligatorio \
    y solo acepta estos valores: next_hour, next_3_hours, this_morning, this_afternoon, \
    this_evening, tonight, today, tomorrow_morning, tomorrow_afternoon, \
    tomorrow_evening, tomorrow. Elige el que más se parezca a lo que pidió el usuario y \
    no inventes otros nombres ni fechas. Sin 'place' pronostica donde está el usuario; \
    para otro sitio pasa 'place' con la ciudad y NUNCA inventes latitud y longitud. \
    Lee 'status': 'ok' = pronóstico real, y entonces 'from' y 'to' dicen las horas que \
    cubre, 'location' el sitio, 'min_temperature_celsius' y 'max_temperature_celsius' el \
    rango, 'precipitation_chance' la probabilidad de lluvia del PEOR momento (no del \
    promedio) y 'summary' una frase lista para decir. Cítale al usuario ese 'location' y \
    ese rango de horas. 'invalid_period' = el periodo no existe, elige uno de \
    'valid_periods'. 'no_forecast' = no hay datos para ese momento: dilo, no inventes una \
    previsión. 'period_in_past' = ese momento ya pasó, pregúntale de cuándo lo quiere. \
    'place_not_found', 'location_unknown', 'invalid_coordinates' y 'error' = no hay \
    pronóstico; nunca des temperaturas con esos estados.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(
            name: "period",
            type: .string,
            description: "Momento a pronosticar: next_hour, next_3_hours, this_morning, this_afternoon, this_evening, tonight, today, tomorrow_morning, tomorrow_afternoon, tomorrow_evening, tomorrow",
            required: true
        ),
        AgentToolParam(name: "place", type: .string, description: "Ciudad o lugar; omítelo para usar la ubicación actual del usuario", required: false),
        AgentToolParam(name: "latitude", type: .number, description: "Latitud en grados decimales. Solo si el usuario te la dio; requiere longitude", required: false),
        AgentToolParam(name: "longitude", type: .number, description: "Longitud en grados decimales. Solo si el usuario te la dio; requiere latitude", required: false)
    ]

    private let weatherService: WeatherService

    public init(weatherService: WeatherService = WeatherService()) {
        self.weatherService = weatherService
    }

    public func run(argsJSON: String) async -> String {
        let rawPeriod = Self.parseString(named: "period", from: argsJSON)
        guard let period = WeatherPeriod.parse(rawPeriod) else {
            return ToolJSONOutput.object([
                "status": "invalid_period",
                "requested": rawPeriod,
                "valid_periods": WeatherPeriod.allNames,
                "message": "Periodo no reconocido. Elige uno de 'valid_periods'."
            ])
        }

        let lat = Self.parseDouble(named: "latitude", from: argsJSON)
        let lon = Self.parseDouble(named: "longitude", from: argsJSON)
        let place = Self.parseString(named: "place", from: argsJSON)

        do {
            let reading = try await weatherService.forecast(
                period: period,
                latitude: lat,
                longitude: lon,
                place: place
            )
            let summary = reading.summary
            let formatter = ISO8601DateFormatter()
            return ToolJSONOutput.object([
                "status": "ok",
                "period": period.rawValue,
                "period_name": period.spanishName,
                "from": formatter.string(from: summary.interval.start),
                "to": formatter.string(from: summary.interval.end),
                "hours_covered": summary.hourCount,
                // El sitio resuelto por el sistema, no la etiqueta que pidió el modelo.
                "location": reading.resolvedPlace,
                "latitude": reading.coordinate.latitude,
                "longitude": reading.coordinate.longitude,
                "source": reading.source.rawValue,
                "min_temperature_celsius": summary.minTemperatureCelsius,
                "max_temperature_celsius": summary.maxTemperatureCelsius,
                "condition": summary.dominantCondition,
                "precipitation_chance": Int((summary.maxPrecipitationChance * 100).rounded()),
                "rainiest_hour": summary.worstHour.map { formatter.string(from: $0.date) },
                "max_wind_speed_kmh": summary.maxWindSpeedKmh,
                "summary": summary.summary
            ])
        } catch WeatherServiceError.noForecastData(let name) {
            return ToolJSONOutput.object([
                "status": "no_forecast",
                "period": period.rawValue,
                "message": WeatherServiceError.noForecastData(name).localizedDescription
            ])
        } catch WeatherServiceError.periodInThePast(let name) {
            return ToolJSONOutput.object([
                "status": "period_in_past",
                "period": period.rawValue,
                "message": WeatherServiceError.periodInThePast(name).localizedDescription
            ])
        } catch WeatherServiceError.placeNotFound(let name) {
            return ToolJSONOutput.object([
                "status": "place_not_found",
                "requested": name,
                "message": WeatherServiceError.placeNotFound(name).localizedDescription
            ])
        } catch WeatherServiceError.invalidCoordinates(let reason) {
            return ToolJSONOutput.object([
                "status": "invalid_coordinates",
                "message": WeatherServiceError.invalidCoordinates(reason).localizedDescription
            ])
        } catch WeatherServiceError.unknownLocation {
            return ToolJSONOutput.object([
                "status": "location_unknown",
                "message": WeatherServiceError.unknownLocation.localizedDescription
            ])
        } catch let error as LocationProviderError {
            return ToolJSONOutput.object([
                "status": "location_unknown",
                "message": error.localizedDescription
            ])
        } catch {
            return ToolJSONOutput.object([
                "status": "error",
                "message": "No se pudo obtener el pronóstico: \(error.localizedDescription)"
            ])
        }
    }

    private static func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = dict[name] as? String, !val.isEmpty else {
            return nil
        }
        return val
    }

    private static func parseDouble(named name: String, from json: String) -> Double? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let d = dict[name] as? Double { return d }
        if let n = dict[name] as? NSNumber { return n.doubleValue }
        if let s = dict[name] as? String { return Double(s) }
        return nil
    }
}
