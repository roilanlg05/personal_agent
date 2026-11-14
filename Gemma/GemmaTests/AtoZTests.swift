import XCTest
@testable import Gemma

final class MockAtoZTransport: AtoZHTTPTransport, @unchecked Sendable {
    var handler: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))?

    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let handler else {
            throw AtoZFailure.unknown("Mock transport not configured")
        }
        return try handler(request)
    }
}

@MainActor
final class AtoZTests: XCTestCase {
    private var defaults: UserDefaults!
    private var mockTransport: MockAtoZTransport!
    private var client: AtoZClient!

    /// El almacén de secretos que tenía el gestor antes de esta suite, para devolverlo.
    private var almacenDeAntes: (any AlmacenDeSecretos)!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "AtoZTests-\(UUID().uuidString)")!
        mockTransport = MockAtoZTransport()
        client = AtoZClient(transport: mockTransport)
        // 🔴 NO LEER LA ENTRADA DE PRODUCCIÓN DEL LLAVERO. `setSession` y `clearSession` lanzan,
        // con `syncToServer` por omisión, un `Task` que habla con el servicio de memoria del i3 y
        // que por tanto PIDE SU TOKEN. Desde la Tarea 6b ese token vive en el llavero, y el host
        // de estas pruebas es la propia app: sin esta línea una corrida de la suite leería el
        // token real del usuario (y un acceso al llavero desde el binario de pruebas puede abrir
        // un diálogo del sistema y colgar la corrida de todos).
        almacenDeAntes = AtoZSessionManager.shared.almacenDeSecretos
        AtoZSessionManager.shared.almacenDeSecretos = AlmacenEnMemoria()
        // `removeFromRemote: false`: limpiar la sesión LOCAL es lo que estas pruebas quieren; el
        // `DELETE` al i3 que el valor por omisión dispara es un `Task` suelto que ni esperamos ni
        // necesitamos, y que al correr después del `tearDown` volvería a pedir el token cuando el
        // almacén de verdad ya está puesto otra vez.
        AtoZSessionManager.shared.clearSession(removeFromRemote: false)
    }

    override func tearDown() async throws {
        AtoZSessionManager.shared.clearSession(removeFromRemote: false)
        AtoZSessionManager.shared.almacenDeSecretos = almacenDeAntes
        defaults.removePersistentDomain(forName: defaults.description)
        try await super.tearDown()
    }

    // MARK: - Identity & Constants (Guidelines §2 & §3)

    func test_userAgent_isAgentGemma() {
        XCTAssertEqual(AtoZConstants.userAgent, "Agent/Gemma")
    }

    // MARK: - In-Memory Session Management (User Privacy)

    func test_session_livesOnlyInMemory() {
        let mgr = AtoZSessionManager.shared
        XCTAssertFalse(mgr.isLoggedIn)
        XCTAssertNil(mgr.currentSession)

        mgr.setSession(cookie: "secret-cookie=123", employeeId: "12345678")
        XCTAssertTrue(mgr.isLoggedIn)
        XCTAssertEqual(mgr.currentSession?.employeeId, "12345678")
        XCTAssertEqual(mgr.currentSession?.cookie, "secret-cookie=123")

        mgr.clearSession()
        XCTAssertFalse(mgr.isLoggedIn)
        XCTAssertNil(mgr.currentSession)
    }

    // MARK: - Request Building & GraphQL Fidelity

    func test_makeRequest_includesTransparentAgentHeaders() throws {
        let session = AtoZSession(cookie: "test-cookie=abc", employeeId: "999888")
        let req = try AtoZGraphQL.makeRequest(
            operationName: "FindShiftsPageMore",
            query: AtoZGraphQL.findShiftsMoreQuery,
            variables: ["test": 123],
            session: session
        )

        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "Agent/Gemma")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-atoz-client-id"), "SCHEDULE_MANAGEMENT_SERVICE")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "x-atoz-client-request-id"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "test-cookie=abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Origin"), "https://atoz.amazon.work")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), "https://atoz.amazon.work/")
        XCTAssertTrue(req.url?.query?.contains("employeeId=999888") == true)
    }

    // MARK: - HTTP & Bot Challenge Classification (Guidelines §3 & §9)

    func test_classifyHTTP_detectsChallengeAndLimits() {
        let challengeHeader = ["cf-mitigated": "challenge"]
        let fail1 = AtoZGraphQL.classifyHTTP(status: 200, headers: challengeHeader, finalURL: nil, body: Data())
        XCTAssertEqual(fail1, .accessLimited("verificación anti-bot / CAPTCHA"))

        let fail401 = AtoZGraphQL.classifyHTTP(status: 401, headers: [:], finalURL: nil, body: Data())
        XCTAssertEqual(fail401, .sessionExpired)

        let fail403 = AtoZGraphQL.classifyHTTP(status: 403, headers: [:], finalURL: nil, body: Data())
        XCTAssertEqual(fail403, .accessDenied)

        let fail429 = AtoZGraphQL.classifyHTTP(status: 429, headers: [:], finalURL: nil, body: Data())
        XCTAssertEqual(fail429, .accessLimited("demasiadas solicitudes (HTTP 429)"))
    }

    // MARK: - GraphQL Error Mapping

    func test_classifyGraphQLErrors_mapsToAtoZFailures() {
        let capacityError: [[String: Any]] = [
            ["message": "Capacity has been met for this opportunity", "errorType": "CapacityMet"]
        ]
        XCTAssertEqual(AtoZGraphQL.classifyGraphQLErrors(capacityError), .shiftUnavailable)

        let conflictError: [[String: Any]] = [
            ["message": "Shift overlaps with another scheduled shift", "errorType": "Conflict"]
        ]
        XCTAssertEqual(AtoZGraphQL.classifyGraphQLErrors(conflictError), .scheduleConflict)

        let authError: [[String: Any]] = [
            ["message": "Session expired or user unauthenticated", "errorType": "Unauthenticated"]
        ]
        XCTAssertEqual(AtoZGraphQL.classifyGraphQLErrors(authError), .sessionExpired)
    }

    // MARK: - Opportunity Parsing

    func test_parseOpportunities_extractsValidShifts() {
        let sampleData: [String: Any] = [
            "shiftOpportunities": [
                "opportunities": [
                    [
                        "id": "amzn.ls.opportunity123",
                        "type": "VOLUNTARY_EXTRA_TIME",
                        "eligibility": [
                            "isEligible": true,
                            "unclaimableReasonCodes": []
                        ],
                        "shift": [
                            "id": "shift-1",
                            "timeRange": [
                                "start": "2026-11-04T17:00:00.000Z",
                                "end": "2026-11-04T21:00:00.000Z"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let parsed = AtoZGraphQL.parseOpportunities(sampleData)
        XCTAssertEqual(parsed?.count, 1)
        let first = parsed?.first
        XCTAssertEqual(first?.id, "amzn.ls.opportunity123")
        XCTAssertEqual(first?.type, "VOLUNTARY_EXTRA_TIME")
        XCTAssertEqual(first?.isEligible, true)
        XCTAssertEqual(first?.durationMinutes, 240)
    }

    // MARK: - Tool Specifications

    func test_tools_conformToAgentTool() {
        XCTAssertEqual(ListAvailableShiftsTool.name, "list_available_shifts")
        XCTAssertEqual(ListAvailableShiftsTool.parameters.count, 2)

        XCTAssertEqual(AddShiftTool.name, "add_shift")
        XCTAssertEqual(AddShiftTool.parameters.count, 2)

        XCTAssertEqual(DropShiftTool.name, "drop_shift")
        XCTAssertEqual(DropShiftTool.parameters.count, 2)
    }

    // MARK: - Client Gates & Safety Controls

    func test_listAvailableShifts_validatesDateRange() async {
        AtoZSessionManager.shared.setSession(cookie: "cookie=1", employeeId: "123")
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.enabled)
        defer {
            UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.enabled)
        }

        let now = Date()
        // Invalid: end <= start
        do {
            _ = try await client.listAvailableShifts(start: now, end: now.addingTimeInterval(-3600))
            XCTFail("Should have thrown invalidRequest")
        } catch let failure as AtoZFailure {
            XCTAssertEqual(failure, .invalidRequest("La fecha de fin debe ser posterior a la de inicio."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Invalid: exceeds 14 days
        do {
            _ = try await client.listAvailableShifts(start: now, end: now.addingTimeInterval(15 * 86400))
            XCTFail("Should have thrown invalidRequest")
        } catch let failure as AtoZFailure {
            XCTAssertEqual(failure, .invalidRequest("El rango máximo de consulta es de 14 días para evitar sobrecargar el servicio."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_addShift_requiresConfirmationAndDryRun() async throws {
        AtoZSessionManager.shared.setSession(cookie: "cookie=1", employeeId: "123")
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.enabled)
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.dryRun)
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.addShiftAuthorized)
        defer {
            UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.enabled)
            UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.dryRun)
            UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.addShiftAuthorized)
        }

        // Stage an opportunity in client by simulating list query
        let sampleData: [String: Any] = [
            "data": [
                "shiftOpportunities": [
                    "opportunities": [
                        [
                            "id": "opp-999",
                            "type": "ADD",
                            "eligibility": ["isEligible": true, "unclaimableReasonCodes": []],
                            "shift": [
                                "id": "shift-999",
                                "timeRange": [
                                    "start": "2026-11-04T17:00:00.000Z",
                                    "end": "2026-11-04T21:00:00.000Z"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: sampleData)
        let resp = HTTPURLResponse(url: AtoZConstants.graphQLURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!

        mockTransport.handler = { _ in (data, resp) }

        let now = Date()
        let shifts = try await client.listAvailableShifts(start: now, end: now.addingTimeInterval(86400))
        XCTAssertEqual(shifts.count, 1)

        // Step 1: Unconfirmed request -> must return confirmationRequired
        let result1 = try await client.requestAddShift(opportunityId: "opp-999", confirmed: false)
        guard case .confirmationRequired(let prompt) = result1 else {
            return XCTFail("Expected confirmationRequired, got \(result1)")
        }
        XCTAssertTrue(prompt.contains("opp-999"))

        // Step 2: Confirmed request with dryRun = true -> returns dryRun notice
        let result2 = try await client.requestAddShift(opportunityId: "opp-999", confirmed: true)
        guard case .dryRun(let desc) = result2 else {
            return XCTFail("Expected dryRun, got \(result2)")
        }
        XCTAssertTrue(desc.contains("Modo simulado"))
    }

    func test_dropShift_requiresConfirmationAndDryRun() async throws {
        AtoZSessionManager.shared.setSession(cookie: "cookie=1", employeeId: "123")
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.enabled)
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.dryRun)
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.addShiftAuthorized)
        defer {
            UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.enabled)
            UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.dryRun)
            UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.addShiftAuthorized)
        }

        let sampleData: [String: Any] = [
            "data": [
                "shiftOpportunities": [
                    "opportunities": [
                        [
                            "id": "opp-drop-1",
                            "type": "DROP",
                            "eligibility": ["isEligible": true, "unclaimableReasonCodes": []],
                            "shift": [
                                "id": "shift-drop-1",
                                "timeRange": [
                                    "start": "2026-11-04T17:00:00.000Z",
                                    "end": "2026-11-04T21:00:00.000Z"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: sampleData)
        let resp = HTTPURLResponse(url: AtoZConstants.graphQLURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        mockTransport.handler = { _ in (data, resp) }

        let now = Date()
        _ = try await client.listAvailableShifts(start: now, end: now.addingTimeInterval(86400))

        // Step 1: Unconfirmed request -> must return confirmationRequired for drop
        let result1 = try await client.requestDropShift(opportunityId: "opp-drop-1", confirmed: false)
        guard case .confirmationRequired(let prompt) = result1 else {
            return XCTFail("Expected confirmationRequired, got \(result1)")
        }
        XCTAssertTrue(prompt.contains("renunciar") || prompt.contains("soltar") || prompt.contains("drop"))
        XCTAssertTrue(prompt.contains("opp-drop-1"))

        // Step 2: Confirmed request with dryRun = true -> returns dryRun notice
        let result2 = try await client.requestDropShift(opportunityId: "opp-drop-1", confirmed: true)
        guard case .dryRun(let desc) = result2 else {
            return XCTFail("Expected dryRun, got \(result2)")
        }
        XCTAssertTrue(desc.contains("Modo simulado"))
    }

    // MARK: - cURL & Cookie Parser (Session Parser)

    func test_sessionParser_extractsFromCurlCommand() {
        let curl = """
        curl 'https://atoz.amazon.work/schedule-management/graphql?employeeId=10394857' \\
          -H 'User-Agent: Mozilla/5.0' \\
          -H 'Cookie: atoz-oauth-token=token123; atoz-refresh-token=refresh456; atoz-auth-session=sess789' \\
          --data-raw '{"query": "..."}'
        """

        let result = AtoZSessionParser.parse(text: curl)
        XCTAssertEqual(result.employeeId, "10394857")
        XCTAssertEqual(result.cookie, "atoz-oauth-token=token123; atoz-refresh-token=refresh456; atoz-auth-session=sess789")
    }

    func test_sessionParser_extractsFromRawCookieAndPayload() {
        let raw = "Cookie: session-id=abc123xyz; atoz-oauth-token=foo"
        let result = AtoZSessionParser.parse(text: raw)
        XCTAssertEqual(result.cookie, "session-id=abc123xyz; atoz-oauth-token=foo")
        XCTAssertNil(result.employeeId)
    }

    func test_sessionParser_extractsFromJSONPayload() {
        let curlWithJson = """
        curl 'https://atoz.amazon.work/graphql' \\
          -H "cookie: token=abc;" \\
          -d '{"employeeId": "98765432"}'
        """
        let result = AtoZSessionParser.parse(text: curlWithJson)
        XCTAssertEqual(result.employeeId, "98765432")
        XCTAssertEqual(result.cookie, "token=abc")
    }

    func test_sessionParser_extractsChromeDashBCookieFlag() {
        let curl = """
        curl 'https://atoz-apps.amazon.work/apis/ScheduleManagementAssociateGateway/graphql?employeeId=11223344' \\
          -H 'accept: */*' \\
          -b 'atoz-oauth-token=AAA; atoz-auth-session=BBB' \\
          --data-raw '{}'
        """
        let result = AtoZSessionParser.parse(text: curl)
        XCTAssertEqual(result.employeeId, "11223344")
        XCTAssertEqual(result.cookie, "atoz-oauth-token=AAA; atoz-auth-session=BBB")
    }

    func test_sessionParser_curlWithoutCookie_returnsNil() {
        let curl = "curl 'https://atoz-apps.amazon.work/x?employeeId=11223344' -H 'accept: */*'"
        XCTAssertNil(AtoZSessionParser.parse(text: curl).cookie)
    }

    func test_sessionParser_extractsDevToolsTable() {
        let table = "Name\tValue\tDomain\tPath\n" +
            "atoz-oauth-token\tAAA\t.amazon.work\t/\n" +
            "atoz-auth-session\tBBB\t.amazon.work\t/\n"
        let result = AtoZSessionParser.parse(text: table)
        XCTAssertEqual(result.cookie, "atoz-oauth-token=AAA; atoz-auth-session=BBB")
        XCTAssertEqual(AtoZSessionParser.cookieNames(result.cookie!), ["atoz-oauth-token", "atoz-auth-session"])
    }

    func test_sessionParser_extractsFirefoxJSON() {
        let json = #"{"Request Cookies":{"b":"2","a":"1"}}"#
        XCTAssertEqual(AtoZSessionParser.parse(text: json).cookie, "a=1; b=2")
    }

    func test_classifyHTTP_redirectToLogin_isSessionExpired_withSafeDiagnostic() {
        let url = URL(string: "https://atoz-apps.amazon.work/apis/ScheduleManagementAssociateGateway/graphql")!
        let f = AtoZGraphQL.classifyHTTP(
            status: 302,
            headers: ["Location": "https://atoz.amazon.work/login?returnUrl=secret&source=ac"],
            finalURL: url, body: Data())
        XCTAssertEqual(f, .sessionExpired)
        XCTAssertEqual(AtoZDiagnostics.last, "HTTP 302 → atoz.amazon.work/login")
        XCTAssertFalse(AtoZDiagnostics.last!.contains("secret"))
    }

    func test_noSessionInMemory_isNotLoggedIn() async {
        UserDefaults.standard.set(true, forKey: AtoZSettingsKeys.enabled)
        defer { UserDefaults.standard.removeObject(forKey: AtoZSettingsKeys.enabled) }
        do {
            _ = try await client.listAvailableShifts(start: Date(), end: Date().addingTimeInterval(3600))
            XCTFail("expected notLoggedIn")
        } catch let f as AtoZFailure {
            XCTAssertEqual(f, .notLoggedIn)
        } catch { XCTFail("\(error)") }
    }

    func test_extractTokenMetadata_parsesJWTAndSub() {
        // Construct JWT with sub: 204193941 and exp in the future
        let payload = #"{"sub":"204193941","exp":1893456000,"iat":1893455100}"#
        let b64 = Data(payload.utf8).base64EncodedString()
        let cookie = "atoz-oauth-token=header.\(b64).sig; other=123"

        let meta = AtoZSessionParser.extractTokenMetadata(from: cookie)
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.employeeId, "204193941")
        XCTAssertFalse(meta?.isExpired ?? true)

        let parsed = AtoZSessionParser.parse(text: cookie)
        XCTAssertEqual(parsed.employeeId, "204193941")
    }
}
