import XCTest
import CoreLocation
@testable import Gemma

final class StubForecastProvider: WeatherForecastProviding, @unchecked Sendable {
    var hourly: [HourlyWeather]
    var errorToThrow: Error?
    private(set) var requested: [(coordinate: CLLocationCoordinate2D, interval: DateInterval)] = []

    init(hourly: [HourlyWeather] = [], errorToThrow: Error? = nil) {
        self.hourly = hourly
        self.errorToThrow = errorToThrow
    }

    func hourlyForecast(
        for coordinate: CLLocationCoordinate2D,
        interval: DateInterval
    ) async throws -> [HourlyWeather] {
        requested.append((coordinate, interval))
        if let errorToThrow { throw errorToThrow }
        return hourly.filter { interval.contains($0.date) }
    }
}

/// Traducir "mañana por la mañana" a un intervalo concreto es la parte con reglas, y
/// equivocarse ahí hace que el pronóstico sea de otro momento del día.
final class WeatherPeriodTests: XCTestCase {

    /// Lunes 2026-11-09, 10:00 en la zona del usuario.
    private var now: Date { ISO8601Dates.parse("2026-11-09T10:00:00Z")! }
    private let utc = TimeZone(identifier: "UTC")!

    private func resolve(_ period: WeatherPeriod) -> DateInterval? {
        period.interval(now: now, timeZone: utc)
    }

    func test_laProximaHoraEmpiezaAhora() throws {
        let interval = try XCTUnwrap(resolve(.nextHour))
        XCTAssertEqual(interval.start, now)
        XCTAssertEqual(interval.end, ISO8601Dates.parse("2026-11-09T11:00:00Z"))
    }

    func test_estaTardeVaDeDoceASeis() throws {
        let interval = try XCTUnwrap(resolve(.thisAfternoon))
        XCTAssertEqual(interval.start, ISO8601Dates.parse("2026-11-09T12:00:00Z"))
        XCTAssertEqual(interval.end, ISO8601Dates.parse("2026-11-09T18:00:00Z"))
    }

    func test_estaNocheCruzaLaMedianoche() throws {
        let interval = try XCTUnwrap(resolve(.tonight))
        XCTAssertEqual(interval.start, ISO8601Dates.parse("2026-11-09T22:00:00Z"))
        XCTAssertEqual(interval.end, ISO8601Dates.parse("2026-11-10T06:00:00Z"))
    }

    func test_mananaPorLaMananaEsDelDiaSiguiente() throws {
        let interval = try XCTUnwrap(resolve(.tomorrowMorning))
        XCTAssertEqual(interval.start, ISO8601Dates.parse("2026-11-10T06:00:00Z"))
        XCTAssertEqual(interval.end, ISO8601Dates.parse("2026-11-10T12:00:00Z"))
    }

    func test_mananaCompletoEsElDiaEntero() throws {
        let interval = try XCTUnwrap(resolve(.tomorrow))
        XCTAssertEqual(interval.start, ISO8601Dates.parse("2026-11-10T00:00:00Z"))
        XCTAssertEqual(interval.end, ISO8601Dates.parse("2026-11-11T00:00:00Z"))
    }

    func test_unaVentanaDeHoyQueYaEmpezoSeRecortaDesdeAhora() throws {
        // Son las 10:00 y se pregunta por "esta mañana": ya empezó, así que el
        // pronóstico cubre lo que queda, no lo que ya pasó.
        let interval = try XCTUnwrap(resolve(.thisMorning))
        XCTAssertEqual(interval.start, now)
        XCTAssertEqual(interval.end, ISO8601Dates.parse("2026-11-09T12:00:00Z"))
    }

    func test_unaVentanaDeHoyQueYaTerminoNoSeResuelve() {
        // A las 23:00 no hay pronóstico que dar de "esta tarde": ya pasó.
        let late = ISO8601Dates.parse("2026-11-09T23:00:00Z")!
        XCTAssertNil(WeatherPeriod.thisAfternoon.interval(now: late, timeZone: utc))
    }

    func test_seReconocenLosNombresQueEnviaElModelo() {
        XCTAssertEqual(WeatherPeriod.parse("next_hour"), .nextHour)
        XCTAssertEqual(WeatherPeriod.parse("tomorrow_morning"), .tomorrowMorning)
        XCTAssertEqual(WeatherPeriod.parse("TOMORROW"), .tomorrow)
        XCTAssertNil(WeatherPeriod.parse("la semana que viene"))
    }
}

/// Un pronóstico de seis horas no es un dato, son seis. Resumirlos mal haría que Gemma
/// dijera "va a hacer sol" de una tarde que incluye una tormenta.
final class WeatherForecastSummaryTests: XCTestCase {

    private func hour(_ iso: String, temp: Double, condition: String, rain: Double = 0, wind: Double = 10) -> HourlyWeather {
        HourlyWeather(
            date: ISO8601Dates.parse(iso)!,
            temperatureCelsius: temp,
            condition: condition,
            symbolName: "cloud",
            precipitationChance: rain,
            windSpeedKmh: wind
        )
    }

    private var interval: DateInterval {
        DateInterval(
            start: ISO8601Dates.parse("2026-11-09T12:00:00Z")!,
            end: ISO8601Dates.parse("2026-11-09T18:00:00Z")!
        )
    }

    func test_resumeMinimaYMaxima() throws {
        let summary = try XCTUnwrap(WeatherForecastSummary(
            interval: interval,
            hours: [
                hour("2026-11-09T12:00:00Z", temp: 24, condition: "Despejado"),
                hour("2026-11-09T15:00:00Z", temp: 29, condition: "Despejado"),
                hour("2026-11-09T17:00:00Z", temp: 22, condition: "Nublado")
            ]
        ))

        XCTAssertEqual(summary.minTemperatureCelsius, 22)
        XCTAssertEqual(summary.maxTemperatureCelsius, 29)
        XCTAssertEqual(summary.hourCount, 3)
    }

    func test_laLluviaSeReportaPorElPeorMomentoNoPorElPromedio() throws {
        // Lo que el usuario necesita saber es si va a necesitar paraguas en algún
        // momento, no la media del día.
        let summary = try XCTUnwrap(WeatherForecastSummary(
            interval: interval,
            hours: [
                hour("2026-11-09T12:00:00Z", temp: 25, condition: "Despejado", rain: 0.0),
                hour("2026-11-09T16:00:00Z", temp: 24, condition: "Lluvia", rain: 0.9)
            ]
        ))

        XCTAssertEqual(summary.maxPrecipitationChance, 0.9)
        XCTAssertEqual(summary.worstHour?.condition, "Lluvia")
    }

    func test_laCondicionDominanteEsLaMasRepetida() throws {
        let summary = try XCTUnwrap(WeatherForecastSummary(
            interval: interval,
            hours: [
                hour("2026-11-09T12:00:00Z", temp: 25, condition: "Nublado"),
                hour("2026-11-09T13:00:00Z", temp: 25, condition: "Nublado"),
                hour("2026-11-09T14:00:00Z", temp: 26, condition: "Despejado")
            ]
        ))

        XCTAssertEqual(summary.dominantCondition, "Nublado")
    }

    func test_elVientoSeReportaPorLaRachaMasFuerte() throws {
        let summary = try XCTUnwrap(WeatherForecastSummary(
            interval: interval,
            hours: [
                hour("2026-11-09T12:00:00Z", temp: 25, condition: "Despejado", wind: 8),
                hour("2026-11-09T13:00:00Z", temp: 25, condition: "Despejado", wind: 34)
            ]
        ))

        XCTAssertEqual(summary.maxWindSpeedKmh, 34)
    }

    func test_sinHorasNoHayResumenQueInventar() {
        XCTAssertNil(WeatherForecastSummary(interval: interval, hours: []))
    }

    func test_elTextoMencionaRangoYLluviaCuandoImporta() throws {
        let summary = try XCTUnwrap(WeatherForecastSummary(
            interval: interval,
            hours: [
                hour("2026-11-09T12:00:00Z", temp: 22, condition: "Nublado", rain: 0.7)
            ]
        ))

        let text = summary.summary
        XCTAssertTrue(text.contains("22"))
        XCTAssertTrue(text.contains("70"), "Debe avisar de la lluvia: \(text)")
    }
}

/// El tool tiene que decir de qué momento y de qué sitio habla, igual que `get_weather`.
final class GetForecastToolTests: XCTestCase {

    private let havana = CLLocationCoordinate2D(latitude: 23.1136, longitude: -82.3666)

    private func hours() -> [HourlyWeather] {
        (0..<48).map { offset in
            HourlyWeather(
                date: Date().addingTimeInterval(Double(offset) * 3600),
                temperatureCelsius: 25 + Double(offset % 5),
                condition: "Despejado",
                symbolName: "sun.max",
                precipitationChance: 0.1,
                windSpeedKmh: 12
            )
        }
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func tool(
        hourly: [HourlyWeather]? = nil,
        location: StubLocationInfoProvider? = nil,
        geocoder: StubPlaceGeocoder = StubPlaceGeocoder()
    ) -> GetForecastTool {
        GetForecastTool(weatherService: WeatherService(
            provider: MockWeatherProvider(),
            forecastProvider: StubForecastProvider(hourly: hourly ?? hours()),
            locationProvider: location ?? StubLocationInfoProvider(coordinate: havana, city: "La Habana"),
            geocoder: geocoder
        ))
    }

    func test_pronosticoDeLaProximaHoraEnLaUbicacionActual() async throws {
        let result = try json(await tool().run(argsJSON: #"{"period": "next_hour"}"#))

        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["location"] as? String, "La Habana")
        XCTAssertEqual(result["period"] as? String, "next_hour")
        XCTAssertNotNil(result["min_temperature_celsius"])
        XCTAssertNotNil(result["max_temperature_celsius"])
        XCTAssertNotNil(result["from"])
        XCTAssertNotNil(result["to"])
    }

    func test_pronosticoDeOtraCiudad() async throws {
        let geocoder = StubPlaceGeocoder(results: ["miami": (
            CLLocationCoordinate2D(latitude: 25.76, longitude: -80.19), "Miami, Florida"
        )])
        let result = try json(await tool(geocoder: geocoder)
            .run(argsJSON: #"{"period": "tomorrow_morning", "place": "Miami"}"#))

        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["location"] as? String, "Miami, Florida")
        XCTAssertEqual(result["source"] as? String, "place_name")
    }

    func test_unPeriodoDesconocidoSeRechazaConLaListaDeOpciones() async throws {
        let result = try json(await tool().run(argsJSON: #"{"period": "la semana que viene"}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_period")
        let options = try XCTUnwrap(result["valid_periods"] as? [String])
        XCTAssertTrue(options.contains("tomorrow_morning"))
    }

    func test_sinDatosParaEsePeriodoLoDiceYNoInventa() async throws {
        let result = try json(await tool(hourly: []).run(argsJSON: #"{"period": "tomorrow"}"#))

        XCTAssertEqual(result["status"] as? String, "no_forecast")
        XCTAssertNil(result["min_temperature_celsius"])
    }

    func test_sinUbicacionNiLugarLoPide() async throws {
        let result = try json(await tool(location: StubLocationInfoProvider())
            .run(argsJSON: #"{"period": "next_hour"}"#))

        XCTAssertEqual(result["status"] as? String, "location_unknown")
    }

    func test_laDescripcionListaLosPeriodosYProhibeInventar() {
        let description = GetForecastTool.description.lowercased()
        XCTAssertTrue(description.contains("tomorrow_morning"))
        XCTAssertTrue(description.contains("next_hour"))
        XCTAssertTrue(description.contains("no invent") || description.contains("nunca invent"))
    }
}
