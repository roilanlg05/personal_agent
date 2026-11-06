import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

/// Un momento del día del que se puede pedir pronóstico.
///
/// El usuario pregunta "¿cómo va a estar la tarde?" o "¿y mañana por la mañana?", no
/// "dame el pronóstico de 2026-11-10T06:00Z a 2026-11-10T12:00Z". Que el modelo elija
/// de una lista corta en vez de calcular fechas evita el error más caro: pedir el
/// pronóstico de un momento que no es el que preguntó el usuario.
///
/// Las ventanas usan la zona horaria del dispositivo, porque "la tarde" es la tarde de
/// donde está el usuario.
public enum WeatherPeriod: String, CaseIterable, Sendable, Equatable {
    case nextHour = "next_hour"
    case nextThreeHours = "next_3_hours"
    case thisMorning = "this_morning"
    case thisAfternoon = "this_afternoon"
    case thisEvening = "this_evening"
    case tonight = "tonight"
    case today = "today"
    case tomorrowMorning = "tomorrow_morning"
    case tomorrowAfternoon = "tomorrow_afternoon"
    case tomorrowEvening = "tomorrow_evening"
    case tomorrow = "tomorrow"

    /// Nombres que acepta el tool, para poder listarlos en el error.
    public static var allNames: [String] { allCases.map(\.rawValue) }

    /// Reconoce lo que manda el modelo, tolerando mayúsculas y espacios.
    ///
    /// No intenta adivinar frases libres: un periodo mal entendido daría el clima de
    /// otro momento, y es mejor devolver la lista de opciones.
    public static func parse(_ raw: String?) -> WeatherPeriod? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return WeatherPeriod(rawValue: key)
    }

    /// Nombre en español, para que el tool pueda decirle al modelo de qué habla.
    public var spanishName: String {
        switch self {
        case .nextHour: return "la próxima hora"
        case .nextThreeHours: return "las próximas tres horas"
        case .thisMorning: return "esta mañana"
        case .thisAfternoon: return "esta tarde"
        case .thisEvening: return "esta noche (tarde-noche)"
        case .tonight: return "la madrugada"
        case .today: return "lo que queda de hoy"
        case .tomorrowMorning: return "mañana por la mañana"
        case .tomorrowAfternoon: return "mañana por la tarde"
        case .tomorrowEvening: return "mañana por la noche"
        case .tomorrow: return "mañana"
        }
    }

    /// Franja horaria del periodo: día de desplazamiento y horas de inicio y fin.
    /// La hora de fin puede pasar de 24 (la madrugada termina al día siguiente).
    private var window: (dayOffset: Int, startHour: Int, endHour: Int)? {
        switch self {
        case .thisMorning: return (0, 6, 12)
        case .thisAfternoon: return (0, 12, 18)
        case .thisEvening: return (0, 18, 22)
        case .tonight: return (0, 22, 30)
        case .tomorrowMorning: return (1, 6, 12)
        case .tomorrowAfternoon: return (1, 12, 18)
        case .tomorrowEvening: return (1, 18, 22)
        default: return nil
        }
    }

    /// Convierte el periodo en un intervalo concreto.
    ///
    /// Devuelve `nil` cuando la ventana ya terminó: a las once de la noche no hay
    /// pronóstico de "esta tarde" que dar, y lo honesto es decirlo en vez de servir el
    /// de la tarde siguiente como si fuera lo que se pidió.
    ///
    /// Una ventana que ya empezó se recorta desde ahora: "esta mañana" a las diez
    /// significa lo que queda de la mañana, no un pronóstico de las seis.
    public func interval(now: Date = Date(), timeZone: TimeZone = .current) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        switch self {
        case .nextHour:
            return DateInterval(start: now, end: now.addingTimeInterval(60 * 60))
        case .nextThreeHours:
            return DateInterval(start: now, end: now.addingTimeInterval(3 * 60 * 60))
        case .today:
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return Self.clamped(start: start, end: end, now: now, clampToNow: true)
        case .tomorrow:
            guard let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        default:
            guard let window else { return nil }
            guard let base = calendar.date(byAdding: .day, value: window.dayOffset, to: calendar.startOfDay(for: now)),
                  let start = calendar.date(byAdding: .hour, value: window.startHour, to: base),
                  let end = calendar.date(byAdding: .hour, value: window.endHour, to: base) else { return nil }
            return Self.clamped(start: start, end: end, now: now, clampToNow: window.dayOffset == 0)
        }
    }

    private static func clamped(start: Date, end: Date, now: Date, clampToNow: Bool) -> DateInterval? {
        guard clampToNow else { return DateInterval(start: start, end: end) }
        guard end > now else { return nil }
        return DateInterval(start: max(start, now), end: end)
    }
}

/// El clima de una hora concreta del pronóstico.
public struct HourlyWeather: Sendable, Equatable {
    public let date: Date
    public let temperatureCelsius: Double
    public let condition: String
    public let symbolName: String
    /// Probabilidad de precipitación de 0 a 1, como la da WeatherKit.
    public let precipitationChance: Double
    public let windSpeedKmh: Double

    public init(
        date: Date,
        temperatureCelsius: Double,
        condition: String,
        symbolName: String,
        precipitationChance: Double,
        windSpeedKmh: Double
    ) {
        self.date = date
        self.temperatureCelsius = temperatureCelsius
        self.condition = condition
        self.symbolName = symbolName
        self.precipitationChance = precipitationChance
        self.windSpeedKmh = windSpeedKmh
    }
}

/// Resumen de un periodo: varias horas convertidas en algo que se puede decir en voz alta.
///
/// Una tarde son seis horas de datos, y el usuario quiere una frase. Lo que no se puede
/// hacer es promediar: un promedio esconde la tormenta de las cinco. Así que la
/// temperatura se da como rango, y la lluvia y el viento por su peor momento, que es lo
/// que decide si hay que llevar paraguas.
public struct WeatherForecastSummary: Sendable {
    public let interval: DateInterval
    public let hours: [HourlyWeather]

    /// `nil` cuando no hay ni una hora de datos: no hay nada que resumir, y un resumen
    /// vacío con ceros se leería como "0°C y sin lluvia".
    public init?(interval: DateInterval, hours: [HourlyWeather]) {
        guard !hours.isEmpty else { return nil }
        self.interval = interval
        self.hours = hours.sorted { $0.date < $1.date }
    }

    public var hourCount: Int { hours.count }

    public var minTemperatureCelsius: Double {
        Self.round(hours.map(\.temperatureCelsius).min() ?? 0)
    }

    public var maxTemperatureCelsius: Double {
        Self.round(hours.map(\.temperatureCelsius).max() ?? 0)
    }

    /// El peor momento de lluvia del periodo, no el promedio.
    public var maxPrecipitationChance: Double {
        Self.round(hours.map(\.precipitationChance).max() ?? 0, decimals: 2)
    }

    /// La racha más fuerte, por el mismo motivo que la lluvia.
    public var maxWindSpeedKmh: Double {
        Self.round(hours.map(\.windSpeedKmh).max() ?? 0)
    }

    /// La hora con más probabilidad de precipitación, para poder decir "sobre las cinco".
    public var worstHour: HourlyWeather? {
        hours.max { lhs, rhs in lhs.precipitationChance < rhs.precipitationChance }
    }

    /// La condición que más se repite; en empate, la que ocurre antes.
    public var dominantCondition: String {
        var counts: [String: Int] = [:]
        for hour in hours { counts[hour.condition, default: 0] += 1 }
        let best = counts.values.max() ?? 0
        return hours.first { counts[$0.condition] == best }?.condition ?? ""
    }

    /// Frase lista para leer, con el rango de temperatura y el aviso de lluvia.
    public var summary: String {
        let minT = Int(minTemperatureCelsius.rounded())
        let maxT = Int(maxTemperatureCelsius.rounded())
        let range = minT == maxT ? "\(minT)°C" : "entre \(minT)°C y \(maxT)°C"
        let rain = Int((maxPrecipitationChance * 100).rounded())
        var parts = ["\(dominantCondition), \(range)"]
        parts.append("probabilidad de lluvia hasta \(rain)%")
        if maxWindSpeedKmh >= 30 {
            parts.append("viento de hasta \(Int(maxWindSpeedKmh.rounded())) km/h")
        }
        return parts.joined(separator: ", ") + "."
    }

    private static func round(_ value: Double, decimals: Int = 1) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }
}

/// De dónde sale el pronóstico por horas.
public protocol WeatherForecastProviding: Sendable {
    func hourlyForecast(
        for coordinate: CLLocationCoordinate2D,
        interval: DateInterval
    ) async throws -> [HourlyWeather]
}

/// Pronóstico por horas de WeatherKit.
///
/// Se pide con fechas explícitas (`.hourly(startDate:endDate:)`) y no filtrando el
/// `hourlyForecast` de la consulta general, porque esa consulta trae solo las horas
/// próximas y "mañana por la mañana" quedaría fuera.
public final class SystemWeatherForecastProvider: WeatherForecastProviding, Sendable {
    public init() {}

    public func hourlyForecast(
        for coordinate: CLLocationCoordinate2D,
        interval: DateInterval
    ) async throws -> [HourlyWeather] {
        #if canImport(WeatherKit)
        if #available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *) {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let forecast = try await WeatherKit.WeatherService.shared.weather(
                for: location,
                including: .hourly(startDate: interval.start, endDate: interval.end)
            )
            return forecast.forecast.map { hour in
                HourlyWeather(
                    date: hour.date,
                    temperatureCelsius: hour.temperature.converted(to: .celsius).value,
                    condition: hour.condition.description,
                    symbolName: hour.symbolName,
                    precipitationChance: hour.precipitationChance,
                    windSpeedKmh: hour.wind.speed.converted(to: .kilometersPerHour).value
                )
            }
        }
        throw WeatherServiceError.providerUnavailable("WeatherKit requiere iOS 16 o macOS 13.")
        #else
        throw WeatherServiceError.providerUnavailable("WeatherKit no está disponible en esta plataforma.")
        #endif
    }
}

/// Un pronóstico junto con el sitio y el momento que de verdad cubre.
///
/// Igual que `WeatherReading`: el modelo tiene que poder citarle al usuario de qué sitio
/// y de qué horas le está hablando, en vez de la etiqueta que él pidió.
public struct WeatherForecastReading: Sendable {
    public let period: WeatherPeriod
    public let summary: WeatherForecastSummary
    public let coordinate: CLLocationCoordinate2D
    public let resolvedPlace: String?
    public let source: WeatherLocationSource
}
