import Foundation
#if os(iOS)
import MediaPlayer
#endif

/// Una lista de reproducción de la biblioteca del usuario.
public struct MusicPlaylist: Codable, Sendable, Equatable, Identifiable {
    /// Identificador con el que se puede volver a localizar la lista para reproducirla.
    /// En iOS es el `persistentID` de MediaPlayer; en macOS, el nombre de la lista.
    public let id: String
    public let name: String
    public let trackCount: Int
    public let platform: MusicPlatform

    public init(id: String, name: String, trackCount: Int, platform: MusicPlatform) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.platform = platform
    }
}

/// Algo que se puso a sonar: una canción, un álbum, una lista.
public struct MusicPlaybackItem: Codable, Sendable, Equatable {
    public let title: String
    /// Artista, o descripción corta de la fuente.
    public let subtitle: String?
    /// "song", "album", "playlist" o "artist".
    public let kind: String

    public init(title: String, subtitle: String? = nil, kind: String) {
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

/// Lectura de la biblioteca musical del usuario y reproducción de sus listas.
///
/// Solo Apple Música lo soporta. Spotify no expone la biblioteca del usuario ni por
/// AppleScript (su diccionario solo acepta URIs) ni en iOS sin su SDK propio con OAuth,
/// así que para Spotify estas operaciones no están disponibles y se dice con claridad
/// en lugar de devolver una lista vacía como si no tuviera nada guardado.
public protocol MusicLibraryReading: Sendable {
    /// ¿Tenemos permiso (y la app) para leer la biblioteca? Puede provocar el diálogo
    /// de autorización del sistema la primera vez.
    func authorizationGranted() async -> Bool

    /// Listas de reproducción del usuario. Vacío si no hay permiso.
    func playlists() async -> [MusicPlaylist]

    /// Reproduce la lista indicada. Devuelve `true` solo si la reproducción arrancó.
    func playPlaylist(id: String) async -> Bool

    /// Busca en la biblioteca local (canciones, artistas, álbumes) y reproduce la mejor
    /// coincidencia. Devuelve lo que se puso a sonar, o `nil` si no había nada parecido.
    ///
    /// Esta es la vía que funciona sin suscripción y sin conexión: solo lo que el
    /// usuario ya tiene en el dispositivo.
    func playLibraryMatch(for query: String, type: MusicQueryType) async -> MusicPlaybackItem?
}

// MARK: - iOS: MediaPlayer

#if os(iOS)
/// Lee la biblioteca de Música con MediaPlayer y reproduce con el reproductor del
/// sistema, así que la música suena sin sacar al usuario de Gemma.
///
/// Requiere `NSAppleMusicUsageDescription` en el Info.plist: sin esa clave, iOS termina
/// el proceso en cuanto se consulta la biblioteca.
///
/// Solo ve lo que está en la biblioteca del dispositivo. Las listas de Apple Music
/// aparecen si el usuario tiene activada la sincronización de biblioteca; las que solo
/// escucha en streaming sin añadir, no.
public final class MediaPlayerMusicLibrary: MusicLibraryReading, Sendable {

    /// Cuánto esperar a que el reproductor del sistema confirme que está sonando.
    private let playbackTimeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(playbackTimeout: TimeInterval = 2.0, pollInterval: TimeInterval = 0.2) {
        self.playbackTimeout = playbackTimeout
        self.pollInterval = pollInterval
    }

    public func authorizationGranted() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    public func playlists() async -> [MusicPlaylist] {
        guard await authorizationGranted() else { return [] }
        guard let collections = MPMediaQuery.playlists().collections else { return [] }

        return collections.compactMap { collection in
            guard let name = collection.value(forProperty: MPMediaPlaylistPropertyName) as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return MusicPlaylist(
                id: String(collection.persistentID),
                name: name,
                trackCount: collection.count,
                platform: .appleMusic
            )
        }
    }

    public func playPlaylist(id: String) async -> Bool {
        guard let persistentID = UInt64(id), await authorizationGranted() else { return false }
        guard await startPlayback(persistentID: persistentID) else { return false }
        return await waitForPlayback()
    }

    public func playLibraryMatch(for query: String, type: MusicQueryType) async -> MusicPlaybackItem? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2, await authorizationGranted() else { return nil }

        // Se prueba la propiedad más específica según lo que pidió el usuario y después
        // las demás, porque el modelo no siempre acierta con 'type'.
        let properties: [String]
        switch type {
        case .artist:
            properties = [MPMediaItemPropertyArtist, MPMediaItemPropertyTitle, MPMediaItemPropertyAlbumTitle]
        case .album:
            properties = [MPMediaItemPropertyAlbumTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyTitle]
        case .genre:
            properties = [MPMediaItemPropertyGenre, MPMediaItemPropertyTitle, MPMediaItemPropertyArtist]
        case .track, .playlist:
            properties = [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle]
        }

        for property in properties {
            guard let items = await songs(matching: needle, property: property), !items.isEmpty else { continue }
            guard await startPlayback(items: items), await waitForPlayback() else { continue }
            let first = items[0]
            return MusicPlaybackItem(
                title: first.title ?? needle,
                subtitle: first.artist,
                kind: property == MPMediaItemPropertyAlbumTitle ? "album" : "song"
            )
        }
        return nil
    }

    @MainActor
    private func songs(matching needle: String, property: String) -> [MPMediaItem]? {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(
            MPMediaPropertyPredicate(value: needle, forProperty: property, comparisonType: .contains)
        )
        return query.items
    }

    @MainActor
    private func startPlayback(items: [MPMediaItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let player = MPMusicPlayerController.systemMusicPlayer
        player.setQueue(with: MPMediaItemCollection(items: items))
        player.shuffleMode = .off
        player.play()
        return true
    }

    @MainActor
    private func startPlayback(persistentID: UInt64) -> Bool {
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(
            MPMediaPropertyPredicate(
                value: NSNumber(value: persistentID),
                forProperty: MPMediaPlaylistPropertyPersistentID
            )
        )
        guard let playlist = query.collections?.first, playlist.count > 0 else { return false }

        let player = MPMusicPlayerController.systemMusicPlayer
        player.setQueue(with: playlist)
        player.shuffleMode = .off
        player.play()
        return true
    }

    @MainActor
    private func isPlaying() -> Bool {
        MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
    }

    /// El reproductor del sistema tarda un instante en pasar a `.playing`, así que se
    /// sondea en lugar de dar por bueno el primer estado.
    private func waitForPlayback() async -> Bool {
        let deadline = Date().addingTimeInterval(playbackTimeout)
        repeat {
            if await isPlaying() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        } while Date() < deadline
        return await isPlaying()
    }
}
#endif

// MARK: - Tool

public final class ListMusicPlaylistsTool: AgentTool, Sendable {
    public static let name = "list_music_playlists"
    public static let description = """
    Lista las listas de reproducción de la biblioteca de Música del usuario, con su \
    nombre y número de canciones. Úsala cuando el usuario pregunte qué listas tiene o \
    cuando pida poner "una de mis listas" y haya que saber cuáles existen. Después, para \
    reproducir una, llama a play_music con el nombre exacto de la lista. Si 'status' es \
    'permission_required', el usuario debe conceder acceso a su biblioteca; si es \
    'unsupported', esa plataforma no permite leer la biblioteca.
    """
    public static let parameters: [AgentToolParam] = []

    private let musicService: MusicService

    public init(musicService: MusicService = MusicService()) {
        self.musicService = musicService
    }

    public func run(argsJSON: String) async -> String {
        guard musicService.hasLibraryAccess else {
            return ToolJSONOutput.object([
                "status": "unsupported",
                "count": 0,
                "playlists": [],
                "message": "No se puede leer la biblioteca de música en este dispositivo."
            ])
        }

        guard await musicService.libraryAuthorized() else {
            return ToolJSONOutput.object([
                "status": "permission_required",
                "count": 0,
                "playlists": [],
                "message": "Gemma necesita permiso para acceder a tu biblioteca de música. Concédelo en Ajustes y vuelve a pedírmelo."
            ])
        }

        let playlists = await musicService.listPlaylists()
        return ToolJSONOutput.object([
            "status": "ok",
            "count": playlists.count,
            "playlists": playlists.map { list in
                [
                    "id": list.id,
                    "name": list.name,
                    "track_count": list.trackCount,
                    "platform": list.platform.rawValue
                ]
            },
            "message": playlists.isEmpty
                ? "No hay listas de reproducción en la biblioteca."
                : "\(playlists.count) listas de reproducción en la biblioteca."
        ])
    }
}
