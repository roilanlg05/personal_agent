import XCTest
import CoreLocation
@testable import Gemma

final class WeatherHonestyTests: XCTestCase {

    private func mockProvider(_ snapshot: WeatherSnapshot? = nil) -> MockWeatherProvider {
        MockWeatherProvider(cannedSnapshot: snapshot)
    }

    private func stubLocationService(latitude: Double, longitude: Double) -> LocationServiceWeatherLocation {
        LocationServiceWeatherLocation(locationService: LocationService(
            placeStore: PlaceStore(storageURL: nil),
            locationProvider: StubLocationProvider(location: CLLocation(latitude: latitude, longitude: longitude))
        ))
    }

    // MARK: - Defecto 2: sin coordenadas no se inventa una ciudad

    func test_weather_service_without_location_service_refuses_instead_of_guessing() async {
        let provider = mockProvider()
        let service = WeatherService(provider: provider, locationProvider: nil)
        do {
            _ = try await service.getWeather(latitude: nil, longitude: nil)
            XCTFail("Sin ubicación conocida el servicio debe fallar, no devolver San Francisco.")
        } catch let error as WeatherServiceError {
            XCTAssertEqual(error, .unknownLocation)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
        XCTAssertTrue(provider.requestedCoordinates.isEmpty,
                      "No debe consultarse el proveedor con coordenadas inventadas.")
    }

    func test_weather_service_uses_real_location_when_coordinates_are_missing() async throws {
        let provider = mockProvider()
        let service = WeatherService(
            provider: provider,
            locationProvider: stubLocationService(latitude: 25.76, longitude: -80.19)
        )
        _ = try await service.getWeather(latitude: nil, longitude: nil)
        XCTAssertEqual(provider.requestedCoordinates.count, 1)
        XCTAssertEqual(provider.requestedCoordinates.first?.latitude ?? 0, 25.76, accuracy: 0.0001)
        XCTAssertEqual(provider.requestedCoordinates.first?.longitude ?? 0, -80.19, accuracy: 0.0001)
    }

    func test_weather_service_default_is_wired_to_the_shared_location_service() {
        // Por omisión el clima mide donde está el usuario, no en unas coordenadas fijas.
        XCTAssertTrue(WeatherService().locationProviderForTesting is LocationServiceWeatherLocation)
    }

    func test_system_weather_provider_has_no_fabricated_fallback() async {
        // El proveedor real debe propagar el fallo, nunca devolver 21°C de adorno.
        let provider = SystemWeatherProvider()
        do {
            let snapshot = try await provider.weather(
                for: CLLocationCoordinate2D(latitude: 25.76, longitude: -80.19)
            )
            XCTAssertFalse(
                snapshot.temperatureCelsius == 21.0
                    && snapshot.condition == "Despejado"
                    && snapshot.windSpeedKmh == 10.0,
                "Ese valor es el clima fabricado que había que eliminar."
            )
        } catch {
            // Lo esperado sin entitlement de WeatherKit: falla, y lo dice.
        }
    }

    // MARK: - Defecto 2: el tool explica cada estado

    func test_get_weather_tool_reports_location_unknown() async throws {
        let tool = GetWeatherTool(weatherService: WeatherService(provider: mockProvider(), locationProvider: nil))
        let out = await tool.run(argsJSON: "{}")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "got: \(out)")
        XCTAssertEqual(json["status"] as? String, "location_unknown", "got: \(out)")
        XCTAssertNil(json["temperature_celsius"], "No debe haber temperatura si no se sabe dónde está.")
    }

    func test_get_weather_tool_reports_provider_error() async throws {
        let provider = mockProvider()
        provider.shouldThrowError = NSError(
            domain: "WeatherKit", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Falta el entitlement \"com.apple.weatherkit\""]
        )
        let tool = GetWeatherTool(weatherService: WeatherService(
            provider: provider,
            locationProvider: stubLocationService(latitude: 1, longitude: 2)
        ))
        let out = await tool.run(argsJSON: #"{"latitude": 1, "longitude": 2}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido aun con comillas en el error. got: \(out)")
        XCTAssertEqual(json["status"] as? String, "error", "got: \(out)")
        XCTAssertNil(json["temperature_celsius"])
        let message = try XCTUnwrap(json["message"] as? String)
        XCTAssertTrue(message.contains("com.apple.weatherkit"), "got: \(message)")
    }

    func test_get_weather_tool_describes_its_states_to_the_model() {
        let description = GetWeatherTool.description.lowercased()
        XCTAssertTrue(description.contains("location_unknown"), "got: \(GetWeatherTool.description)")
        XCTAssertTrue(description.contains("error"), "got: \(GetWeatherTool.description)")
    }

    // MARK: - Defecto 3: JSON válido

    func test_get_weather_tool_output_is_valid_json_with_hostile_strings() async throws {
        let snapshot = WeatherSnapshot(
            temperatureCelsius: 30.5,
            condition: "Lluvia \"fuerte\"",
            humidityPercentage: 80,
            windSpeedKmh: 12,
            uvIndex: 3,
            precipitationChance: 90,
            summary: "30.5°C\\nLluvia \"fuerte\"\they"
        )
        let tool = GetWeatherTool(weatherService: WeatherService(
            provider: mockProvider(snapshot),
            locationProvider: nil
        ))
        let args = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "latitude": 1.0, "longitude": 2.0, "location_name": "Miami \"centro\"\\n"
            ]),
            encoding: .utf8
        ))
        let out = await tool.run(argsJSON: args)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido. got: \(out)")
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(json["condition"] as? String, "Lluvia \"fuerte\"")
        XCTAssertEqual(json["summary"] as? String, "30.5°C\\nLluvia \"fuerte\"\they")
        // Con coordenadas explícitas no se reporta la etiqueta del modelo como sitio
        // medido: lo que describe la medición son las coordenadas.
        XCTAssertNil(json["location"])
        XCTAssertEqual(json["source"] as? String, "coordinates")
        XCTAssertEqual(json["latitude"] as? Double, 1.0)
    }
}
