import XCTest
@testable import Gemma

/// LO QUE SE MUESTRA Y LO QUE SE ARCHIVA NO SON LA MISMA COSA.
///
/// La línea de estado del navegador la escribe la APP y es para el USUARIO. Viaja concatenada
/// al `text` del `.completed` porque la interfaz tiene que pintarla, pero ese mismo texto es el
/// que `HarnessModel.runAgentTurn` persiste en el servicio de memoria como «lo que dijo el
/// asistente», y de ahí pasa a los resúmenes, a la consolidación y a `reflect`. Sin el filtro,
/// un aviso de la app acaba guardado como una frase del asistente y puede terminar convertido en
/// un «insight» sobre el usuario: memoria a largo plazo contaminada con diagnóstico de la app.
///
/// Estas pruebas pasan por `consumeAgentEvents`, que es el mismo bucle que usa `runAgentTurn`:
/// su valor de retorno es LITERALMENTE lo que se archiva, y `agentLog` es lo que se ve.
@MainActor
final class AvisoDeLaAppEnElTranscriptoTests: XCTestCase {

    private func makeModel() -> (HarnessModel, AsyncStream<BrowserRelayEvent>.Continuation) {
        let (stream, cont) = AsyncStream<BrowserRelayEvent>.makeStream()
        // `almacen:` para no leer la entrada de producción del llavero: `init` → `ensureVoice()`
        // → el token del servicio de memoria.
        return (HarnessModel(browserPanels: BrowserPanelCoordinator(stream: { (stream, MandoDeMentira()) }),
                             almacen: AlmacenEnMemoria()), cont)
    }

    private func turn(_ events: [AgentEvent]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }

    private static let metrics = RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0,
                                                timeToFirstTokenSeconds: 0,
                                                peakResidentMemoryBytes: 0,
                                                draftAcceptanceRate: nil)

    /// El aviso de la app NO entra en el transcripto Y SÍ llega a la pantalla. Las dos mitades
    /// en la misma función: quitar el filtro mata la primera, y filtrar también lo que se pinta
    /// (o no pintar nada) mata la segunda.
    func test_el_aviso_de_la_app_no_se_archiva_y_si_se_muestra() async throws {
        let (model, cont) = makeModel(); defer { cont.finish() }
        let linea = try XCTUnwrap(Agent.lineaDeEstadoDelNavegador(
            herramienta: "browser_press",
            resultado: #"{"status":"error","message":"la pulsacion no llego"}"#))
        let prosa = "Ya te he puesto el vídeo."
        let archivado = await model.consumeAgentEvents(turn([
            .token(prosa),
            .token("\n\n" + linea),
            .completed(GenerationResult(text: prosa + "\n\n" + linea,
                                        metrics: Self.metrics,
                                        appNotice: linea)),
        ]))

        XCTAssertEqual(archivado, prosa, "al transcripto va la respuesta del modelo y nada más")
        XCTAssertFalse(archivado.contains("Aviso de la app"),
                       "un aviso de la app en el transcripto acaba en la consolidación: \(archivado)")
        let pintado = try XCTUnwrap(model.agentLog.last(where: { $0.role == "gemma" })?.text,
                                    "la respuesta no llegó al registro del chat")
        XCTAssertTrue(pintado.contains(linea),
                      "y al usuario SÍ se le enseña, que es para lo que la línea existe: \(pintado)")
    }

    /// Un turno normal —sin aviso— no se toca: el texto del modelo llega al transcripto entero.
    func test_un_turno_sin_aviso_llega_entero_al_transcripto() async {
        let (model, cont) = makeModel(); defer { cont.finish() }
        let archivado = await model.consumeAgentEvents(turn([
            .token("Son las tres."),
            .completed(GenerationResult(text: "Son las tres.", metrics: Self.metrics)),
        ]))
        XCTAssertEqual(archivado, "Son las tres.")
    }

    /// La función pura. Es un SUFIJO DECLARADO, no una búsqueda: si el aviso no está al final,
    /// no se quita nada. Un filtro que buscara el texto por el medio podría comerse una frase
    /// del modelo que casualmente lo contuviera.
    func test_el_filtro_solo_quita_un_sufijo_y_nunca_toca_el_texto_del_modelo() {
        let aviso = "Aviso de la app, no del modelo: X."
        XCTAssertEqual(HarnessModel.sinElAvisoDeLaApp("Hola.\n\n" + aviso, aviso: aviso), "Hola.")
        XCTAssertEqual(HarnessModel.sinElAvisoDeLaApp("Hola.", aviso: aviso), "Hola.",
                       "sin sufijo no se quita nada")
        XCTAssertEqual(HarnessModel.sinElAvisoDeLaApp(aviso + " y sigo hablando", aviso: aviso),
                       aviso + " y sigo hablando",
                       "en medio no es un sufijo: el texto del modelo no se toca")
        XCTAssertEqual(HarnessModel.sinElAvisoDeLaApp("Hola.", aviso: nil), "Hola.")
        XCTAssertEqual(HarnessModel.sinElAvisoDeLaApp("Hola.", aviso: ""), "Hola.")
        XCTAssertEqual(HarnessModel.sinElAvisoDeLaApp(aviso, aviso: aviso), "",
                       "si el modelo no dijo nada, al transcripto no va nada")
    }
}
