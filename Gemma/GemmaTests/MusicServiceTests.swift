import XCTest
@testable import Gemma

/// Controlador de app de música de prueba: permite simular que Spotify/Música están
/// instalados, que el guion de reproducción arranca (o no) y que la búsqueda en la
/// biblioteca local encuentra (o no) una coincidencia.
final class MockMusicAppController: MusicAppControlling, @unchecked Sendable {
    var installedPlatforms: Set<MusicPlatform>
    var playShouldStart: Bool
    var libraryMatchShouldPlay: Bool

    private(set) var playedURIs: [String] = []
    private(set) var librarySearches: [String] = []

    init(
        installedPlatforms: Set<MusicPlatform> = [.spotify, .appleMusic],
        playShouldStart: Bool = true,
        libraryMatchShouldPlay: Bool = false
    ) {
        self.installedPlatforms = installedPlatforms
        self.playShouldStart = playShouldStart
        self.libraryMatchShouldPlay = libraryMatchShouldPlay
    }

    func isInstalled(_ platform: MusicPlatform) -> Bool {
        installedPlatforms.contains(platform)
    }

    func play(uri: String, platform: MusicPlatform) async -> Bool {
        playedURIs.append(uri)
        return playShouldStart
    }

    func playFromLibrary(matching text: String, platform: MusicPlatform) async -> Bool {
        librarySearches.append(text)
        return libraryMatchShouldPlay
    }
}

final class MusicServiceTests: XCTestCase {

    // MARK: - resolveTarget (puro, sin efectos secundarios)

    func test_resolveTarget_genreKeyword_mapsToConcreteSpotifyPlaylist() {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil)
        let target = service.resolveTarget(
            for: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )
        guard case .playable(let url)? = target else {
            return XCTFail("Un género curado debe resolverse como destino reproducible, no como búsqueda. Obtenido: \(String(describing: target))")
        }
        XCTAssertEqual(url.absoluteString, "spotify:playlist:37i9dQZF1DX10zKzsJ2jva")
    }

    func test_resolveTarget_genreKeyword_isAccentAndCaseInsensitive() {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil)
        for query in ["Reggaetón", "REGGAETON", " reggaeton "] {
            let target = service.resolveTarget(
                for: MusicPlaybackRequest(query: query, type: .genre, platform: .spotify)
            )
            guard case .playable(let url)? = target else {
                return XCTFail("'\(query)' debería resolver al playlist curado")
            }
            XCTAssertEqual(url.absoluteString, "spotify:playlist:37i9dQZF1DX10zKzsJ2jva")
        }
    }

    func test_resolveTarget_passthroughSpotifyURI_isPlayable() {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil)
        let target = service.resolveTarget(
            for: MusicPlaybackRequest(query: "spotify:track:4cOdK2wGLETKBW3PvgPWqT", type: .track, platform: .spotify)
        )
        guard case .playable(let url)? = target else {
            return XCTFail("Una URI de Spotify explícita es reproducible")
        }
        XCTAssertEqual(url.absoluteString, "spotify:track:4cOdK2wGLETKBW3PvgPWqT")
    }

    func test_resolveTarget_freeText_isSearchNotPlayable() {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil)
        let target = service.resolveTarget(
            for: MusicPlaybackRequest(query: "Bad Bunny", type: .artist, platform: .spotify)
        )
        guard case .search(let text, let url)? = target else {
            return XCTFail("Texto libre no es reproducible directamente: debe ser búsqueda")
        }
        XCTAssertEqual(text, "Bad Bunny")
        XCTAssertTrue(url.absoluteString.hasPrefix("spotify:search:"), "Obtenido: \(url.absoluteString)")
        XCTAssertTrue(url.absoluteString.contains("Bad"), "La consulta debe viajar codificada en la URL")
    }

    func test_resolveTarget_appleMusicFreeText_usesMusicSearchURL() {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil)
        let target = service.resolveTarget(
            for: MusicPlaybackRequest(query: "Buena Vista Social Club", type: .artist, platform: .appleMusic)
        )
        guard case .search(_, let url)? = target else {
            return XCTFail("Texto libre en Apple Music debe ser búsqueda")
        }
        XCTAssertTrue(url.absoluteString.hasPrefix("music://"), "Obtenido: \(url.absoluteString)")
        XCTAssertTrue(url.absoluteString.contains("term="))
    }

    func test_resolveTarget_emptyQuery_isNil() {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil)
        XCTAssertNil(service.resolveTarget(for: MusicPlaybackRequest(query: "   ", type: .track, platform: .spotify)))
    }

    // MARK: - play: el resultado NO puede mentir

    func test_play_whenAppNotInstalled_reportsAppUnavailable() async {
        // El opener no reconoce el esquema => la app no está instalada.
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let service = MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )
        XCTAssertEqual(result.outcome, .appUnavailable)
        XCTAssertTrue(opener.openedURLs.isEmpty, "No debe intentar abrir una app ausente")
    }

    func test_play_whenOpenFails_reportsFailedNotPlaying() async {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        opener.shouldSucceed = false
        let service = MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )
        XCTAssertEqual(result.outcome, .failed, "Una apertura fallida jamás debe reportarse como reproducción")
    }

    func test_play_playableTargetViaURLScheme_reportsLaunchingAndOpensURL() async {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )
        XCTAssertEqual(result.outcome, .launching)
        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), ["spotify:playlist:37i9dQZF1DX10zKzsJ2jva"])
    }

    func test_play_searchTargetViaURLScheme_reportsSearchOpenedNotPlaying() async {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "Bad Bunny", type: .artist, platform: .spotify)
        )
        XCTAssertEqual(
            result.outcome, .searchOpened,
            "Abrir el buscador no es reproducir: el agente debe poder decirlo con precisión"
        )
    }

    func test_play_emptyQuery_reportsFailed() async {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "", type: .track, platform: .spotify)
        )
        XCTAssertEqual(result.outcome, .failed)
    }

    // MARK: - play con control de la app (macOS / AppleScript)

    func test_play_withControllerVerifyingPlayback_reportsPlaying() async {
        let controller = MockMusicAppController(playShouldStart: true)
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: controller, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )
        XCTAssertEqual(result.outcome, .playing, "Reproducción verificada por guion debe reportarse como 'playing'")
        XCTAssertEqual(controller.playedURIs, ["spotify:playlist:37i9dQZF1DX10zKzsJ2jva"])
        XCTAssertTrue(opener.openedURLs.isEmpty, "Con guion exitoso no hace falta el esquema URL")
    }

    func test_play_withControllerThatFailsToStart_fallsBackToURLScheme() async {
        let controller = MockMusicAppController(playShouldStart: false)
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: controller, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )
        XCTAssertEqual(result.outcome, .launching)
        XCTAssertEqual(opener.openedURLs.count, 1, "Si el guion no arranca, el esquema URL es el respaldo")
    }

    func test_play_withControllerNotInstalled_skipsScriptAndUsesURLScheme() async {
        let controller = MockMusicAppController(installedPlatforms: [.appleMusic])
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: controller, library: nil, catalog: nil, launchDelay: 0)
        _ = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )
        XCTAssertTrue(controller.playedURIs.isEmpty, "No se guiona una app que no está instalada")
    }

    func test_play_freeTextWithLibraryHit_reportsPlaying() async {
        let controller = MockMusicAppController(libraryMatchShouldPlay: true)
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let service = MusicService(urlOpener: opener, appController: controller, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "Chan Chan", type: .track, platform: .appleMusic)
        )
        XCTAssertEqual(result.outcome, .playing)
        XCTAssertEqual(controller.librarySearches, ["Chan Chan"])
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func test_play_freeTextWithLibraryMiss_opensSearch() async {
        let controller = MockMusicAppController(libraryMatchShouldPlay: false)
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let service = MusicService(urlOpener: opener, appController: controller, library: nil, catalog: nil, launchDelay: 0)
        let result = await service.play(
            request: MusicPlaybackRequest(query: "Chan Chan", type: .track, platform: .appleMusic)
        )
        XCTAssertEqual(result.outcome, .searchOpened)
        XCTAssertEqual(opener.openedURLs.count, 1)
    }

    // MARK: - PlayMusicTool: contrato JSON hacia el modelo

    func test_tool_metadata() {
        XCTAssertEqual(PlayMusicTool.name, "play_music")
        XCTAssertFalse(PlayMusicTool.description.isEmpty)
        XCTAssertTrue(PlayMusicTool.parameters.contains { $0.name == "query" && $0.required })
    }

    func test_tool_returnsValidJSON_evenWithQuotesInQuery() async throws {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let tool = PlayMusicTool(musicService: MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0))
        let args = try String(
            data: JSONSerialization.data(withJSONObject: ["query": #"Él dijo "hola" \ chau"#, "platform": "spotify"]),
            encoding: .utf8
        ) ?? "{}"

        let out = await tool.run(argsJSON: args)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            "La salida del tool debe ser JSON válido. Obtenido: \(out)"
        )
        XCTAssertEqual(parsed["status"] as? String, "search_opened")
        XCTAssertEqual(parsed["query"] as? String, #"Él dijo "hola" \ chau"#)
    }

    func test_tool_missingQuery_returnsValidErrorJSON() async throws {
        let tool = PlayMusicTool(musicService: MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil, launchDelay: 0))
        let out = await tool.run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["error"])
    }

    func test_tool_appNotInstalled_statusIsAppUnavailable() async throws {
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let tool = PlayMusicTool(musicService: MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0))
        let out = await tool.run(argsJSON: #"{"query": "reggaeton", "platform": "spotify"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "app_unavailable")
        let message = try XCTUnwrap(parsed["message"] as? String)
        XCTAssertFalse(message.lowercased().contains("reproduciendo"), "No debe afirmar que reproduce si la app falta")
    }

    func test_tool_playingStatus_whenControllerVerifiesPlayback() async throws {
        let controller = MockMusicAppController(playShouldStart: true)
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let tool = PlayMusicTool(musicService: MusicService(urlOpener: opener, appController: controller, library: nil, catalog: nil, launchDelay: 0))
        let out = await tool.run(argsJSON: #"{"query": "reggaeton", "type": "genre", "platform": "spotify"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "playing")
        XCTAssertEqual(parsed["platform"] as? String, "spotify")
    }

    func test_tool_honoursExplicitSpotify() async throws {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let tool = PlayMusicTool(musicService: MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0))
        let out = await tool.run(argsJSON: #"{"query": "reggaeton", "platform": "spotify"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["platform"] as? String, "spotify")
    }

    func test_tool_acceptsAppleMusicAliases() async throws {
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        for alias in ["apple_music", "music", "apple music", "Apple Music"] {
            let tool = PlayMusicTool(musicService: MusicService(urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0))
            let args = try String(
                data: JSONSerialization.data(withJSONObject: ["query": "reggaeton", "platform": alias]),
                encoding: .utf8
            ) ?? "{}"
            let out = await tool.run(argsJSON: args)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
            XCTAssertEqual(parsed["platform"] as? String, "apple_music", "alias '\(alias)' debe mapear a Apple Music")
        }
    }
}
