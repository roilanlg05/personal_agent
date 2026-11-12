import Foundation
import Observation

enum FormBrokerError: Error, Equatable {
    /// Ya hay un formulario abierto: la UI solo sabe mostrar uno, y reemplazarlo en silencio
    /// dejaría colgada la llamada de herramienta del primero.
    case yaHayUnoAbierto
}

/// Intermediario entre la herramienta que pide un formulario y la vista que lo muestra.
///
/// `presenta` suspende la llamada de herramienta hasta que ocurre UNA de tres cosas: el usuario
/// envía, el usuario cancela, o vence el plazo. Las tres compiten por la misma
/// `CheckedContinuation`; reanudarla dos veces es un fallo fatal, así que todo el estado vive
/// en el hilo principal y quien resuelve primero la toma (`continuacion = nil`) y las demás
/// vías encuentran el hueco vacío y no hacen nada.
@MainActor
@Observable
final class FormBroker {
    struct PendingForm: Identifiable, Equatable {
        let id: String
        let spec: FormSpec
        /// Host de la página a la que quedarán atados los secretos del formulario (`nil` si no
        /// tiene campos `secret`). Lo pone la app, nunca el modelo.
        var origen: String? = nil
        /// El turno del agente que lo pidió (`nil` fuera de un turno, p. ej. en pruebas). Sirve
        /// para que el fin de un turno cierre solo SU formulario: ver `cancela(turno:)`.
        var turno: UUID? = nil

        /// Lo que la tarjeta enseña bajo el título cuando el formulario pide secretos. El título y
        /// las etiquetas los escribe el modelo y una página inyectada puede hacerse pasar por
        /// «Contraseña de Google» estando en evil.com; el host es la única pista que el usuario
        /// tiene de DÓNDE va a quedar su contraseña. Sin campos `secret`, nada que avisar.
        var avisoDeAtadura: String? {
            guard spec.fields.contains(where: { $0.kind == .secret }) else { return nil }
            guard let origen, !origen.isEmpty else {
                return "Atención: no se sabe a qué sitio quedará atado este secreto."
            }
            return "Se guardará para: \(origen)"
        }
    }

    /// Lo que la vista observa para mostrar la hoja. `nil` = nada abierto.
    private(set) var pendiente: PendingForm?

    /// El turno del agente en curso, o `nil` entre turnos (tras detener o mientras arranca el
    /// siguiente). Lo fija `HarnessModel`. Un `presenta` con un `turno` distinto no abre nada: es
    /// un turno abandonado que siguió corriendo, y si ocupara el hueco el turno nuevo recibiría
    /// `yaHayUnoAbierto` por un formulario que ya nadie espera.
    @ObservationIgnored var turnoVigente: UUID?

    @ObservationIgnored private var continuacion: CheckedContinuation<FormResponse, Never>?
    @ObservationIgnored private var tareaDelPlazo: Task<Void, Never>?
    @ObservationIgnored private let plazo: Duration
    @ObservationIgnored private let dormir: @Sendable (Duration) async throws -> Void

    /// `dormir` es inyectable para que las pruebas no esperen diez minutos de verdad.
    init(plazo: Duration = .seconds(600),
         dormir: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.plazo = plazo
        self.dormir = dormir
    }

    // Se permite el desmontaje fuera del hilo principal: el deinit no toca estado aislado.
    // Sin esto, un deinit aislado a MainActor hace doble liberación bajo XCTMemoryChecker
    // (macOS 26); ver ToolRegistry.swift.
    nonisolated deinit {}

    /// `origen`: el host al que quedarán atados los secretos, para que la tarjeta lo enseñe.
    /// `turno`: el turno del agente que lo pide; con uno que ya no es el vigente no se abre nada.
    func presenta(_ spec: FormSpec, origen: String? = nil, turno: UUID? = nil) async throws -> FormResponse {
        // Un llamador ya cancelado, o un turno que ya no es el vigente, no llega a ocupar el hueco
        // ni un instante: se contesta «cancelado» sin mostrar nada.
        if Task.isCancelled { return FormResponse(status: .cancelled, values: [:]) }
        if let turno, turno != turnoVigente { return FormResponse(status: .cancelled, values: [:]) }
        guard pendiente == nil else { throw FormBrokerError.yaHayUnoAbierto }
        // Id nuevo por presentación: un envío tardío del formulario anterior no puede resolver
        // el siguiente.
        let id = UUID().uuidString
        pendiente = PendingForm(id: id, spec: spec, origen: origen, turno: turno)

        // Si el turno que llamó se cancela, el formulario no puede quedarse abierto sin dueño ni
        // la llamada colgada: se resuelve como cancelado. `onCancel` corre en un hilo cualquiera,
        // por eso salta al principal; ahí `resuelve` ya filtra por id, así que si llega tarde (o
        // ya resolvió otra vía) no hace nada. Si la tarea ya venía cancelada, el salto se encola
        // detrás del cuerpo síncrono de la continuación, que ya habrá guardado la suya.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<FormResponse, Never>) in
                continuacion = c
                let plazo = self.plazo, dormir = self.dormir
                tareaDelPlazo = Task { @MainActor [weak self] in
                    // Si `dormir` lanza es porque resolvieron antes y cancelaron esta tarea.
                    do { try await dormir(plazo) } catch { return }
                    self?.resuelve(id: id, FormResponse(status: .timeout, values: [:]))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resuelve(id: id, FormResponse(status: .cancelled, values: [:]))
            }
        }
    }

    func envia(id: String, valores: [String: String]) {
        resuelve(id: id, FormResponse(status: .submitted, values: valores))
    }

    func cancela(id: String) {
        resuelve(id: id, FormResponse(status: .cancelled, values: [:]))
    }

    /// Fin de UN turno: cierra el formulario abierto solo si lo pidió ese turno. Un turno viejo
    /// cancelado que acaba tarde no puede cerrar el formulario que ya pidió el turno nuevo.
    func cancela(turno: UUID) {
        guard let p = pendiente, p.turno == turno else { return }
        resuelve(id: p.id, FormResponse(status: .cancelled, values: [:]))
    }

    /// Detener o mandar otro mensaje: lo que esté abierto se cierra como cancelado, sea de quien sea
    /// (el turno vigente es el que se abandona).
    func cancelaTodo() {
        guard let id = pendiente?.id else { return }
        resuelve(id: id, FormResponse(status: .cancelled, values: [:]))
    }

    /// Único punto por el que se reanuda. Ignora ids que no son el pendiente (envíos tardíos,
    /// dobles pulsaciones) y se lleva la continuación antes de reanudar.
    private func resuelve(id: String, _ respuesta: FormResponse) {
        guard pendiente?.id == id, let c = continuacion else { return }
        continuacion = nil
        pendiente = nil
        tareaDelPlazo?.cancel()
        tareaDelPlazo = nil
        c.resume(returning: respuesta)
    }
}
