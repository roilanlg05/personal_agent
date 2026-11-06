import Foundation

/// Protocol abstraction for URLSession to allow full unit testing with simulated responses.
protocol AtoZHTTPTransport: Sendable {
    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct DefaultAtoZHTTPTransport: AtoZHTTPTransport {
    private let session: URLSession

    /// Ephemeral session (no disk cache, no shared cookie jar) that does NOT follow redirects,
    /// so a redirect to the login page is surfaced as "session rejected" instead of HTML.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            cfg.urlCache = nil
            self.session = URLSession(configuration: cfg, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
        }
    }

    func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AtoZFailure.unknown("Respuesta no HTTP")
        }
        return (data, http)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Client responsible for executing A to Z operations with strict safety gates,
/// empirical verification, and zero exposure of secrets to the LLM.
actor AtoZClient {
    static let shared = AtoZClient()

    private let transport: AtoZHTTPTransport
    private var cachedOpportunities: [String: AtoZShiftOpportunity] = [:]
    private var pendingConfirmation: (opportunity: AtoZShiftOpportunity, expiresAt: Date)?
    private var pendingDropConfirmation: (opportunity: AtoZShiftOpportunity, expiresAt: Date)?
    private var inFlightOrUncertainIds: Set<String> = []

    init(transport: AtoZHTTPTransport = DefaultAtoZHTTPTransport()) {
        self.transport = transport
    }

    private func currentOrSyncedSession() async -> AtoZSession? {
        if let session = await AtoZSessionManager.shared.currentSession {
            return session
        }
        await AtoZSessionManager.shared.syncSessionFromServer()
        return await AtoZSessionManager.shared.currentSession
    }

    // MARK: - Query: listAvailableShifts

    func listAvailableShifts(start: Date, end: Date) async throws -> [AtoZShiftOpportunity] {
        let settings = AtoZSettings.load()
        guard settings.enabled else { throw AtoZFailure.notConfigured }
        guard !settings.suspended else { throw AtoZFailure.suspended }

        guard let session = await currentOrSyncedSession() else { throw AtoZFailure.notLoggedIn }

        // Local request validation (Guidelines §8 & §10)
        guard end > start else {
            throw AtoZFailure.invalidRequest("La fecha de fin debe ser posterior a la de inicio.")
        }
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        guard days <= AtoZConstants.maxQueryDays else {
            throw AtoZFailure.invalidRequest("El rango máximo de consulta es de \(AtoZConstants.maxQueryDays) días para evitar sobrecargar el servicio.")
        }

        let variables = AtoZGraphQL.findShiftsVariables(start: start, end: end)
        let request = try AtoZGraphQL.makeRequest(
            operationName: "FindShiftsPageMore",
            query: AtoZGraphQL.findShiftsMoreQuery,
            variables: variables,
            session: session
        )

        let (data, http) = try await transport.execute(request: request)

        // Classify HTTP transport status & bot mitigation
        if let failure = AtoZGraphQL.classifyHTTP(status: http.statusCode, headers: http.allHeaderFields, finalURL: http.url, body: data) {
            if failure.requiresSuspension {
                AtoZSettings.suspend(reason: failure.userMessage)
            }
            throw failure
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errors = json?["errors"] as? [[String: Any]], !errors.isEmpty {
            let failure = AtoZGraphQL.classifyGraphQLErrors(errors)
            if failure.requiresSuspension {
                AtoZSettings.suspend(reason: failure.userMessage)
            }
            throw failure
        }

        guard let payload = json?["data"] as? [String: Any],
              let opportunities = AtoZGraphQL.parseOpportunities(payload) else {
            throw AtoZFailure.unknown("No se pudo interpretar el listado de turnos de A to Z.")
        }

        // Cache opportunities for confirmation verification
        for opp in opportunities {
            cachedOpportunities[opp.id] = opp
        }

        return opportunities
    }

    // MARK: - Modification: addShift

    func requestAddShift(opportunityId: String, confirmed: Bool) async throws -> AtoZAddShiftResult {
        let settings = AtoZSettings.load()
        guard settings.enabled else { throw AtoZFailure.notConfigured }
        guard !settings.suspended else { throw AtoZFailure.suspended }

        guard let session = await currentOrSyncedSession() else { throw AtoZFailure.notLoggedIn }

        // Verify that the opportunity was offered to the user and is in cache (Guidelines §8)
        var opp = cachedOpportunities[opportunityId]
        if opp == nil {
            let now = Date()
            _ = try? await listAvailableShifts(start: now, end: now.addingTimeInterval(14 * 86400))
            opp = cachedOpportunities[opportunityId]
        }

        guard let opp else {
            throw AtoZFailure.invalidRequest("No encontré ese turno en las oportunidades recientes. Por favor consulta primero los turnos disponibles.")
        }

        guard opp.isEligible else {
            throw AtoZFailure.scheduleConflict
        }

        // Prevent duplicate attempts on an uncertain shift (Guidelines §5)
        if inFlightOrUncertainIds.contains(opportunityId) {
            throw AtoZFailure.invalidRequest("El estado de este turno quedó pendiente de verificación previa. No se permiten reintentos automáticos.")
        }

        // Two-step confirmation gate (Guidelines §5 & §7)
        if !confirmed {
            pendingConfirmation = (opportunity: opp, expiresAt: Date().addingTimeInterval(AtoZConstants.confirmationTTL))
            let desc = AtoZFormat.describe(opp)
            return .confirmationRequired(
                prompt: "¿Confirmas que quieres aceptar el turno del \(desc)? (Identificador: \(opp.id)). Por favor responde 'sí' para proceder."
            )
        }

        // User confirmed: clear any pending staged confirmation and proceed
        pendingConfirmation = nil

        // Safety gate: Authorization required (Guidelines §5 & §11)
        guard settings.addShiftAuthorized else {
            return .failed(.invalidRequest(
                "La aceptación de turnos está desactivada en los Ajustes de la app. Abre Ajustes (icono de engranaje) en Gemma y activa 'Autorización de aceptación de turnos' para permitir modificaciones."
            ))
        }

        // Safety gate: Dry-run check (Guidelines §10)
        if settings.dryRun {
            return .dryRun(description: "Modo simulado (dry-run): Se validó la confirmación y los parámetros para el turno \(AtoZFormat.describe(opp)). Para enviarlo realmente a Amazon, desactiva 'Modo simulado (Dry Run)' en Ajustes.")
        }

        // Mark as in-flight during the request
        inFlightOrUncertainIds.insert(opportunityId)
        defer {
            inFlightOrUncertainIds.remove(opportunityId)
        }

        let variables = AtoZGraphQL.addShiftVariables(opportunityId: opportunityId)
        let request = try AtoZGraphQL.makeRequest(
            operationName: "AddShift",
            query: AtoZGraphQL.addShiftMutation,
            variables: variables,
            session: session
        )

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.execute(request: request)
        } catch {
            return .unknownOutcome(opp, reason: "Error de red al enviar la solicitud: \(error.localizedDescription)")
        }

        if let failure = AtoZGraphQL.classifyHTTP(status: http.statusCode, headers: http.allHeaderFields, finalURL: http.url, body: data) {
            if failure.requiresSuspension {
                AtoZSettings.suspend(reason: failure.userMessage)
            }
            return .failed(failure)
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errors = json?["errors"] as? [[String: Any]], !errors.isEmpty {
            let failure = AtoZGraphQL.classifyGraphQLErrors(errors)
            if failure.requiresSuspension {
                AtoZSettings.suspend(reason: failure.userMessage)
            }
            return .failed(failure)
        }

        // Empirical Verification (Guidelines §5 & §6):
        // Verify against the user's schedule.
        do {
            let verified = try await verifyShiftOnSchedule(opportunity: opp, session: session)
            if verified {
                return .confirmed(opp)
            } else {
                return .unknownOutcome(opp, reason: "La solicitud se envió a Amazon pero el turno aún no aparece reflejado en tu horario.")
            }
        } catch {
            return .unknownOutcome(opp, reason: "No fue posible verificar el horario: \(error.localizedDescription)")
        }
    }

    private func verifyShiftOnSchedule(opportunity: AtoZShiftOpportunity, session: AtoZSession) async throws -> Bool {
        // Query schedule for the day
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: opportunity.start)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? opportunity.end.addingTimeInterval(3600)

        let variables: [String: Any] = [
            "timeRange": [
                "start": AtoZGraphQL.isoString(dayStart),
                "end": AtoZGraphQL.isoString(dayEnd)
            ]
        ]

        let request = try AtoZGraphQL.makeRequest(
            operationName: "GemmaScheduleCheck",
            query: AtoZGraphQL.scheduleQuery,
            variables: variables,
            session: session
        )

        let (data, http) = try await transport.execute(request: request)
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let scheduled = AtoZGraphQL.parseSchedule(payload) else {
            return false
        }

        // Look for matching time range
        return scheduled.contains { s in
            abs(s.start.timeIntervalSince(opportunity.start)) < 60 &&
            abs(s.end.timeIntervalSince(opportunity.end)) < 60
        }
    }

    // MARK: - Modification: dropShift

    func requestDropShift(opportunityId: String, confirmed: Bool) async throws -> AtoZDropShiftResult {
        let settings = AtoZSettings.load()
        guard settings.enabled else { throw AtoZFailure.notConfigured }
        guard !settings.suspended else { throw AtoZFailure.suspended }

        guard let session = await currentOrSyncedSession() else { throw AtoZFailure.notLoggedIn }

        var opp = cachedOpportunities[opportunityId]
        if opp == nil {
            let now = Date()
            _ = try? await listAvailableShifts(start: now, end: now.addingTimeInterval(14 * 86400))
            opp = cachedOpportunities[opportunityId]
        }

        guard let opp else {
            throw AtoZFailure.invalidRequest("No encontré ese turno en las oportunidades recientes. Por favor consulta primero los turnos disponibles o tu horario.")
        }

        if inFlightOrUncertainIds.contains(opportunityId) {
            throw AtoZFailure.invalidRequest("El estado de este turno quedó pendiente de verificación previa. No se permiten reintentos automáticos.")
        }

        if !confirmed {
            pendingDropConfirmation = (opportunity: opp, expiresAt: Date().addingTimeInterval(AtoZConstants.confirmationTTL))
            let desc = AtoZFormat.describe(opp)
            return .confirmationRequired(
                prompt: "¿Confirmas que quieres renunciar / soltar (drop) el turno del \(desc)? (Identificador: \(opp.id)). Por favor responde 'sí' para proceder."
            )
        }

        pendingDropConfirmation = nil

        guard settings.addShiftAuthorized else {
            return .failed(.invalidRequest(
                "La modificación de turnos está desactivada en los Ajustes de la app. Abre Ajustes en Gemma y activa 'Autorización de aceptación de turnos'."
            ))
        }

        if settings.dryRun {
            return .dryRun(description: "Modo simulado (dry-run): Se validó la confirmación para soltar el turno \(AtoZFormat.describe(opp)). Para enviarlo realmente a Amazon, desactiva 'Modo simulado (Dry Run)' en Ajustes.")
        }

        // Mark as in-flight during the request
        inFlightOrUncertainIds.insert(opportunityId)
        defer {
            inFlightOrUncertainIds.remove(opportunityId)
        }

        let variables = AtoZGraphQL.dropShiftVariables(opportunityId: opportunityId)
        let request = try AtoZGraphQL.makeRequest(
            operationName: "DropShift",
            query: AtoZGraphQL.dropShiftMutation,
            variables: variables,
            session: session
        )

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.execute(request: request)
        } catch {
            return .unknownOutcome(opp, reason: "Error de red al enviar la solicitud: \(error.localizedDescription)")
        }

        if let failure = AtoZGraphQL.classifyHTTP(status: http.statusCode, headers: http.allHeaderFields, finalURL: http.url, body: data) {
            if failure.requiresSuspension {
                AtoZSettings.suspend(reason: failure.userMessage)
            }
            return .failed(failure)
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errors = json?["errors"] as? [[String: Any]], !errors.isEmpty {
            let failure = AtoZGraphQL.classifyGraphQLErrors(errors)
            if failure.requiresSuspension {
                AtoZSettings.suspend(reason: failure.userMessage)
            }
            return .failed(failure)
        }

        // Empirical Verification: check that the shift is gone from the schedule
        do {
            let stillPresent = try await verifyShiftOnSchedule(opportunity: opp, session: session)
            if !stillPresent {
                return .confirmed(opp)
            } else {
                return .unknownOutcome(opp, reason: "La mutación de drop se procesó pero el turno todavía aparece en el horario oficial.")
            }
        } catch {
            return .unknownOutcome(opp, reason: "No fue posible verificar la retirada del turno: \(error.localizedDescription)")
        }
    }
}
