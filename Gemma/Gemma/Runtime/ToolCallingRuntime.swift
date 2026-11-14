import Foundation

public enum ToolActivity: Sendable {
    case started(name: String, args: String)
    case finished(name: String, result: String)
}

@MainActor
public final class ToolActivityRelay {
    public static let shared = ToolActivityRelay()
    public var sink: ((ToolActivity) -> Void)?
    public init() {}
    // Keep the type @MainActor (app/UI-owned), but allow off-main teardown — its deinit does
    // no main-actor work. Avoids the MainActor-isolated-deinit double-free under
    // XCTMemoryChecker (macOS 26 XCTest).
    nonisolated deinit {}
    public func started(name: String, args: String) { sink?(.started(name: name, args: args)) }
    public func finished(name: String, result: String) { sink?(.finished(name: name, result: result)) }
}

/// A runtime that can run a generation with agent tools and stream tool-call events.
public protocol ToolCallingRuntime: AnyObject {
    func generate(
        prompt: String,
        tools: [AgentTool],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error>

    /// Ventana de contexto del runtime en tokens, cuando la conoce.
    ///
    /// `nil` significa «no la declaro»: es el caso de los runtimes de servidor, donde la
    /// ventana la fija el modelo remoto y es holgada. Quien decide con esto (`Agent`) trata
    /// `nil` como «cabe».
    ///
    /// Existe por una razón concreta: el bloque de la guía del navegador son ~17 KB, y en el
    /// camino on-device (`LlamaCppRuntime`, ventana de 4096 por defecto) `LlamaContext` no
    /// revienta cuando el prompt no cabe — DESLIZA la ventana y se come el medio en silencio.
    /// Lo que se cae por ese agujero puede ser el prompt del sistema, que es donde viven las
    /// reglas de seguridad. Ver `Agent.browserGuideFits`.
    var contextTokenBudget: Int? { get }
}

public extension ToolCallingRuntime {
    /// Por omisión, un runtime no declara ventana. Los dobles de test y los runtimes de
    /// servidor se quedan con esto.
    var contextTokenBudget: Int? { nil }
}
