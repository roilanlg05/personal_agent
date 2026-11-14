import XCTest
import CoreLocation
@testable import Gemma

final class StubPlaceGeocoder: PlaceGeocoding, @unchecked Sendable {
    var results: [String: (CLLocationCoordinate2D, String)]
    private(set) var requested: [String] = []

    init(results: [String: (CLLocationCoordinate2D, String)] = [:]) {
        self.results = results
    }

    func coordinate(forPlace name: String) async throws -> (coordinate: CLLocationCoordinate2D, resolvedName: String) {
        requested.append(name)
        guard let hit = results[name.lowercased()] else {
            throw WeatherServiceError.placeNotFound(name)
        }
        return (hit.0, hit.1)
    }
}

final class StubLocationInfoProvider: WeatherLocationProviding, @unchecked Sendable {
    var info: (coordinate: CLLocationCoordinate2D, city: String?)?
    var errorToThrow: Error?

    init(
        coordinate: CLLocationCoordinate2D? = nil,
        city: String? = nil,
        errorToThrow: Error? = nil
    ) {
        self.info = coordinate.map { ($0, city) }
        self.errorToThrow = errorToThrow
    }

    func currentCoordinate() async throws -> (coordinate: CLLocationCoordinate2D, city: String?) {
        if let errorToThrow { throw errorToThrow }
        guard let info else { throw WeatherServiceError.unknownLocation }
        return info
    }
}

/// El síntoma que reportó el usuario: el clima que sale no es el del sitio donde está.
///
/// Quitar las coordenadas fijas de San Francisco no bastaba. Quedaban tres grietas por
/// las que el sitio medido y el sitio reportado podían no coincidir, y ninguna avisaba.
final class WeatherLocationTests: XCTestCase {

    private let miami = CLLocationCoordinate2D(latitude: 25.7617, longitude: -80.1918)
    private let havana = CLLocationCoordinate2D(latitude: 23.1136, longitude: -82.3666)

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func service(
        provider: MockWeatherProvider = MockWeatherProvider(),
        location: StubLocationInfoProvider? = nil,
        geocoder: StubPlaceGeocoder = StubPlaceGeocoder()
    ) -> WeatherService {
        WeatherService(
            provider: provider,
            locationProvider: location,
            geocoder: geocoder
        )
    }

    // MARK: - Grieta 1: la etiqueta del modelo no es el sitio medido

    func test_noSeReportaLaEtiquetaDelModeloComoSitioMedido() async throws {
        // El modelo manda 'place: "Miami"' sin coordenadas y el servicio mide donde
        // está el usuario de verdad. Reportar "Miami" sería la mentira exacta que vio
        // el usuario.
        let provider = MockWeatherProvider()
        let tool = GetWeatherTool(weatherService: service(
            provider: provider,
            location: StubLocationInfoProvider(coordinate: havana, city: "La Habana")
        ))

        let result = try json(await tool.run(argsJSON: #"{"place": "Miami"}"#))

        XCTAssertEqual(result["status"] as? String, "place_not_found")
        XCTAssertNil(result["temperature_celsius"], "Sin sitio resuelto no hay clima que dar.")
        XCTAssertTrue(provider.requestedCoordinates.isEmpty)
    }

    func test_laUbicacionActualSeReportaConSuCiudadReal() async throws {
        let provider = MockWeatherProvider()
        let tool = GetWeatherTool(weatherService: service(
            provider: provider,
            location: StubLocationInfoProvider(coordinate: havana, city: "La Habana")
        ))

        let result = try json(await tool.run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["location"] as? String, "La Habana")
        XCTAssertEqual(result["source"] as? String, "current_location")
        XCTAssertEqual(result["latitude"] as? Double, havana.latitude)
        XCTAssertEqual(provider.requestedCoordinates.first?.latitude, havana.latitude)
    }

    // MARK: - Grieta 2: coordenadas a medias

    func test_coordenadaIncompletaEsUnErrorYNoCaeAlGPS() async throws {
        // Con solo la latitud, antes se ignoraba en silencio y se medía la ubicación
        // actual, así que el usuario recibía el clima de otro sitio sin saberlo.
        let provider = MockWeatherProvider()
        let tool = GetWeatherTool(weatherService: service(
            provider: provider,
            location: StubLocationInfoProvider(coordinate: havana, city: "La Habana")
        ))

        let result = try json(await tool.run(argsJSON: #"{"latitude": 25.7617}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_coordinates")
        XCTAssertTrue(provider.requestedCoordinates.isEmpty)
    }

    func test_coordenadasFueraDeRangoSeRechazan() async throws {
        let provider = MockWeatherProvider()
        let tool = GetWeatherTool(weatherService: service(provider: provider))

        let result = try json(await tool.run(argsJSON: #"{"latitude": 125.0, "longitude": -80.0}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_coordinates")
        XCTAssertTrue(provider.requestedCoordinates.isEmpty)
    }

    func test_coordenadasCompletasSeUsanTalCual() async throws {
        let provider = MockWeatherProvider()
        let tool = GetWeatherTool(weatherService: service(
            provider: provider,
            location: StubLocationInfoProvider(coordinate: havana, city: "La Habana")
        ))

        let result = try json(await tool.run(argsJSON: #"{"latitude": 25.7617, "longitude": -80.1918}"#))

        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["source"] as? String, "coordinates")
        XCTAssertEqual(provider.requestedCoordinates.first?.latitude, miami.latitude)
    }

    // MARK: - Grieta 3: el modelo no tenía forma de consultar una ciudad

    func test_elNombreDeLugarSeResuelveConElGeocodificador() async throws {
        // Sin esto, para "¿qué tiempo hace en Miami?" el modelo tenía que inventarse
        // las coordenadas, y unas coordenadas inventadas son el clima de otro sitio.
        let provider = MockWeatherProvider()
        let geocoder = StubPlaceGeocoder(results: ["miami": (miami, "Miami, Florida")])
        let tool = GetWeatherTool(weatherService: service(
            provider: provider,
            location: StubLocationInfoProvider(coordinate: havana, city: "La Habana"),
            geocoder: geocoder
        ))

        let result = try json(await tool.run(argsJSON: #"{"place": "Miami"}"#))

        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["location"] as? String, "Miami, Florida")
        XCTAssertEqual(result["source"] as? String, "place_name")
        XCTAssertEqual(provider.requestedCoordinates.first?.latitude, miami.latitude)
        XCTAssertEqual(geocoder.requested, ["Miami"])
    }

    func test_lasCoordenadasExplicitasManSobreElNombre() async throws {
        let provider = MockWeatherProvider()
        let geocoder = StubPlaceGeocoder(results: ["miami": (miami, "Miami, Florida")])
        let tool = GetWeatherTool(weatherService: service(provider: provider, geocoder: geocoder))

        _ = await tool.run(argsJSON: #"{"place": "Miami", "latitude": 23.1136, "longitude": -82.3666}"#)

        XCTAssertEqual(provider.requestedCoordinates.first?.latitude, havana.latitude)
        XCTAssertTrue(geocoder.requested.isEmpty)
    }

    // MARK: - Sin ubicación

    func test_sinUbicacionNiNombreLoDiceYNoMide() async throws {
        let provider = MockWeatherProvider()
        let tool = GetWeatherTool(weatherService: service(provider: provider, location: nil))

        let result = try json(await tool.run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "location_unknown")
        XCTAssertNil(result["temperature_celsius"])
        XCTAssertTrue(provider.requestedCoordinates.isEmpty)
    }

    func test_permisoDeUbicacionDenegadoSeDistingue() async throws {
        let tool = GetWeatherTool(weatherService: service(
            location: StubLocationInfoProvider(errorToThrow: LocationProviderError.permissionDenied)
        ))

        let result = try json(await tool.run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "location_unknown")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("permiso"))
    }

    // MARK: - Descripción

    func test_laDescripcionObligaAUsarPlaceEnVezDeInventarCoordenadas() {
        let description = GetWeatherTool.description.lowercased()
        XCTAssertTrue(description.contains("place"))
        XCTAssertTrue(description.contains("no invent") || description.contains("nunca invent"))
    }
}
