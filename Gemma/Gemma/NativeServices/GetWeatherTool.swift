import Foundation
import CoreLocation

public final class GetWeatherTool: AgentTool, Sendable {
    public static let name = "get_weather"
    public static let description = """
    Consulta el clima actual (temperatura, humedad, viento, probabilidad de lluvia). Sin \
    argumentos mide donde está el usuario. Para otro sitio pasa 'place' con el nombre de \
    la ciudad y Gemma lo resuelve: NUNCA inventes latitud y longitud, porque unas \
    coordenadas inventadas devuelven el clima de otro lugar. Usa 'latitude' y 'longitude' \
    solo si el usuario te las dio, y siempre las dos juntas. Lee 'status': 'ok' = \
    medición real, y entonces 'location', 'latitude' y 'longitude' dicen el sitio que de \
    verdad se midió, y 'source' de dónde salió; cítale al usuario ese 'location' y no el \
    nombre que tú pediste. 'place_not_found' = no existe ese sitio, pide que lo escriba \
    de otra forma. 'location_unknown' = no se sabe dónde está el usuario, pídele la \
    ciudad. 'invalid_coordinates' = las coordenadas estaban mal. 'error' = el servicio de \
    clima falló. Con cualquier estado distinto de 'ok' no hay temperatura: dilo, no \
    inventes datos.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "place", type: .string, description: "Ciudad o lugar a consultar; omítelo para usar la ubicación actual del usuario", required: false),
        AgentToolParam(name: "latitude", type: .number, description: "Latitud en grados decimales. Solo si el usuario te la dio; requiere longitude", required: false),
        AgentToolParam(name: "longitude", type: .number, description: "Longitud en grados decimales. Solo si el usuario te la dio; requiere latitude", required: false)
    ]

    private let weatherService: WeatherService

    public init(weatherService: WeatherService = WeatherService()) {
        self.weatherService = weatherService
    }

    public func run(argsJSON: String) async -> String {
        let lat = parseDouble(named: "latitude", from: argsJSON)
        let lon = parseDouble(named: "longitude", from: argsJSON)
        // 'location_name' era el nombre antiguo del parámetro, cuando solo servía de
        // etiqueta. Se sigue aceptando para que un modelo con el hábito viejo no falle.
        let place = parseString(named: "place", from: argsJSON)
            ?? parseString(named: "location_name", from: argsJSON)

        do {
            let reading = try await weatherService.reading(latitude: lat, longitude: lon, place: place)
            let snap = reading.snapshot
            return ToolJSONOutput.object([
                "status": "ok",
                // El sitio medido, resuelto por el sistema. No la etiqueta del modelo.
                "location": reading.resolvedPlace,
                "latitude": reading.coordinate.latitude,
                "longitude": reading.coordinate.longitude,
                "source": reading.source.rawValue,
                "temperature_celsius": snap.temperatureCelsius,
                "condition": snap.condition,
                "humidity_percentage": Int(snap.humidityPercentage),
                "wind_speed_kmh": snap.windSpeedKmh,
                "uv_index": snap.uvIndex,
                "precipitation_chance": Int(snap.precipitationChance),
                "summary": snap.summary
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
            // No se pudo saber dónde está el usuario: es el mismo caso práctico.
            return ToolJSONOutput.object([
                "status": "location_unknown",
                "message": error.localizedDescription
            ])
        } catch {
            return ToolJSONOutput.object([
                "status": "error",
                "message": "No se pudo obtener el clima: \(error.localizedDescription)"
            ])
        }
    }

    private func parseDouble(named name: String, from json: String) -> Double? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let d = dict[name] as? Double { return d }
        if let n = dict[name] as? NSNumber { return n.doubleValue }
        if let s = dict[name] as? String { return Double(s) }
        return nil
    }

    private func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = dict[name] as? String, !val.isEmpty else {
            return nil
        }
        return val
    }
}
