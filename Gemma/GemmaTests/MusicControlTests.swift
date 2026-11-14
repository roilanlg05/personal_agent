import XCTest
@testable import Gemma

/// La música solo se podía poner.
///
/// `MusicService` tenía `play` y las listas, y nada más: ni pausar, ni parar, ni pasar de
/// canción, ni saber qué está sonando. Gemma ponía música y no la podía quitar, que es
/// una de las órdenes más obvias que se le puede dar por voz.
///
/// Lo que se puede controlar depende de la plataforma, y eso se dice en vez de fingir:
/// en macOS se guionan Spotify y Música con Apple Events; en iOS se controla la app
/// Música del sistema con MediaPlayer, pero Spotify no expone nada, así que la respuesta
/// honesta ahí es 'unsupported' y no un falso "pausado".
final class MusicControlTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    // MARK: - El servicio

    func test_pausar_lo_que_esta_sonando() async throws {
        let controller = MockMusicPlaybackController(state: .playing)
        let outcome = await controller.control(.pause, platform: .appleMusic)

        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(controller.commands, [.pause])
        XCTAssertEqual(controller.state, .paused, "Hay que verificar el estado, no suponerlo.")
    }

    func test_pausar_cuando_no_suena_nada_no_es_un_exito() async throws {
        let controller = MockMusicPlaybackController(state: .stopped)
        let outcome = await controller.control(.pause, platform: .appleMusic)

        XCTAssertEqual(
            outcome, .notPlaying,
            "Decir 'pausado' cuando no había nada sonando le hace creer al usuario que Gemma controla algo que no controla."
        )
    }

    func test_seguir_reproduciendo() async throws {
        let controller = MockMusicPlaybackController(state: .paused)
        let outcome = await controller.control(.resume, platform: .appleMusic)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(controller.state, .playing)
    }

    func test_siguiente_y_anterior() async throws {
        let controller = MockMusicPlaybackController(state: .playing)
        let next = await controller.control(.next, platform: .appleMusic)
        let previous = await controller.control(.previous, platform: .appleMusic)
        XCTAssertEqual(next, .done)
        XCTAssertEqual(previous, .done)
        XCTAssertEqual(controller.commands, [.next, .previous])
    }

    func test_parar() async throws {
        let controller = MockMusicPlaybackController(state: .playing)
        let outcome = await controller.control(.stop, platform: .appleMusic)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(controller.state, .stopped)
    }

    func test_una_plataforma_que_no_se_puede_controlar_lo_dice() async throws {
        let controller = MockMusicPlaybackController(state: .playing, controllable: [])
        let outcome = await controller.control(.pause, platform: .spotify)
        XCTAssertEqual(outcome, .unsupported)
    }

    func test_saber_que_esta_sonando() async throws {
        let controller = MockMusicPlaybackController(state: .playing)
        controller.nowPlayingInfo = NowPlayingInfo(title: "Imagine", artist: "John Lennon", isPlaying: true)

        let info = await controller.nowPlaying(platform: .appleMusic)

        XCTAssertEqual(info?.title, "Imagine")
        XCTAssertEqual(info?.artist, "John Lennon")
    }

    // MARK: - La herramienta

    private func tool(_ controller: MockMusicPlaybackController) -> ControlMusicTool {
        ControlMusicTool(controller: controller)
    }

    func test_tool_pausa() async throws {
        let controller = MockMusicPlaybackController(state: .playing)
        let result = try json(await tool(controller).run(argsJSON: #"{"action": "pause"}"#))

        XCTAssertEqual(result["status"] as? String, "done", "Salida: \(result)")
        XCTAssertEqual(result["action"] as? String, "pause")
    }

    func test_tool_acepta_las_palabras_del_usuario() async throws {
        // Un modelo pequeño escribe 'parar', 'quitar', 'siguiente'. Rechazarlas obliga al
        // usuario a repetirse.
        for (word, expected) in [
            ("pausa", MusicCommand.pause), ("pausar", .pause),
            ("reanudar", .resume), ("continuar", .resume), ("play", .resume),
            ("parar", .stop), ("stop", .stop), ("quitar", .stop),
            ("siguiente", .next), ("next", .next), ("saltar", .next),
            ("anterior", .previous), ("previous", .previous)
        ] {
            XCTAssertEqual(MusicCommand.parse(word), expected, "No entendió '\(word)'")
        }
    }

    func test_tool_rechaza_una_accion_desconocida_con_la_lista() async throws {
        let result = try json(await tool(MockMusicPlaybackController(state: .playing))
            .run(argsJSON: #"{"action": "bailar"}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_action")
        let valid = try XCTUnwrap(result["valid_actions"] as? [String])
        XCTAssertTrue(valid.contains("pause"))
    }

    func test_tool_sin_accion_lo_pide() async throws {
        let result = try json(await tool(MockMusicPlaybackController(state: .playing)).run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "invalid_action")
    }

    func test_tool_dice_cuando_no_habia_nada_sonando() async throws {
        let result = try json(await tool(MockMusicPlaybackController(state: .stopped))
            .run(argsJSON: #"{"action": "pause"}"#))

        XCTAssertEqual(result["status"] as? String, "not_playing")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("no"), "Debe decir que no había nada: \(message)")
    }

    func test_tool_status_cuenta_que_suena() async throws {
        let controller = MockMusicPlaybackController(state: .playing)
        controller.nowPlayingInfo = NowPlayingInfo(title: "Imagine", artist: "John Lennon", isPlaying: true)

        let result = try json(await tool(controller).run(argsJSON: #"{"action": "status"}"#))

        XCTAssertEqual(result["status"] as? String, "playing")
        XCTAssertEqual(result["title"] as? String, "Imagine")
        XCTAssertEqual(result["artist"] as? String, "John Lennon")
    }

    func test_tool_status_cuando_no_suena_nada() async throws {
        let result = try json(await tool(MockMusicPlaybackController(state: .stopped))
            .run(argsJSON: #"{"action": "status"}"#))

        XCTAssertEqual(result["status"] as? String, "not_playing")
    }

    func test_tool_dice_cuando_la_plataforma_no_se_puede_controlar() async throws {
        let controller = MockMusicPlaybackController(state: .playing, controllable: [])
        let result = try json(await tool(controller)
            .run(argsJSON: #"{"action": "pause", "platform": "spotify"}"#))

        XCTAssertEqual(result["status"] as? String, "unsupported")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("spotify"), "Debe nombrar la app: \(message)")
    }

    func test_la_descripcion_enumera_las_acciones() {
        let description = ControlMusicTool.description.lowercased()
        for action in ["pause", "resume", "stop", "next", "status"] {
            XCTAssertTrue(description.contains(action), "Falta '\(action)' en la descripción.")
        }
    }
}
