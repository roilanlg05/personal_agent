import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Gemma

/// Cableado del panel del navegador en el chat: la entrada del historial, el cierre del panel al
/// detener el turno y la decodificación del frame fuera del hilo principal.
@MainActor
final class BrowserPanelWiringTests: XCTestCase {
    /// Modelo con un coordinador cuya fábrica siempre devuelve un flujo (Ruling 40): sin esto,
    /// en pruebas no hay `browserBaseURL` y `openIfNeeded` devolvería `nil`.
    /// La continuación se devuelve para que la prueba mantenga el flujo abierto.
    static func makeModel() -> (HarnessModel, AsyncStream<BrowserRelayEvent>.Continuation) {
        let (stream, continuation) = AsyncStream<BrowserRelayEvent>.makeStream()
        let coordinator = BrowserPanelCoordinator(stream: { stream })
        return (HarnessModel(browserPanels: coordinator), continuation)
    }

    /// JPEG real de 64x48, generado con ImageIO.
    static func realJPEG() -> Data {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    func test_chatLogEntry_sin_panelID_se_construye_igual_que_antes() {
        XCTAssertNil(ChatLogEntry(role: "tool", text: "🔧 x").panelID)
    }

    func test_una_entrada_de_panel_lleva_rol_propio_y_su_id() {
        let entry = ChatLogEntry(role: "browserPanel", text: "", panelID: "p1")
        XCTAssertEqual(entry.role, "browserPanel")
        XCTAssertEqual(entry.panelID, "p1")
        XCTAssertTrue(entry.text.isEmpty, "el panel no lleva texto: lo pinta la vista desde el estado")
    }

    /// Detener la generación congela el panel: si no, la pantalla del pago queda viva.
    func test_detener_el_turno_congela_el_panel_activo() throws {
        let (model, continuation) = Self.makeModel()
        defer { continuation.finish() }
        let id = try XCTUnwrap(model.browserPanels.openIfNeeded(toolName: "browser_open"))
        XCTAssertFalse(model.browserPanels.panels[id]!.isCollapsed)
        model.cancelAgentTurn()
        XCTAssertTrue(model.browserPanels.panels[id]!.isCollapsed)
        XCTAssertNil(model.browserPanels.panels[id]!.jpeg)
        XCTAssertNil(model.browserPanels.activeID)
    }

    /// La decodificación del JPEG no puede ocurrir en el hilo principal.
    func test_la_vista_decodifica_fuera_del_hilo_principal() async {
        let state = BrowserPanelState()
        state.apply(.frame(seq: 1, jpeg: Self.realJPEG(), capturedAt: .now))
        let image = await BrowserPanelView.decodeOffMain(state.jpeg!)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 64)
    }

    func test_decodeOffMain_con_bytes_corruptos_devuelve_nil() async {
        let image = await BrowserPanelView.decodeOffMain(Data([0, 1, 2, 3]))
        XCTAssertNil(image)
    }

    /// §6.2(g): plegar suelta el JPEG, y el id del task debe cambiar para que la vista suelte la imagen.
    func test_plegar_cambia_el_id_del_task_para_soltar_la_imagen() {
        let state = BrowserPanelState()
        state.apply(.frame(seq: 1, jpeg: Self.realJPEG(), capturedAt: Date(timeIntervalSince1970: 100)))
        let vivo = BrowserPanelView.frameID(jpeg: state.jpeg, lastFrameAt: state.lastFrameAt)
        XCTAssertNotNil(vivo)

        state.apply(.state(live: true, collapsed: true))
        XCTAssertNil(state.jpeg)
        let plegado = BrowserPanelView.frameID(jpeg: state.jpeg, lastFrameAt: state.lastFrameAt)
        XCTAssertNil(plegado, "sin JPEG el id debe ser nil, o el efecto no se reejecuta y la imagen sobrevive")
        XCTAssertNotEqual(vivo, plegado)

        // Desplegar sin frame nuevo no resucita nada: el id sigue siendo nil.
        state.apply(.state(live: true, collapsed: false))
        XCTAssertNil(BrowserPanelView.frameID(jpeg: state.jpeg, lastFrameAt: state.lastFrameAt))

        // Un frame nuevo vuelve a dar un id distinto del anterior: la vista repinta.
        state.apply(.frame(seq: 2, jpeg: Self.realJPEG(), capturedAt: Date(timeIntervalSince1970: 101)))
        let nuevo = BrowserPanelView.frameID(jpeg: state.jpeg, lastFrameAt: state.lastFrameAt)
        XCTAssertNotNil(nuevo)
        XCTAssertNotEqual(nuevo, vivo)
    }
}
