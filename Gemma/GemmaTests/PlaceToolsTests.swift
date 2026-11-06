import XCTest
import CoreLocation
@testable import Gemma

/// Proveedor de ubicación de pruebas: nunca toca CoreLocation.
final class StubLocationProvider: LocationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _location: CLLocation?
    private var _error: Error?
    var requestCount = 0

    init(location: CLLocation? = nil, error: Error? = nil) {
        self._location = location
        self._error = error
    }

    func requestCurrentLocation() async throws -> CLLocation {
        lock.lock()
        requestCount += 1
        let err = _error
        let loc = _location
        lock.unlock()
        if let err { throw err }
        guard let loc else {
            throw NSError(domain: "StubLocationProvider", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "sin ubicación simulada"])
        }
        return loc
    }

    func reverseGeocode(location: CLLocation) async -> (address: String?, city: String?) {
        ("Calle \"Falsa\" 123\\n", "Ciudad")
    }
}

final class PlaceToolsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma.tests.places.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        // El ciclo completo escribe en el almacén real de la app: se limpia lo propio.
        for place in PlaceStore.shared.list() where place.name.hasPrefix("ZZTest") {
            _ = PlaceStore.shared.delete(id: place.id)
        }
    }

    private func makeStore() -> PlaceStore {
        PlaceStore(storageURL: tempDir.appendingPathComponent("places.json"))
    }

    private func stubLocationService(_ store: PlaceStore) -> LocationService {
        LocationService(
            placeStore: store,
            locationProvider: StubLocationProvider(location: CLLocation(latitude: 10, longitude: 20))
        )
    }

    // MARK: - Defecto 1: el almacén se comparte de verdad

    func test_default_place_store_is_the_shared_singleton() {
        XCTAssertTrue(SavePlaceTool().placeStoreForTesting === PlaceStore.shared)
        XCTAssertTrue(ListPlacesTool().placeStoreForTesting === PlaceStore.shared)
        XCTAssertTrue(DeletePlaceTool().placeStoreForTesting === PlaceStore.shared)
        XCTAssertTrue(OpenNavigationTool().placeStoreForTesting === PlaceStore.shared)
        XCTAssertTrue(LocationService.shared.placeStore === PlaceStore.shared)
        XCTAssertTrue(SavePlaceTool().locationServiceForTesting.placeStore === PlaceStore.shared)
    }

    func test_default_store_persists_to_disk() throws {
        XCTAssertNotNil(PlaceStore.defaultStorageURL(),
                        "El almacén por omisión debe tener un fichero en disco o no persiste nada.")
        let url = try XCTUnwrap(PlaceStore.defaultStorageURL())
        let name = "ZZTestPersistencia"
        let place = KnownPlace(name: name, latitude: 1, longitude: 2)
        PlaceStore.shared.save(place: place)

        let reloaded = PlaceStore(storageURL: url)
        XCTAssertTrue(reloaded.list().contains(where: { $0.name == name }),
                      "Lo guardado por el almacén compartido debe estar en disco.")
        _ = PlaceStore.shared.delete(id: place.id)
    }

    /// Ciclo completo con una instancia nueva de cada tool, como en producción:
    /// cada turno de conversación reconstruye los tools pero comparten el almacén.
    func test_full_cycle_with_separate_tool_instances() async throws {
        let name = "ZZTestCasaDeMarcos"

        let saveOut = await SavePlaceTool().run(
            argsJSON: #"{"name": "\#(name)", "latitude": 25.76, "longitude": -80.19}"#
        )
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saveOut.utf8)) as? [String: Any])
        XCTAssertEqual(saved["status"] as? String, "saved", "got: \(saveOut)")

        let listOut = await ListPlacesTool().run(argsJSON: "{}")
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listOut.utf8)) as? [String: Any])
        let places = try XCTUnwrap(listed["places"] as? [[String: Any]])
        XCTAssertTrue(places.contains(where: { $0["name"] as? String == name }),
                      "list_places debe ver lo que save_place acaba de guardar. got: \(listOut)")

        let opener = MockAppURLOpener(supportedSchemes: ["maps"])
        let navOut = await OpenNavigationTool(urlOpener: opener).run(
            argsJSON: #"{"destination": "\#(name)"}"#
        )
        let nav = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(navOut.utf8)) as? [String: Any])
        XCTAssertEqual(nav["status"] as? String, "navigating", "got: \(navOut)")
        XCTAssertEqual(opener.openedURLs.count, 1)

        let delOut = await DeletePlaceTool().run(argsJSON: #"{"id_or_name": "\#(name)"}"#)
        let del = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(delOut.utf8)) as? [String: Any])
        XCTAssertEqual(del["status"] as? String, "deleted", "got: \(delOut)")

        let afterOut = await ListPlacesTool().run(argsJSON: "{}")
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(afterOut.utf8)) as? [String: Any])
        let remaining = try XCTUnwrap(after["places"] as? [[String: Any]])
        XCTAssertFalse(remaining.contains(where: { $0["name"] as? String == name }))
    }

    // MARK: - Defecto 1 (nota): save_place actualiza en vez de duplicar

    func test_save_place_updates_instead_of_duplicating() async throws {
        let store = makeStore()
        let tool = SavePlaceTool(placeStore: store, locationService: stubLocationService(store))

        let first = await tool.run(argsJSON: #"{"name": "Oficina", "latitude": 1.0, "longitude": 2.0}"#)
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let firstPlace = try XCTUnwrap(firstJSON["place"] as? [String: Any])
        let firstID = try XCTUnwrap(firstPlace["id"] as? String)

        let second = await tool.run(argsJSON: #"{"name": "  oficina ", "latitude": 3.0, "longitude": 4.0}"#)
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])
        XCTAssertEqual(secondJSON["status"] as? String, "updated", "got: \(second)")
        let secondPlace = try XCTUnwrap(secondJSON["place"] as? [String: Any])
        XCTAssertEqual(secondPlace["id"] as? String, firstID, "Debe reusar el id, no crear otro lugar.")

        XCTAssertEqual(store.list().count, 1, "No debe acumular duplicados del mismo nombre.")
        XCTAssertEqual(store.list().first?.latitude, 3.0, "Debe quedarse con las coordenadas nuevas.")
    }

    func test_save_place_without_coordinates_uses_location_service() async throws {
        let store = makeStore()
        let tool = SavePlaceTool(placeStore: store, locationService: stubLocationService(store))
        let out = await tool.run(argsJSON: #"{"name": "Aquí"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let place = try XCTUnwrap(json["place"] as? [String: Any])
        XCTAssertEqual(place["latitude"] as? Double, 10)
        XCTAssertEqual(place["longitude"] as? Double, 20)
    }

    // MARK: - Defecto 3: JSON válido con comillas, barras y saltos de línea

    private let nasty = "Casa de \"Marcos\"\\nTab\there"

    func test_save_place_output_is_valid_json_with_hostile_name() async throws {
        let store = makeStore()
        let tool = SavePlaceTool(placeStore: store, locationService: stubLocationService(store))
        let args = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: ["name": nasty, "latitude": 1.5, "longitude": 2.5]),
            encoding: .utf8
        ))
        let out = await tool.run(argsJSON: args)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido. got: \(out)")
        let place = try XCTUnwrap(json["place"] as? [String: Any])
        XCTAssertEqual(place["name"] as? String, nasty)
    }

    func test_delete_place_output_is_valid_json_with_hostile_name() async throws {
        let store = makeStore()
        store.save(place: KnownPlace(name: nasty, latitude: 1, longitude: 2))
        let out = await DeletePlaceTool(placeStore: store).run(
            argsJSON: try XCTUnwrap(String(
                data: JSONSerialization.data(withJSONObject: ["id_or_name": nasty]), encoding: .utf8))
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido. got: \(out)")
        XCTAssertEqual(json["status"] as? String, "deleted")
        XCTAssertEqual(json["place"] as? String, nasty)
    }

    func test_delete_place_ambiguity_output_is_valid_json() async throws {
        let store = makeStore()
        store.save(place: KnownPlace(name: "Casa de \"Marcos\" uno", latitude: 1, longitude: 2))
        store.save(place: KnownPlace(name: "Casa de \"Marcos\" dos", latitude: 3, longitude: 4))
        let out = await DeletePlaceTool(placeStore: store).run(
            argsJSON: #"{"id_or_name": "Casa de \"Marcos\""}"#
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido. got: \(out)")
        XCTAssertNotNil(json["error"] ?? json["candidates"])
        XCTAssertEqual(store.list().count, 2, "Ante la ambigüedad no borra nada.")
    }

    func test_open_navigation_output_is_valid_json_with_hostile_name() async throws {
        let store = makeStore()
        store.save(place: KnownPlace(name: nasty, latitude: 1, longitude: 2))
        let opener = MockAppURLOpener(supportedSchemes: ["maps"])
        let out = await OpenNavigationTool(placeStore: store, urlOpener: opener).run(
            argsJSON: try XCTUnwrap(String(
                data: JSONSerialization.data(withJSONObject: ["destination": nasty]), encoding: .utf8))
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido. got: \(out)")
        XCTAssertEqual(json["status"] as? String, "navigating")
        XCTAssertEqual(json["place"] as? String, nasty)
    }

    func test_open_navigation_ambiguous_output_is_valid_json() async throws {
        let store = makeStore()
        store.save(place: KnownPlace(name: "Casa de \"Marcos\" uno", latitude: 1, longitude: 2))
        store.save(place: KnownPlace(name: "Casa de \"Marcos\" dos", latitude: 3, longitude: 4))
        let opener = MockAppURLOpener(supportedSchemes: ["maps"])
        let out = await OpenNavigationTool(placeStore: store, urlOpener: opener).run(
            argsJSON: #"{"destination": "Casa de \"Marcos\""}"#
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido. got: \(out)")
        XCTAssertEqual(json["status"] as? String, "ambiguous")
        XCTAssertEqual((json["candidates"] as? [String])?.count, 2)
        XCTAssertTrue(opener.openedURLs.isEmpty, "Ante la ambigüedad no abre nada.")
    }

    func test_current_location_output_is_valid_json_with_hostile_address() async throws {
        let store = makeStore()
        store.save(place: KnownPlace(name: nasty, latitude: 10, longitude: 20))
        let service = LocationService(
            placeStore: store,
            locationProvider: StubLocationProvider(location: CLLocation(latitude: 10, longitude: 20))
        )
        let out = await CurrentLocationTool(locationService: service).run(argsJSON: "{}")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "La salida debe ser JSON válido. got: \(out)")
        XCTAssertEqual(json["status"] as? String, "certain")
        XCTAssertEqual(json["place"] as? String, nasty)
        XCTAssertEqual(json["address"] as? String, "Calle \"Falsa\" 123\\n")
    }

    // MARK: - Defecto 4: la navegación abre URLs por el actor principal

    func test_open_navigation_uses_async_url_opener() async throws {
        let store = makeStore()
        store.save(place: KnownPlace(name: "Oficina", latitude: 1, longitude: 2))
        let opener = MockAppURLOpener(supportedSchemes: ["maps"])
        let out = await OpenNavigationTool(placeStore: store, urlOpener: opener).run(
            argsJSON: #"{"destination": "Oficina"}"#
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(json["opened"] as? Bool, true, "got: \(out)")
        XCTAssertEqual(opener.openedURLs.first?.scheme, "maps")
    }

    func test_open_navigation_reports_failure_honestly() async throws {
        let store = makeStore()
        store.save(place: KnownPlace(name: "Oficina", latitude: 1, longitude: 2))
        let opener = MockAppURLOpener(supportedSchemes: ["maps"])
        opener.shouldSucceed = false
        let out = await OpenNavigationTool(placeStore: store, urlOpener: opener).run(
            argsJSON: #"{"destination": "Oficina"}"#
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "failed",
                       "Si no se pudo abrir Maps, el tool no debe decir que está navegando. got: \(out)")
    }
}
