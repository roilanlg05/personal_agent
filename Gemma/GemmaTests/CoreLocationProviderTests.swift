import XCTest
import CoreLocation
@testable import Gemma

/// Hardware de localización simulado: deja ver qué le pidió el proveedor y cuándo.
final class FakeLocationHardware: LocationHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: CLAuthorizationStatus
    private var _authorizationRequests = 0
    private var _locationRequests = 0

    init(status: CLAuthorizationStatus) {
        self._status = status
    }

    var hardwareAuthorizationStatus: CLAuthorizationStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    func setStatus(_ status: CLAuthorizationStatus) {
        lock.lock(); _status = status; lock.unlock()
    }

    var authorizationRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return _authorizationRequests
    }

    var locationRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return _locationRequests
    }

    func requestAuthorization() {
        lock.lock(); _authorizationRequests += 1; lock.unlock()
    }

    func requestOneShotLocation() {
        lock.lock(); _locationRequests += 1; lock.unlock()
    }
}

final class CoreLocationProviderTests: XCTestCase {

    private let fix = CLLocation(latitude: 25.76, longitude: -80.19)

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Defecto 5(a): dos peticiones solapadas no pierden continuaciones

    func test_overlapping_requests_share_one_hardware_fix() async throws {
        let hardware = FakeLocationHardware(status: .authorizedAlways)
        let provider = CoreLocationProvider(hardware: hardware, timeout: 5.0)

        async let first = provider.requestCurrentLocation()
        async let second = provider.requestCurrentLocation()

        await waitUntil { provider.pendingRequestCountForTesting == 2 }
        XCTAssertEqual(hardware.locationRequests, 1,
                       "Una sola petición en vuelo: la segunda llamada se encola, no relanza el hardware.")

        provider.handleLocations([fix])

        let a = try await first
        let b = try await second
        XCTAssertEqual(a.coordinate.latitude, fix.coordinate.latitude, accuracy: 0.0001)
        XCTAssertEqual(b.coordinate.latitude, fix.coordinate.latitude, accuracy: 0.0001)
        XCTAssertEqual(provider.pendingRequestCountForTesting, 0)
    }

    // MARK: - Defecto 5(b): espera la autorización antes de pedir la ubicación

    func test_not_determined_waits_for_authorization_before_requesting_location() async throws {
        let hardware = FakeLocationHardware(status: .notDetermined)
        let provider = CoreLocationProvider(hardware: hardware, timeout: 5.0)

        async let pending = provider.requestCurrentLocation()
        await waitUntil { hardware.authorizationRequests == 1 }

        XCTAssertEqual(hardware.authorizationRequests, 1)
        XCTAssertEqual(hardware.locationRequests, 0,
                       "No se pide la ubicación antes de que el usuario conteste el diálogo.")

        hardware.setStatus(.authorizedAlways)
        provider.handleAuthorizationChange()
        await waitUntil { hardware.locationRequests == 1 }
        XCTAssertEqual(hardware.locationRequests, 1)

        provider.handleLocations([fix])
        let location = try await pending
        XCTAssertEqual(location.coordinate.longitude, fix.coordinate.longitude, accuracy: 0.0001)
    }

    func test_denied_during_dialog_fails_with_permission_denied() async {
        let hardware = FakeLocationHardware(status: .notDetermined)
        let provider = CoreLocationProvider(hardware: hardware, timeout: 5.0)

        let task = Task { try await provider.requestCurrentLocation() }
        await waitUntil { hardware.authorizationRequests == 1 }

        hardware.setStatus(.denied)
        provider.handleAuthorizationChange()

        do {
            _ = try await task.value
            XCTFail("Permiso denegado debe propagarse como error.")
        } catch let error as LocationProviderError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
        XCTAssertEqual(hardware.locationRequests, 0)
    }

    func test_already_denied_fails_immediately() async {
        let hardware = FakeLocationHardware(status: .denied)
        let provider = CoreLocationProvider(hardware: hardware, timeout: 5.0)
        do {
            _ = try await provider.requestCurrentLocation()
            XCTFail("Permiso denegado debe propagarse como error.")
        } catch let error as LocationProviderError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
        XCTAssertEqual(hardware.authorizationRequests, 0)
        XCTAssertEqual(hardware.locationRequests, 0)
    }

    // MARK: - Defecto 5: plazo máximo

    func test_request_times_out_instead_of_hanging_forever() async {
        let hardware = FakeLocationHardware(status: .authorizedAlways)
        let provider = CoreLocationProvider(hardware: hardware, timeout: 0.2)
        do {
            _ = try await provider.requestCurrentLocation()
            XCTFail("Sin callback del delegado la llamada debe expirar, no colgarse.")
        } catch let error as LocationProviderError {
            guard case .timedOut = error else {
                return XCTFail("Se esperaba timedOut, llegó \(error)")
            }
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
        XCTAssertEqual(provider.pendingRequestCountForTesting, 0,
                       "Tras expirar no puede quedar ninguna continuación filtrada.")
    }

    func test_provider_recovers_after_a_timeout() async throws {
        let hardware = FakeLocationHardware(status: .authorizedAlways)
        let provider = CoreLocationProvider(hardware: hardware, timeout: 0.2)
        _ = try? await provider.requestCurrentLocation()

        async let second = provider.requestCurrentLocation()
        await waitUntil { provider.pendingRequestCountForTesting == 1 }
        provider.handleLocations([fix])
        let location = try await second
        XCTAssertEqual(location.coordinate.latitude, fix.coordinate.latitude, accuracy: 0.0001)
    }

    func test_hardware_failure_is_propagated() async {
        let hardware = FakeLocationHardware(status: .authorizedAlways)
        let provider = CoreLocationProvider(hardware: hardware, timeout: 5.0)
        let task = Task { try await provider.requestCurrentLocation() }
        await waitUntil { provider.pendingRequestCountForTesting == 1 }
        provider.handleFailure(NSError(domain: "CLError", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "kCLErrorDomain 1"]))
        do {
            _ = try await task.value
            XCTFail("El fallo del hardware debe propagarse.")
        } catch {
            XCTAssertTrue("\(error)".contains("kCLErrorDomain") || error is LocationProviderError, "got: \(error)")
        }
    }

    // MARK: - El tool traduce el motivo para que el agente lo explique

    func test_current_location_tool_reports_permission_denied() async throws {
        let service = LocationService(
            placeStore: PlaceStore(storageURL: nil),
            locationProvider: StubLocationProvider(error: LocationProviderError.permissionDenied)
        )
        let out = await CurrentLocationTool(locationService: service).run(argsJSON: "{}")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "got: \(out)")
        XCTAssertEqual(json["status"] as? String, "permission_denied", "got: \(out)")
    }

    func test_current_location_tool_reports_timeout() async throws {
        let service = LocationService(
            placeStore: PlaceStore(storageURL: nil),
            locationProvider: StubLocationProvider(error: LocationProviderError.timedOut(seconds: 12))
        )
        let out = await CurrentLocationTool(locationService: service).run(argsJSON: "{}")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "got: \(out)")
        XCTAssertEqual(json["status"] as? String, "timeout", "got: \(out)")
    }
}
