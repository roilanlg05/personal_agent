import Foundation

public final class PlayMusicTool: AgentTool, Sendable {
    public static let name = "play_music"
    public static let description = """
    Reproduce música. Acepta el nombre de una lista de \
    reproducción de la biblioteca del usuario (que tiene prioridad sobre todo lo demás), \
    un género o estado de ánimo ('reggaetón', 'salsa', 'rock', 'chill'), un artista, una \
    canción, un álbum o una URI directa (spotify:track:..., spotify:playlist:...). Si el \
    usuario pide "una de mis listas" sin decir cuál, usa primero list_music_playlists. \
    Devuelve 'status': 'playing' \
    si la música ya está sonando, 'launching' si se abrió el recurso en la app, \
    'search_opened' si solo se pudo abrir el buscador y el usuario debe elegir, \
    'app_unavailable' si la app no está instalada, o 'failed'. Informa al usuario \
    exactamente lo que dice 'status': no afirmes que la música suena si es 'search_opened'.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Canción, artista, álbum, playlist, género o URI a reproducir (ej. 'reggaeton', 'Bad Bunny', 'Dákiti')", required: true),
        AgentToolParam(name: "type", type: .string, description: "Tipo de contenido: 'track', 'artist', 'album', 'playlist' o 'genre' (por defecto 'track')", required: false),
        AgentToolParam(name: "platform", type: .string, description: "NO envíes este parámetro salvo que el usuario nombre expresamente una plataforma. Omitirlo deja que Gemma elija la que realmente puede reproducir. Valores: 'apple_music' o 'spotify'.", required: false)
    ]

    private let musicService: MusicService

    public init(musicService: MusicService = MusicService()) {
        self.musicService = musicService
    }

    public func run(argsJSON: String) async -> String {
        guard let query = Self.parseString(named: "query", from: argsJSON), !query.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'query' con la música, artista o género a reproducir.")
        }

        let typeString = Self.parseString(named: "type", from: argsJSON)?.lowercased() ?? "track"
        let queryType = MusicQueryType(rawValue: typeString) ?? .track

        // Si el usuario no nombró plataforma, el servicio puede elegir la que de verdad
        // consiga reproducir; si la nombró, se respeta su elección.
        let platformArgument = Self.parseString(named: "platform", from: argsJSON)
        let platform = MusicPlatform.parse(platformArgument)
        let isPlatformExplicit = !(platformArgument ?? "").isEmpty

        let result = await musicService.play(
            request: MusicPlaybackRequest(
                query: query,
                type: queryType,
                platform: platform,
                isPlatformExplicit: isPlatformExplicit
            )
        )

        return ToolJSONOutput.object([
            "status": result.outcome.rawValue,
            "query": query,
            "type": queryType.rawValue,
            "platform": result.platform.rawValue,
            "playlist": result.playlist?.name,
            "track_count": result.playlist?.trackCount,
            "now_playing": result.item?.title,
            "artist": result.item?.subtitle,
            "kind": result.item?.kind,
            "url": result.target?.url.absoluteString,
            "message": result.detail
        ])
    }

    private static func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[name] as? String else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
