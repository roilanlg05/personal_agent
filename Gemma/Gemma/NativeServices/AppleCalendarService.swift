import Foundation
import EventKit

public struct CalendarEventDTO: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let notes: String?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
    }
}

extension CalendarEventDTO {
    /// Representación lista para `ToolJSONOutput`, con fechas en ISO8601.
    var jsonObject: [String: Any] {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "id": id,
            "title": title,
            "startDate": formatter.string(from: startDate),
            "endDate": formatter.string(from: endDate)
        ]
        if let location { object["location"] = location }
        if let notes { object["notes"] = notes }
        return object
    }
}

/// Por qué falló una operación de calendario.
///
/// Está tipado para que los tools puedan distinguir "falta el permiso" de "no hay
/// eventos" o "ese evento no existe": el agente tiene que pedir el permiso en el primer
/// caso y no puede afirmar que la agenda está vacía.
public enum CalendarServiceError: Error, LocalizedError, Equatable {
    case permissionDenied
    case eventNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Gemma no tiene permiso para acceder a tu calendario. Puedes concederlo en Ajustes."
        case .eventNotFound(let id):
            return "No existe ningún evento con el id \(id)."
        }
    }
}

/// Traduce un error de calendario a la respuesta JSON del tool.
enum CalendarToolFailure {
    static func json(_ error: Error) -> String {
        if let calendarError = error as? CalendarServiceError {
            switch calendarError {
            case .permissionDenied:
                return ToolJSONOutput.object([
                    "status": "permission_required",
                    "message": calendarError.localizedDescription
                ])
            case .eventNotFound:
                return ToolJSONOutput.object([
                    "status": "not_found",
                    "message": calendarError.localizedDescription
                ])
            }
        }
        return ToolJSONOutput.object([
            "status": "error",
            "message": error.localizedDescription
        ])
    }
}

public protocol CalendarManaging: Sendable {
    func requestAccess() async throws -> Bool
    func getEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEventDTO]
    func createEvent(title: String, startDate: Date, endDate: Date, location: String?, notes: String?) async throws -> CalendarEventDTO
    func updateEvent(id: String, title: String?, startDate: Date?, endDate: Date?, location: String?, notes: String?) async throws -> CalendarEventDTO
    func deleteEvent(id: String) async throws -> Bool
}

public final class EventKitCalendarManager: CalendarManaging {
    private let store: EKEventStore
    private let accessRequester: (@Sendable () async throws -> Bool)?

    /// `accessRequester` permite probar el camino "sin permiso" sin depender del estado
    /// real de EventKit en la máquina que ejecuta las pruebas.
    public init(
        store: EKEventStore = EKEventStore(),
        accessRequester: (@Sendable () async throws -> Bool)? = nil
    ) {
        self.store = store
        self.accessRequester = accessRequester
    }

    public func requestAccess() async throws -> Bool {
        if let accessRequester {
            return try await accessRequester()
        }
        if #available(iOS 17.0, macOS 14.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    public func getEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEventDTO] {
        // Sin autorización, `store.events(matching:)` devuelve una lista vacía que es
        // indistinguible de una agenda realmente vacía: el agente le decía al usuario
        // que no tenía nada apuntado en lugar de pedirle el permiso.
        guard try await requestAccess() else {
            throw CalendarServiceError.permissionDenied
        }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let ekEvents = store.events(matching: predicate)
        return ekEvents.map { ev in
            CalendarEventDTO(
                id: ev.eventIdentifier ?? UUID().uuidString,
                title: ev.title ?? "Sin título",
                startDate: ev.startDate ?? startDate,
                endDate: ev.endDate ?? endDate,
                location: ev.location,
                notes: ev.notes
            )
        }
    }

    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?
    ) async throws -> CalendarEventDTO {
        let hasAccess = try await requestAccess()
        guard hasAccess else {
            throw CalendarServiceError.permissionDenied
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = location
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents

        try store.save(event, span: .thisEvent)

        return CalendarEventDTO(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? title,
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            notes: event.notes
        )
    }

    public func updateEvent(
        id: String,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        location: String?,
        notes: String?
    ) async throws -> CalendarEventDTO {
        let hasAccess = try await requestAccess()
        guard hasAccess else {
            throw CalendarServiceError.permissionDenied
        }

        guard let event = store.event(withIdentifier: id) else {
            throw CalendarServiceError.eventNotFound(id)
        }

        if let title = title { event.title = title }
        if let startDate = startDate { event.startDate = startDate }
        if let endDate = endDate { event.endDate = endDate }
        if let location = location { event.location = location }
        if let notes = notes { event.notes = notes }

        try store.save(event, span: .thisEvent)

        return CalendarEventDTO(
            id: event.eventIdentifier ?? id,
            title: event.title ?? "Sin título",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            notes: event.notes
        )
    }

    public func deleteEvent(id: String) async throws -> Bool {
        let hasAccess = try await requestAccess()
        guard hasAccess else {
            throw CalendarServiceError.permissionDenied
        }

        guard let event = store.event(withIdentifier: id) else {
            throw CalendarServiceError.eventNotFound(id)
        }

        try store.remove(event, span: .thisEvent)
        return true
    }
}

public final class AppleCalendarService: Sendable {
    private let manager: any CalendarManaging

    public init(manager: any CalendarManaging = EventKitCalendarManager()) {
        self.manager = manager
    }

    public func getEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEventDTO] {
        return try await manager.getEvents(from: startDate, to: endDate)
    }

    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil
    ) async throws -> CalendarEventDTO {
        return try await manager.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes
        )
    }

    public func updateEvent(
        id: String,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        location: String? = nil,
        notes: String? = nil
    ) async throws -> CalendarEventDTO {
        return try await manager.updateEvent(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes
        )
    }

    public func deleteEvent(id: String) async throws -> Bool {
        return try await manager.deleteEvent(id: id)
    }
}
