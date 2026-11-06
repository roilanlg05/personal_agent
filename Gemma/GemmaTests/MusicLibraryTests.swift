import XCTest
@testable import Gemma

/// Biblioteca musical de prueba: permite simular permiso concedido o denegado,
/// un catálogo de listas y si la reproducción arranca.
final class MockMusicLibrary: MusicLibraryReading, @unchecked Sendable {
    var authorized: Bool
    var storedPlaylists: [MusicPlaylist]
    var playShouldStart: Bool
    /// Lo que devuelve la búsqueda en la biblioteca local; `nil` = no hay coincidencia.
    var libraryMatch: MusicPlaybackItem?

    private(set) var playedPlaylistIDs: [String] = []
    private(set) var playlistsCallCount = 0
    private(set) var libraryMatchQueries: [String] = []

    init(
        authorized: Bool = true,
        playlists: [MusicPlaylist] = [],
        playShouldStart: Bool = true,
        libraryMatch: MusicPlaybackItem? = nil
    ) {
        self.authorized = authorized
        self.storedPlaylists = playlists
        self.playShouldStart = playShouldStart
        self.libraryMatch = libraryMatch
    }

    func playLibraryMatch(for query: String, type: MusicQueryType) async -> MusicPlaybackItem? {
        libraryMatchQueries.append(query)
        return authorized ? libraryMatch : nil
    }

    func authorizationGranted() async -> Bool { authorized }

    func playlists() async -> [MusicPlaylist] {
        playlistsCallCount += 1
        return authorized ? storedPlaylists : []
    }

    func playPlaylist(id: String) async -> Bool {
        playedPlaylistIDs.append(id)
        return playShouldStart
    }
}

final class MusicLibraryTests: XCTestCase {

    private func playlist(_ name: String, id: String? = nil, tracks: Int = 10) -> MusicPlaylist {
        MusicPlaylist(id: id ?? name, name: name, trackCount: tracks, platform: .appleMusic)
    }

    // MARK: - Emparejar la consulta con una lista del usuario

    func test_bestPlaylistMatch_exactName() {
        let lists = [playlist("Entrenamiento"), playlist("Para Dormir")]
        let match = MusicService.bestPlaylistMatch(query: "Entrenamiento", in: lists)
        XCTAssertEqual(match?.name, "Entrenamiento")
    }

    func test_bestPlaylistMatch_ignoresCaseAndAccents() {
        let lists = [playlist("Música de Guagua")]
        XCTAssertEqual(MusicService.bestPlaylistMatch(query: "musica de guagua", in: lists)?.name, "Música de Guagua")
        XCTAssertEqual(MusicService.bestPlaylistMatch(query: "MUSICA DE GUAGUA", in: lists)?.name, "Música de Guagua")
    }

    func test_bestPlaylistMatch_stripsConversationalPrefixes() {
        let lists = [playlist("Entrenamiento")]
        for query in ["mi lista Entrenamiento", "la playlist de Entrenamiento", "lista de reproducción Entrenamiento"] {
            XCTAssertEqual(
                MusicService.bestPlaylistMatch(query: query, in: lists)?.name,
                "Entrenamiento",
                "'\(query)' debería encontrar la lista"
            )
        }
    }

    func test_bestPlaylistMatch_partialName() {
        let lists = [playlist("Salsa Brava de los 90"), playlist("Rock Clásico")]
        XCTAssertEqual(MusicService.bestPlaylistMatch(query: "salsa brava", in: lists)?.name, "Salsa Brava de los 90")
    }

    func test_bestPlaylistMatch_prefersExactOverPartial() {
        let lists = [playlist("Salsa Brava de los 90"), playlist("Salsa")]
        XCTAssertEqual(MusicService.bestPlaylistMatch(query: "Salsa", in: lists)?.name, "Salsa")
    }

    func test_bestPlaylistMatch_noMatchReturnsNil() {
        let lists = [playlist("Entrenamiento")]
        XCTAssertNil(MusicService.bestPlaylistMatch(query: "reggaeton", in: lists))
    }

    func test_bestPlaylistMatch_ignoresEmptyAndVeryShortQueries() {
        let lists = [playlist("Entrenamiento")]
        XCTAssertNil(MusicService.bestPlaylistMatch(query: "  ", in: lists))
        XCTAssertNil(
            MusicService.bestPlaylistMatch(query: "e", in: lists),
            "Una sola letra no debe secuestrar una lista por coincidencia parcial"
        )
    }

    // MARK: - play(): la biblioteca del usuario tiene prioridad

    func test_play_matchingUserPlaylist_playsItForReal() async {
        let library = MockMusicLibrary(playlists: [playlist("Entrenamiento", id: "pl-1")])
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let service = MusicService(urlOpener: opener, appController: nil, library: library, catalog: nil, launchDelay: 0)

        let result = await service.play(
            request: MusicPlaybackRequest(query: "Entrenamiento", type: .playlist, platform: .appleMusic)
        )

        XCTAssertEqual(result.outcome, .playing)
        XCTAssertEqual(library.playedPlaylistIDs, ["pl-1"])
        XCTAssertTrue(opener.openedURLs.isEmpty, "No debe abrir el buscador si ya está sonando la lista")
        XCTAssertTrue(result.detail.contains("Entrenamiento"))
    }

    func test_play_userPlaylistWinsOverCuratedGenre() async {
        // El usuario tiene su propia lista "Reggaeton": debe ganar al playlist curado de Spotify.
        let library = MockMusicLibrary(playlists: [playlist("Reggaeton", id: "pl-mio")])
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: nil, library: library, catalog: nil, launchDelay: 0)

        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )

        XCTAssertEqual(result.outcome, .playing)
        XCTAssertEqual(library.playedPlaylistIDs, ["pl-mio"])
    }

    func test_play_explicitURI_skipsLibraryLookup() async {
        let library = MockMusicLibrary(playlists: [playlist("Entrenamiento")])
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: nil, library: library, catalog: nil, launchDelay: 0)

        _ = await service.play(
            request: MusicPlaybackRequest(query: "spotify:playlist:abc123", type: .playlist, platform: .spotify)
        )

        XCTAssertTrue(library.playedPlaylistIDs.isEmpty, "Una URI explícita manda: no se busca en la biblioteca")
    }

    func test_play_noPlaylistMatch_fallsThroughToNormalResolution() async {
        let library = MockMusicLibrary(playlists: [playlist("Entrenamiento")])
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: nil, library: library, catalog: nil, launchDelay: 0)

        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )

        XCTAssertEqual(result.outcome, .launching)
        XCTAssertEqual(opener.openedURLs.first?.absoluteString, "spotify:playlist:37i9dQZF1DX10zKzsJ2jva")
    }

    func test_play_unauthorizedLibrary_doesNotBlockPlayback() async {
        let library = MockMusicLibrary(authorized: false, playlists: [playlist("Reggaeton")])
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: nil, library: library, catalog: nil, launchDelay: 0)

        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )

        XCTAssertEqual(result.outcome, .launching, "Sin permiso de biblioteca se sigue por la ruta normal")
        XCTAssertTrue(library.playedPlaylistIDs.isEmpty)
    }

    func test_play_playlistFoundButFailsToStart_fallsBack() async {
        let library = MockMusicLibrary(playlists: [playlist("Reggaeton", id: "pl-mio")], playShouldStart: false)
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(urlOpener: opener, appController: nil, library: library, catalog: nil, launchDelay: 0)

        let result = await service.play(
            request: MusicPlaybackRequest(query: "reggaeton", type: .genre, platform: .spotify)
        )

        XCTAssertEqual(library.playedPlaylistIDs, ["pl-mio"])
        XCTAssertEqual(result.outcome, .launching, "Si la lista no arranca, se intenta la ruta normal")
    }

    // MARK: - listPlaylists()

    func test_listPlaylists_returnsLibraryContents() async {
        let library = MockMusicLibrary(playlists: [playlist("Entrenamiento"), playlist("Para Dormir")])
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: library, catalog: nil, launchDelay: 0)

        let lists = await service.listPlaylists()
        XCTAssertEqual(lists.map(\.name), ["Entrenamiento", "Para Dormir"])
    }

    func test_listPlaylists_unauthorized_returnsEmpty() async {
        let library = MockMusicLibrary(authorized: false, playlists: [playlist("Entrenamiento")])
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: library, catalog: nil, launchDelay: 0)
        let lists = await service.listPlaylists()
        XCTAssertTrue(lists.isEmpty)
    }

    func test_listPlaylists_withoutLibrary_returnsEmpty() async {
        let service = MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: nil, catalog: nil, launchDelay: 0)
        let lists = await service.listPlaylists()
        XCTAssertTrue(lists.isEmpty)
    }

    // MARK: - ListMusicPlaylistsTool

    func test_listTool_metadata() {
        XCTAssertEqual(ListMusicPlaylistsTool.name, "list_music_playlists")
        XCTAssertFalse(ListMusicPlaylistsTool.description.isEmpty)
    }

    func test_listTool_returnsValidJSONWithPlaylists() async throws {
        let library = MockMusicLibrary(playlists: [
            playlist("Entrenamiento", id: "pl-1", tracks: 42),
            playlist(#"Lista "rara" con \ barra"#, id: "pl-2", tracks: 3)
        ])
        let tool = ListMusicPlaylistsTool(
            musicService: MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: library, catalog: nil, launchDelay: 0)
        )

        let out = await tool.run(argsJSON: "{}")
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            "Salida inválida: \(out)"
        )
        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(parsed["count"] as? Int, 2)
        let lists = try XCTUnwrap(parsed["playlists"] as? [[String: Any]])
        XCTAssertEqual(lists.first?["name"] as? String, "Entrenamiento")
        XCTAssertEqual(lists.first?["track_count"] as? Int, 42)
        XCTAssertEqual(lists.last?["name"] as? String, #"Lista "rara" con \ barra"#)
    }

    func test_listTool_unauthorized_reportsPermissionNeeded() async throws {
        let library = MockMusicLibrary(authorized: false)
        let tool = ListMusicPlaylistsTool(
            musicService: MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: library, catalog: nil, launchDelay: 0)
        )
        let out = await tool.run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "permission_required")
        XCTAssertEqual(parsed["count"] as? Int, 0)
    }

    func test_listTool_emptyLibrary_reportsOkWithZero() async throws {
        let library = MockMusicLibrary(playlists: [])
        let tool = ListMusicPlaylistsTool(
            musicService: MusicService(urlOpener: MockAppURLOpener(), appController: nil, library: library, catalog: nil, launchDelay: 0)
        )
        let out = await tool.run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(parsed["count"] as? Int, 0)
    }

    // MARK: - play_music reproduciendo una lista del usuario

    func test_playTool_playsUserPlaylistAndNamesIt() async throws {
        let library = MockMusicLibrary(playlists: [playlist("Entrenamiento", id: "pl-1")])
        let tool = PlayMusicTool(
            musicService: MusicService(
                urlOpener: MockAppURLOpener(supportedSchemes: ["music"]),
                appController: nil,
                library: library,
                launchDelay: 0
            )
        )

        let out = await tool.run(argsJSON: #"{"query": "Entrenamiento", "type": "playlist", "platform": "apple_music"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "playing")
        XCTAssertEqual(parsed["playlist"] as? String, "Entrenamiento")
    }
}

/// Catálogo de Apple Music de prueba.
final class MockMusicCatalog: MusicCatalogPlaying, @unchecked Sendable {
    var authorized: Bool
    var match: MusicPlaybackItem?

    private(set) var queries: [String] = []

    init(authorized: Bool = true, match: MusicPlaybackItem? = nil) {
        self.authorized = authorized
        self.match = match
    }

    func authorizationGranted() async -> Bool { authorized }

    func playBestMatch(for query: String, type: MusicQueryType) async -> MusicPlaybackItem? {
        queries.append(query)
        return authorized ? match : nil
    }
}

/// Reproducción real de canciones: biblioteca local y catálogo de Apple Music.
/// Es la capacidad que el usuario compara con Siri — buscar y que suene.
final class MusicPlaybackSourcesTests: XCTestCase {

    private func song(_ title: String, artist: String? = "Artista") -> MusicPlaybackItem {
        MusicPlaybackItem(title: title, subtitle: artist, kind: "song")
    }

    // MARK: - Biblioteca local

    func test_play_songInLocalLibrary_playsItWithoutOpeningAnyApp() async {
        let library = MockMusicLibrary(libraryMatch: song("Chan Chan", artist: "Buena Vista Social Club"))
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let service = MusicService(urlOpener: opener, appController: nil, library: library, catalog: nil, launchDelay: 0)

        let result = await service.play(
            request: MusicPlaybackRequest(query: "Chan Chan", type: .track, platform: .appleMusic)
        )

        XCTAssertEqual(result.outcome, .playing)
        XCTAssertEqual(result.item?.title, "Chan Chan")
        XCTAssertEqual(library.libraryMatchQueries, ["Chan Chan"])
        XCTAssertTrue(opener.openedURLs.isEmpty, "La biblioteca local suena dentro de la app, sin abrir nada")
        XCTAssertTrue(result.detail.contains("Chan Chan"))
    }

    func test_play_localLibraryIsTriedBeforeCatalog() async {
        let library = MockMusicLibrary(libraryMatch: song("Chan Chan"))
        let catalog = MockMusicCatalog(match: song("Otra Cosa"))
        let service = MusicService(
            urlOpener: MockAppURLOpener(), appController: nil, library: library, catalog: catalog, launchDelay: 0
        )

        let result = await service.play(
            request: MusicPlaybackRequest(query: "Chan Chan", type: .track, platform: .appleMusic)
        )

        XCTAssertEqual(result.item?.title, "Chan Chan")
        XCTAssertTrue(catalog.queries.isEmpty, "Lo que el usuario ya tiene va antes que el streaming")
    }

    // MARK: - Catálogo de Apple Music

    func test_play_songOnlyInCatalog_playsFromCatalog() async {
        let library = MockMusicLibrary(libraryMatch: nil)
        let catalog = MockMusicCatalog(match: song("Dákiti", artist: "Bad Bunny"))
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let service = MusicService(
            urlOpener: opener, appController: nil, library: library, catalog: catalog, launchDelay: 0
        )

        let result = await service.play(
            request: MusicPlaybackRequest(query: "Dákiti", type: .track, platform: .appleMusic)
        )

        XCTAssertEqual(result.outcome, .playing)
        XCTAssertEqual(result.item?.title, "Dákiti")
        XCTAssertEqual(result.item?.subtitle, "Bad Bunny")
        XCTAssertEqual(catalog.queries, ["Dákiti"])
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    func test_play_catalogUnauthorized_fallsBackToSearch() async {
        let catalog = MockMusicCatalog(authorized: false, match: song("Dákiti"))
        let opener = MockAppURLOpener(supportedSchemes: ["music"])
        let service = MusicService(
            urlOpener: opener, appController: nil, library: nil, catalog: catalog, launchDelay: 0
        )

        let result = await service.play(
            request: MusicPlaybackRequest(query: "Dákiti", type: .track, platform: .appleMusic)
        )

        XCTAssertEqual(result.outcome, .searchOpened, "Sin autorización de MusicKit se abre el buscador, no se miente")
        XCTAssertEqual(opener.openedURLs.count, 1)
    }

    func test_play_explicitSpotify_doesNotPlayThroughAppleMusic() async {
        let catalog = MockMusicCatalog(match: song("Dákiti"))
        let library = MockMusicLibrary(libraryMatch: song("Dákiti"))
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(
            urlOpener: opener, appController: nil, library: library, catalog: catalog, launchDelay: 0
        )

        let result = await service.play(
            request: MusicPlaybackRequest(query: "Dákiti", type: .track, platform: .spotify, isPlatformExplicit: true)
        )

        XCTAssertEqual(result.outcome, .searchOpened)
        XCTAssertTrue(catalog.queries.isEmpty, "Si el usuario pidió Spotify, no se le cambia de plataforma")
        XCTAssertTrue(library.libraryMatchQueries.isEmpty)
    }

    func test_play_explicitURI_skipsLibraryAndCatalog() async {
        let catalog = MockMusicCatalog(match: song("X"))
        let library = MockMusicLibrary(libraryMatch: song("X"))
        let opener = MockAppURLOpener(supportedSchemes: ["spotify"])
        let service = MusicService(
            urlOpener: opener, appController: nil, library: library, catalog: catalog, launchDelay: 0
        )

        let result = await service.play(
            request: MusicPlaybackRequest(query: "spotify:track:abc", type: .track, platform: .spotify)
        )

        XCTAssertEqual(result.outcome, .launching)
        XCTAssertTrue(catalog.queries.isEmpty)
        XCTAssertTrue(library.libraryMatchQueries.isEmpty)
    }

    // MARK: - Respaldo entre plataformas cuando no se pidió ninguna

    func test_play_noPlatformAsked_fallsBackToSpotifyPlaylistWhenAppleMusicCannotPlay() async {
        // Nada en biblioteca, nada en catálogo, pero es un género con playlist curada:
        // el enlace profundo de Spotify sí arranca la reproducción.
        let opener = MockAppURLOpener(supportedSchemes: ["spotify", "music"])
        let service = MusicService(
            urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0
        )

        let result = await service.play(
            request: MusicPlaybackRequest(
                query: "reggaeton", type: .genre, platform: .appleMusic, isPlatformExplicit: false
            )
        )

        XCTAssertEqual(result.outcome, .launching)
        XCTAssertEqual(result.platform, .spotify)
        XCTAssertEqual(opener.openedURLs.first?.absoluteString, "spotify:playlist:37i9dQZF1DX10zKzsJ2jva")
    }

    func test_play_explicitAppleMusic_neverFallsBackToSpotify() async {
        let opener = MockAppURLOpener(supportedSchemes: ["spotify", "music"])
        let service = MusicService(
            urlOpener: opener, appController: nil, library: nil, catalog: nil, launchDelay: 0
        )

        let result = await service.play(
            request: MusicPlaybackRequest(
                query: "reggaeton", type: .genre, platform: .appleMusic, isPlatformExplicit: true
            )
        )

        XCTAssertEqual(result.platform, .appleMusic)
        XCTAssertEqual(result.outcome, .searchOpened)
    }

    // MARK: - Plataforma por omisión

    func test_platformParse_unknownGoesToAppleMusic() {
        XCTAssertEqual(MusicPlatform.parse(nil), .appleMusic)
        XCTAssertEqual(MusicPlatform.parse(""), .appleMusic)
        XCTAssertEqual(MusicPlatform.parse("lo que sea"), .appleMusic)
        XCTAssertEqual(MusicPlatform.parse("Spotify"), .spotify)
    }

    // MARK: - Salida del tool

    func test_tool_reportsWhatIsPlayingWithArtist() async throws {
        let catalog = MockMusicCatalog(match: song("Dákiti", artist: "Bad Bunny"))
        let tool = PlayMusicTool(
            musicService: MusicService(
                urlOpener: MockAppURLOpener(supportedSchemes: ["music"]),
                appController: nil, library: nil, catalog: catalog, launchDelay: 0
            )
        )

        let out = await tool.run(argsJSON: #"{"query": "Dákiti"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "playing")
        XCTAssertEqual(parsed["now_playing"] as? String, "Dákiti")
        XCTAssertEqual(parsed["artist"] as? String, "Bad Bunny")
        XCTAssertEqual(parsed["platform"] as? String, "apple_music")
    }

    func test_tool_defaultsToAppleMusicWhenPlatformOmitted() async throws {
        let tool = PlayMusicTool(
            musicService: MusicService(
                urlOpener: MockAppURLOpener(supportedSchemes: ["music"]),
                appController: nil, library: nil, catalog: nil, launchDelay: 0
            )
        )
        let out = await tool.run(argsJSON: #"{"query": "Chan Chan"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["platform"] as? String, "apple_music")
    }
}

/// Regresiones del análisis de la tanda.
final class MusicReviewRegressionTests: XCTestCase {

    private func playlist(_ name: String) -> MusicPlaylist {
        MusicPlaylist(id: name, name: name, trackCount: 10, platform: .appleMusic)
    }

    func test_shortPlaylistNameDoesNotHijackALongerRequest() {
        // Con una lista llamada "Rock", "pon rock en español" pedía esa lista y no se
        // llegaba a buscar el género.
        let lists = [playlist("Rock")]
        XCTAssertNil(MusicService.bestPlaylistMatch(query: "rock en espanol", in: lists))
        XCTAssertNil(MusicService.bestPlaylistMatch(query: "pon algo de rock de los 80", in: lists))
    }

    func test_exactAndContainedMatchesStillWork() {
        let lists = [playlist("Rock"), playlist("Salsa Brava de los 90")]
        XCTAssertEqual(MusicService.bestPlaylistMatch(query: "rock", in: lists)?.name, "Rock")
        XCTAssertEqual(MusicService.bestPlaylistMatch(query: "mi lista Rock", in: lists)?.name, "Rock")
        XCTAssertEqual(
            MusicService.bestPlaylistMatch(query: "salsa brava", in: lists)?.name,
            "Salsa Brava de los 90"
        )
    }

    func test_reverseMatchNeedsToCoverMostOfTheQuery() {
        let lists = [playlist("Entrenamiento")]
        // "Entrenamiento" cubre casi toda la consulta: vale.
        XCTAssertEqual(
            MusicService.bestPlaylistMatch(query: "Entrenamiento ya", in: lists)?.name,
            "Entrenamiento"
        )
        // Aquí es una parte pequeña de una petición muy distinta: no vale.
        XCTAssertNil(
            MusicService.bestPlaylistMatch(
                query: "musica para el entrenamiento de manana por la tarde temprano",
                in: lists
            )
        )
    }
}
