import Foundation
#if os(iOS)
import MusicKit
#endif

/// Búsqueda y reproducción en el catálogo de Apple Music.
///
/// Es la capacidad que usa Siri cuando se le pide una canción que el usuario no tiene
/// guardada: se busca en el catálogo y se reproduce en streaming. A diferencia de la
/// biblioteca local, requiere suscripción activa a Apple Music.
public protocol MusicCatalogPlaying: Sendable {
    /// Autorización de MusicKit. Puede abrir el diálogo del sistema la primera vez.
    func authorizationGranted() async -> Bool

    /// Busca en el catálogo y reproduce la mejor coincidencia. Devuelve lo que empezó a
    /// sonar, o `nil` si no hubo resultados, falta la suscripción o no hay autorización.
    func playBestMatch(for query: String, type: MusicQueryType) async -> MusicPlaybackItem?
}

#if os(iOS)
/// Implementación con MusicKit: `MusicCatalogSearchRequest` para encontrar el contenido
/// y `ApplicationMusicPlayer` para reproducirlo dentro de Gemma.
///
/// Requisitos externos (no se pueden resolver desde el código):
/// - El App ID debe tener el servicio **MusicKit** activado en el portal de Apple
///   Developer (App Services → MusicKit). Sin eso, las peticiones al catálogo fallan por
///   autorización y esta clase devuelve `nil`, con lo que el servicio cae a la
///   biblioteca local o al buscador.
/// - `NSAppleMusicUsageDescription` en el Info.plist.
/// - Suscripción activa a Apple Music en la cuenta del dispositivo.
///
/// Cuando algo de eso falta no se lanza error ni se miente: se devuelve `nil` y el
/// resultado final lo refleja.
public final class MusicKitCatalogPlayer: MusicCatalogPlaying, Sendable {

    /// Cuántos resultados pedir por tipo. Basta con unos pocos: solo se usa el mejor.
    private let searchLimit: Int

    public init(searchLimit: Int = 5) {
        self.searchLimit = searchLimit
    }

    public func authorizationGranted() async -> Bool {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await MusicAuthorization.request() == .authorized
        default:
            return false
        }
    }

    public func playBestMatch(for query: String, type: MusicQueryType) async -> MusicPlaybackItem? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, await authorizationGranted() else { return nil }

        do {
            var request = MusicCatalogSearchRequest(
                term: term,
                types: [Song.self, Album.self, MusicKit.Playlist.self]
            )
            request.limit = searchLimit
            let response = try await request.response()

            // Se intenta primero lo que encaja con la intención declarada y después el
            // resto, porque el modelo no siempre clasifica bien la consulta.
            switch type {
            case .album:
                if let album = response.albums.first, await play([album]) {
                    return MusicPlaybackItem(title: album.title, subtitle: album.artistName, kind: "album")
                }
            case .playlist, .genre:
                if let playlist = response.playlists.first, await play([playlist]) {
                    return MusicPlaybackItem(title: playlist.name, subtitle: playlist.curatorName, kind: "playlist")
                }
            case .artist:
                // Para un artista se encola todo lo encontrado, no una sola canción,
                // para que siga sonando como haría una radio del artista.
                let songs = Array(response.songs)
                if !songs.isEmpty, await play(songs), let first = songs.first {
                    return MusicPlaybackItem(title: first.title, subtitle: first.artistName, kind: "artist")
                }
            case .track:
                break
            }

            if let song = response.songs.first, await play([song]) {
                return MusicPlaybackItem(title: song.title, subtitle: song.artistName, kind: "song")
            }
            if let playlist = response.playlists.first, await play([playlist]) {
                return MusicPlaybackItem(title: playlist.name, subtitle: playlist.curatorName, kind: "playlist")
            }
            if let album = response.albums.first, await play([album]) {
                return MusicPlaybackItem(title: album.title, subtitle: album.artistName, kind: "album")
            }
            return nil
        } catch {
            // Falta de suscripción, App ID sin MusicKit, sin red: todo acaba aquí y el
            // servicio probará la siguiente vía.
            return nil
        }
    }

    @MainActor
    private func play<Items: Collection>(_ items: Items) async -> Bool
    where Items.Element: PlayableMusicItem {
        guard !items.isEmpty else { return false }
        do {
            let player = ApplicationMusicPlayer.shared
            player.queue = ApplicationMusicPlayer.Queue(for: items)
            try await player.play()
            return true
        } catch {
            return false
        }
    }
}
#endif
