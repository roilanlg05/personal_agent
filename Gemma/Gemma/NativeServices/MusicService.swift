import Foundation
#if os(macOS)
import AppKit
#endif

public enum MusicPlatform: String, Codable, Sendable {
    case spotify = "spotify"
    case appleMusic = "apple_music"

    /// Nombre legible para los mensajes que lee el usuario.
    public var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }

    /// Esquema URL que la plataforma registra en el sistema. Se usa para comprobar
    /// con `canOpenURL` si la app está instalada antes de prometer nada.
    public var urlScheme: String {
        switch self {
        case .spotify: return "spotify"
        case .appleMusic: return "music"
        }
    }

    /// Identificador de bundle de la app de escritorio, para guionarla en macOS.
    public var macBundleIdentifier: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    /// Nombre con el que la app responde a Apple Events (`tell application "..."`).
    public var macScriptingName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        }
    }

    /// Acepta los alias que el modelo suele producir ("music", "apple music", ...).
    ///
    /// Lo desconocido cae en Apple Música, no en Spotify: es la única plataforma en la
    /// que se puede reproducir de verdad desde la app (biblioteca local y catálogo), así
    /// que es el destino sensato cuando no hay una indicación clara.
    public static func parse(_ raw: String?) -> MusicPlatform {
        let cleaned = (raw ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch cleaned {
        case "spotify", "espotifai", "spoty":
            return .spotify
        default:
            return .appleMusic
        }
    }
}

public enum MusicQueryType: String, Codable, Sendable {
    case track
    case artist
    case album
    case playlist
    case genre
}

public struct MusicPlaybackRequest: Sendable {
    public let query: String
    public let type: MusicQueryType
    public let platform: MusicPlatform
    /// ¿Pidió el usuario esa plataforma expresamente?
    ///
    /// Si no la pidió, el servicio puede caer a otra plataforma cuando sea la única que
    /// consigue reproducir. Si la pidió, se respeta su elección aunque el resultado sea
    /// solo abrir el buscador.
    public let isPlatformExplicit: Bool

    public init(
        query: String,
        type: MusicQueryType = .track,
        platform: MusicPlatform = .appleMusic,
        isPlatformExplicit: Bool = true
    ) {
        self.query = query
        self.type = type
        self.platform = platform
        self.isPlatformExplicit = isPlatformExplicit
    }
}

/// Qué significa realmente la consulta del usuario, una vez resuelta.
///
/// La distinción es importante y antes no existía: una URI concreta se puede
/// *reproducir*; un texto libre solo se puede *buscar*, porque sin credenciales de la
/// API de Spotify no hay forma de convertir "Bad Bunny" en una pista concreta.
public enum MusicTarget: Sendable, Equatable {
    /// Recurso directamente reproducible (URI de Spotify, enlace de Apple Music...).
    case playable(URL)
    /// Texto libre: solo podemos abrir el buscador de la app o mirar la biblioteca local.
    case search(text: String, url: URL)

    public var url: URL {
        switch self {
        case .playable(let url): return url
        case .search(_, let url): return url
        }
    }

    public var isPlayable: Bool {
        if case .playable = self { return true }
        return false
    }
}

/// Resultado honesto de un intento de reproducción.
///
/// El servicio anterior devolvía siempre `(opened: true, url)` *antes* de abrir nada,
/// así que el agente afirmaba "Reproduciendo X" incluso sin la app instalada. Estos
/// estados distinguen reproducción verificada, apertura sin verificar, buscador abierto
/// y fallo real.
public enum MusicPlaybackOutcome: String, Sendable {
    /// La reproducción arrancó y se verificó (`player state` de la app = playing).
    case playing
    /// La app aceptó el enlace profundo; se espera reproducción pero no se pudo verificar.
    case launching
    /// Se abrió el buscador de la app: el usuario debe elegir un resultado.
    case searchOpened = "search_opened"
    /// La app no está instalada o no es alcanzable.
    case appUnavailable = "app_unavailable"
    /// La consulta era inválida o la apertura falló.
    case failed
}

public struct MusicPlaybackResult: Sendable {
    public let outcome: MusicPlaybackOutcome
    public let platform: MusicPlatform
    public let target: MusicTarget?
    /// La lista de la biblioteca que se puso a sonar, si la reproducción vino de ahí.
    public let playlist: MusicPlaylist?
    /// La canción, álbum o lista que empezó a sonar, cuando se conoce su título.
    public let item: MusicPlaybackItem?
    /// Mensaje para el usuario, redactado sin afirmar más de lo que ocurrió.
    public let detail: String

    public init(
        outcome: MusicPlaybackOutcome,
        platform: MusicPlatform,
        target: MusicTarget?,
        playlist: MusicPlaylist? = nil,
        item: MusicPlaybackItem? = nil,
        detail: String
    ) {
        self.outcome = outcome
        self.platform = platform
        self.target = target
        self.playlist = playlist
        self.item = item
        self.detail = detail
    }
}

/// Control directo de la app de música instalada.
///
/// En macOS se implementa con Apple Events (AppleScript), lo que permite reproducción
/// real y, sobre todo, *verificable*. En iOS no existe equivalente: solo hay esquemas
/// URL, así que allí este controlador es `nil` y el servicio usa la ruta de URL.
public protocol MusicAppControlling: Sendable {
    /// ¿Está la app instalada y disponible para guionar?
    func isInstalled(_ platform: MusicPlatform) -> Bool

    /// Reproduce un recurso concreto. Devuelve `true` solo si la reproducción arrancó
    /// de verdad (comprobado leyendo el estado del reproductor).
    func play(uri: String, platform: MusicPlatform) async -> Bool

    /// Busca en la biblioteca local del usuario y reproduce la mejor coincidencia.
    /// Devuelve `false` si no hay coincidencia o la plataforma no lo soporta.
    func playFromLibrary(matching text: String, platform: MusicPlatform) async -> Bool
}

// MARK: - macOS: control por Apple Events

#if os(macOS)
/// Controla Spotify y Música mediante AppleScript.
///
/// Requisitos:
/// - `NSAppleEventsUsageDescription` en el Info.plist (si falta, macOS mata el proceso
///   la primera vez que se envía un Apple Event).
/// - La primera ejecución abre el diálogo de TCC "Gemma quiere controlar Spotify".
///   Si el usuario lo deniega, los guiones fallan y el servicio cae al esquema URL.
/// - Si algún día se activa el *hardened runtime*, hará falta además el entitlement
///   `com.apple.security.automation.apple-events`. Hoy está desactivado, por eso no
///   se añade (un entitlement desconocido rompería la firma del build de iOS, que
///   comparte el mismo fichero de entitlements).
public final class AppleScriptMusicAppController: MusicAppControlling, Sendable {

    /// Cuánto esperar como máximo a que la app cargue el recurso y empiece a sonar.
    private let playbackTimeout: TimeInterval
    /// Intervalo entre comprobaciones del estado del reproductor.
    private let pollInterval: TimeInterval

    public init(playbackTimeout: TimeInterval = 3.0, pollInterval: TimeInterval = 0.3) {
        self.playbackTimeout = playbackTimeout
        self.pollInterval = pollInterval
    }

    public func isInstalled(_ platform: MusicPlatform) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: platform.macBundleIdentifier) != nil
    }

    public func play(uri: String, platform: MusicPlatform) async -> Bool {
        guard isInstalled(platform) else { return false }

        // Spotify sabe reproducir una pista concreta directamente. Para contextos
        // (playlist, álbum, artista) y para Apple Music hay que cargar el recurso con
        // `open location` y después dar la orden de reproducir.
        if platform == .spotify, uri.hasPrefix("spotify:track:") {
            let script = """
            tell application "\(platform.macScriptingName)"
                activate
                play track "\(Self.escapeForAppleScript(uri))"
            end tell
            """
            guard await Self.run(script) != nil else { return false }
            return await waitForPlayback(platform: platform)
        }

        guard let url = URL(string: uri) else { return false }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { return false }

        // Darle un instante a la app para cargar el contexto antes de pulsar "play".
        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        _ = await Self.run("tell application \"\(platform.macScriptingName)\" to play")
        return await waitForPlayback(platform: platform)
    }

    public func playFromLibrary(matching text: String, platform: MusicPlatform) async -> Bool {
        // Spotify no expone búsqueda por AppleScript: solo acepta URIs. Sin la API web
        // no hay manera de resolver texto libre, así que se declara no soportado.
        guard platform == .appleMusic, isInstalled(platform) else { return false }

        let needle = Self.escapeForAppleScript(text)
        let script = """
        tell application "Music"
            activate
            set hits to (every track of library playlist 1 whose name contains "\(needle)")
            if hits is {} then
                set hits to (every track of library playlist 1 whose artist contains "\(needle)")
            end if
            if hits is {} then
                set hits to (every track of library playlist 1 whose album contains "\(needle)")
            end if
            if hits is {} then return "none"
            play (item 1 of hits)
            return "started"
        end tell
        """

        guard let result = await Self.run(script), result != "none" else { return false }
        return await waitForPlayback(platform: platform)
    }

    /// Sondea `player state` hasta que la app informe "playing" o se agote el tiempo.
    private func waitForPlayback(platform: MusicPlatform) async -> Bool {
        let deadline = Date().addingTimeInterval(playbackTimeout)
        let script = "tell application \"\(platform.macScriptingName)\" to return player state as text"
        repeat {
            if let state = await Self.run(script), state.lowercased().contains("playing") {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        } while Date() < deadline
        return false
    }

    /// Ejecuta un guion y devuelve su resultado textual, o `nil` si falló.
    ///
    /// `NSAppleScript` no es seguro entre hilos, así que se ejecuta siempre en el hilo
    /// principal.
    @MainActor
    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        return descriptor.stringValue ?? ""
    }

    /// Escapa el contenido que se inserta entre comillas en un literal de AppleScript.
    static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - macOS: controlar lo que ya suena

/// La conformidad vive en este fichero porque `run(_:)` es privado de la clase: desde
/// otro fichero no se podría enviar ningún Apple Event.
extension AppleScriptMusicAppController: MusicPlaybackControlling {

    public func control(_ command: MusicCommand, platform: MusicPlatform) async -> MusicControlOutcome {
        guard isInstalled(platform) else { return .unsupported }

        // El estado se lee antes de dar la orden: pausar algo que no suena no es un
        // éxito, y sin esta comprobación el guion "pause" devuelve bien igualmente.
        let before = await playerState(platform: platform)

        switch command {
        case .status:
            return before == .playing ? .done : .notPlaying
        case .pause:
            guard before == .playing else { return .notPlaying }
            guard await Self.runOnMain("tell application \"\(platform.macScriptingName)\" to pause") != nil else {
                return .failed
            }
            return await playerState(platform: platform) == .playing ? .failed : .done
        case .resume:
            guard await Self.runOnMain("tell application \"\(platform.macScriptingName)\" to play") != nil else {
                return .failed
            }
            return await playerState(platform: platform) == .playing ? .done : .failed
        case .stop:
            guard before != .stopped else { return .notPlaying }
            // Spotify no entiende `stop`; se pausa, que es lo más cercano que soporta.
            let verb = platform == .spotify ? "pause" : "stop"
            guard await Self.runOnMain("tell application \"\(platform.macScriptingName)\" to \(verb)") != nil else {
                return .failed
            }
            return await playerState(platform: platform) == .playing ? .failed : .done
        case .next:
            guard before == .playing else { return .notPlaying }
            return await Self.runOnMain("tell application \"\(platform.macScriptingName)\" to next track") != nil ? .done : .failed
        case .previous:
            guard before == .playing else { return .notPlaying }
            return await Self.runOnMain("tell application \"\(platform.macScriptingName)\" to previous track") != nil ? .done : .failed
        }
    }

    public func nowPlaying(platform: MusicPlatform) async -> NowPlayingInfo? {
        guard isInstalled(platform) else { return nil }
        let state = await playerState(platform: platform)
        guard state != .stopped else { return nil }
        // Se piden las dos en un solo guion para no pagar dos Apple Events.
        let script = """
        tell application "\(platform.macScriptingName)"
            return (name of current track) & "\\n" & (artist of current track)
        end tell
        """
        guard let raw = await Self.runOnMain(script) else { return nil }
        let parts = raw.components(separatedBy: "\n")
        return NowPlayingInfo(
            title: parts.first?.isEmpty == false ? parts.first : nil,
            artist: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil,
            isPlaying: state == .playing
        )
    }

    private func playerState(platform: MusicPlatform) async -> MusicPlaybackState {
        let script = "tell application \"\(platform.macScriptingName)\" to return player state as text"
        guard let raw = await Self.runOnMain(script)?.lowercased() else { return .stopped }
        if raw.contains("playing") { return .playing }
        if raw.contains("paused") { return .paused }
        return .stopped
    }

    /// `run` está aislado al actor principal; este envoltorio lo deja llamar desde el
    /// contexto asíncrono del protocolo.
    private static func runOnMain(_ source: String) async -> String? {
        await MainActor.run { run(source) }
    }
}
#endif

// MARK: - Servicio

public final class MusicService: Sendable {
    private let urlOpener: any AppURLOpening
    private let appController: (any MusicAppControlling)?
    private let library: (any MusicLibraryReading)?
    private let catalog: (any MusicCatalogPlaying)?
    /// Retardo antes de abrir la app por esquema URL.
    ///
    /// En iOS abrir otra app manda a Gemma al fondo, lo que puede cortar el turno a
    /// medio generar; por eso se espera a que termine de hablar. En macOS abrir una app
    /// no interrumpe nada, así que el retardo es cero y el resultado se puede devolver
    /// ya comprobado.
    private let launchDelay: TimeInterval

    public init(
        urlOpener: any AppURLOpening = SystemAppURLOpener(),
        appController: (any MusicAppControlling)? = MusicService.defaultAppController(),
        library: (any MusicLibraryReading)? = MusicService.defaultLibrary(),
        catalog: (any MusicCatalogPlaying)? = MusicService.defaultCatalog(),
        launchDelay: TimeInterval = MusicService.defaultLaunchDelay
    ) {
        self.urlOpener = urlOpener
        self.appController = appController
        self.library = library
        self.catalog = catalog
        self.launchDelay = launchDelay
    }

    /// Reproductor de catálogo por omisión. Solo iOS: `ApplicationMusicPlayer` de
    /// MusicKit no existe en macOS, donde la reproducción real se consigue guionando
    /// la app de Música con Apple Events.
    public static func defaultCatalog() -> (any MusicCatalogPlaying)? {
        #if os(iOS)
        return MusicKitCatalogPlayer()
        #else
        return nil
        #endif
    }

    /// Frase para el usuario según lo que empezó a sonar.
    static func playingDetail(for item: MusicPlaybackItem, source: String) -> String {
        let artist = item.subtitle.map { " de \($0)" } ?? ""
        switch item.kind {
        case "album":
            return "Reproduciendo el álbum '\(item.title)'\(artist) desde \(source)."
        case "playlist":
            return "Reproduciendo la lista '\(item.title)'\(artist) desde \(source)."
        case "artist":
            return "Reproduciendo \(item.subtitle ?? item.title) desde \(source)."
        default:
            return "Reproduciendo '\(item.title)'\(artist) desde \(source)."
        }
    }

    public static func defaultAppController() -> (any MusicAppControlling)? {
        #if os(macOS)
        return AppleScriptMusicAppController()
        #else
        return nil
        #endif
    }

    /// Lector de biblioteca por omisión: MediaPlayer en iOS, Apple Events en macOS.
    public static func defaultLibrary() -> (any MusicLibraryReading)? {
        #if os(iOS)
        return MediaPlayerMusicLibrary()
        #elseif os(macOS)
        return AppleScriptMusicAppController()
        #else
        return nil
        #endif
    }

    /// ¿Existe un lector de biblioteca en esta plataforma? (Distinto de tener permiso.)
    public var hasLibraryAccess: Bool { library != nil }

    /// ¿Hay permiso para leer la biblioteca? Puede abrir el diálogo del sistema.
    public func libraryAuthorized() async -> Bool {
        guard let library else { return false }
        return await library.authorizationGranted()
    }

    /// Listas de reproducción del usuario. Vacío si no hay biblioteca o permiso.
    public func listPlaylists() async -> [MusicPlaylist] {
        guard let library, await library.authorizationGranted() else { return [] }
        return await library.playlists()
    }

    public static var defaultLaunchDelay: TimeInterval {
        #if os(macOS)
        return 0
        #else
        return 1.2
        #endif
    }

    /// Playlists públicas y estables de Spotify para los géneros y estados de ánimo que
    /// el usuario pide por nombre. Es lo que convierte "pon reggaetón" en música que
    /// suena de verdad, en lugar de una pantalla de búsqueda.
    private static let curatedSpotifyPlaylists: [String: String] = [
        "reggaeton": "spotify:playlist:37i9dQZF1DX10zKzsJ2jva",   // ¡Viva Latino!
        "latino": "spotify:playlist:37i9dQZF1DX10zKzsJ2jva",
        "pop": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",         // Today's Top Hits
        "top hits": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
        "exitos": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
        "salsa": "spotify:playlist:37i9dQZF1DX7F6T1n37egb",       // Fuego en la Pista
        "bachata": "spotify:playlist:37i9dQZF1DX2L0iB23Enbq",     // Bachata Lovers
        "rock": "spotify:playlist:37i9dQZF1DWXRqgorJj26U",        // Rock Classics
        "hip hop": "spotify:playlist:37i9dQZF1DX0XUsuxWHRQd",     // RapCaviar
        "rap": "spotify:playlist:37i9dQZF1DX0XUsuxWHRQd",
        "electronica": "spotify:playlist:37i9dQZF1DX4dyzvuaRJ0n",  // mint
        "edm": "spotify:playlist:37i9dQZF1DX4dyzvuaRJ0n",
        "chill": "spotify:playlist:37i9dQZF1DXdLEN7aqioXM",
        "lofi": "spotify:playlist:37i9dQZF1DXdLEN7aqioXM",
        "relajante": "spotify:playlist:37i9dQZF1DXdLEN7aqioXM"
    ]

    /// Resuelve la consulta sin producir ningún efecto: función pura y testeable.
    public func resolveTarget(for request: MusicPlaybackRequest) -> MusicTarget? {
        let cleaned = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // 1. El usuario (o el modelo) ya dio un recurso concreto.
        if cleaned.hasPrefix("spotify:")
            || cleaned.hasPrefix("music:")
            || cleaned.hasPrefix("https://open.spotify.com/")
            || cleaned.hasPrefix("https://music.apple.com/") {
            if let url = URL(string: cleaned) { return .playable(url) }
        }

        // 2. Género o estado de ánimo conocido en Spotify -> playlist concreta.
        if request.platform == .spotify {
            let key = cleaned
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            if let uri = Self.curatedSpotifyPlaylists[key], let url = URL(string: uri) {
                return .playable(url)
            }
        }

        // 3. Texto libre: solo se puede buscar.
        guard let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let searchURLString: String
        switch request.platform {
        case .spotify:
            searchURLString = "spotify:search:\(encoded)"
        case .appleMusic:
            searchURLString = "music://music.apple.com/search?term=\(encoded)"
        }
        guard let url = URL(string: searchURLString) else { return nil }
        return .search(text: cleaned, url: url)
    }

    // MARK: - Emparejar la consulta con las listas del usuario

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Palabras con las que el usuario envuelve el nombre de una lista al hablar
    /// ("pon **mi lista de** Entrenamiento") y que no forman parte del nombre.
    private static let playlistQueryFillers: Set<String> = [
        "pon", "ponme", "poner", "reproduce", "reproducir",
        "mi", "mis", "la", "el", "los", "las", "un", "una",
        "lista", "listas", "playlist", "playlists", "reproduccion", "de"
    ]

    /// Quita el envoltorio conversacional para quedarse con el nombre probable.
    static func normalizedPlaylistQuery(_ query: String) -> String {
        var tokens = normalize(query).split(separator: " ").map(String.init)
        while let first = tokens.first, playlistQueryFillers.contains(first) {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    /// Busca entre las listas del usuario la que mejor corresponde a lo que pidió.
    ///
    /// Primero coincidencia exacta; si no, contención en cualquier dirección. Entre
    /// varias parciales gana la de nombre más corto, que es la más específica respecto
    /// a la consulta. Las consultas de una sola letra se descartan para que una
    /// coincidencia parcial trivial no secuestre la reproducción.
    public static func bestPlaylistMatch(query: String, in playlists: [MusicPlaylist]) -> MusicPlaylist? {
        let needle = normalizedPlaylistQuery(query)
        guard needle.count >= 2 else { return nil }

        var partialMatches: [MusicPlaylist] = []
        for list in playlists {
            let name = normalize(list.name)
            guard name.count >= 2 else { continue }
            if name == needle { return list }

            // El nombre de la lista contiene lo pedido: "salsa brava" -> "Salsa Brava
            // de los 90".
            if name.contains(needle) {
                partialMatches.append(list)
                continue
            }

            // El caso inverso solo vale si el nombre cubre buena parte de la consulta.
            // Sin ese umbral, una lista llamada "Rock" se quedaba con "pon rock en
            // español" y nunca se llegaba a buscar el género.
            if needle.contains(name), Double(name.count) / Double(needle.count) >= 0.6 {
                partialMatches.append(list)
            }
        }
        return partialMatches.min { normalize($0.name).count < normalize($1.name).count }
    }

    /// ¿La consulta ya es un recurso concreto? En ese caso manda y no se consulta la
    /// biblioteca.
    static func isExplicitResource(_ query: String) -> Bool {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.hasPrefix("spotify:")
            || cleaned.hasPrefix("music:")
            || cleaned.hasPrefix("https://open.spotify.com/")
            || cleaned.hasPrefix("https://music.apple.com/")
    }

    /// Intenta reproducir y devuelve lo que ocurrió de verdad.
    public func play(request: MusicPlaybackRequest) async -> MusicPlaybackResult {
        guard let target = resolveTarget(for: request) else {
            return MusicPlaybackResult(
                outcome: .failed,
                platform: request.platform,
                target: nil,
                detail: "No se pudo interpretar la consulta '\(request.query)' como música."
            )
        }

        // Una URI concreta es la orden más explícita posible: se obedece sin buscar nada.
        if Self.isExplicitResource(request.query) {
            return await openWithURLScheme(target: target, request: request)
        }

        // 1. Las listas del usuario mandan: si lo que pidió coincide con una de ellas,
        //    suena esa y no una playlist genérica ni una pantalla de búsqueda.
        if let library, await library.authorizationGranted() {
            let userPlaylists = await library.playlists()
            if let match = Self.bestPlaylistMatch(query: request.query, in: userPlaylists),
               await library.playPlaylist(id: match.id) {
                return MusicPlaybackResult(
                    outcome: .playing,
                    platform: match.platform,
                    target: target,
                    playlist: match,
                    detail: "Reproduciendo tu lista '\(match.name)' (\(match.trackCount) canciones)."
                )
            }
        }

        // 2. Biblioteca local: canciones, artistas y álbumes que el usuario ya tiene.
        //    Funciona sin suscripción y sin conexión.
        if request.platform == .appleMusic, let library, await library.authorizationGranted(),
           let item = await library.playLibraryMatch(for: request.query, type: request.type) {
            return MusicPlaybackResult(
                outcome: .playing,
                platform: .appleMusic,
                target: target,
                item: item,
                detail: Self.playingDetail(for: item, source: "tu biblioteca")
            )
        }

        // 3. Catálogo de Apple Music: lo que hace Siri cuando el usuario pide algo que no
        //    tiene guardado. Requiere suscripción y MusicKit activado en el App ID.
        if request.platform == .appleMusic, let catalog,
           let item = await catalog.playBestMatch(for: request.query, type: request.type) {
            return MusicPlaybackResult(
                outcome: .playing,
                platform: .appleMusic,
                target: target,
                item: item,
                detail: Self.playingDetail(for: item, source: "Apple Music")
            )
        }

        // 4. Ruta preferente en macOS: guionar la app para reproducir y verificar.
        if let controller = appController, controller.isInstalled(request.platform) {
            switch target {
            case .playable(let url):
                if await controller.play(uri: url.absoluteString, platform: request.platform) {
                    return MusicPlaybackResult(
                        outcome: .playing,
                        platform: request.platform,
                        target: target,
                        detail: "Reproduciendo en \(request.platform.displayName)."
                    )
                }
            case .search(let text, _):
                if await controller.playFromLibrary(matching: text, platform: request.platform) {
                    return MusicPlaybackResult(
                        outcome: .playing,
                        platform: request.platform,
                        target: target,
                        detail: "Reproduciendo '\(text)' desde la biblioteca de \(request.platform.displayName)."
                    )
                }
            }
            // Si el guion no consiguió arrancar la reproducción, se intenta el esquema URL.
        }

        // 5. Respaldo entre plataformas. Si el usuario no pidió una en concreto y ninguna
        //    vía de Apple Música funcionó, un enlace profundo a una playlist de Spotify
        //    sí arranca la reproducción al abrir la app. Mejor eso que un buscador vacío.
        if !request.isPlatformExplicit, request.platform != .spotify {
            let spotifyRequest = MusicPlaybackRequest(
                query: request.query,
                type: request.type,
                platform: .spotify,
                isPlatformExplicit: true
            )
            if let spotifyTarget = resolveTarget(for: spotifyRequest),
               spotifyTarget.isPlayable,
               await urlOpener.canOpenURL(spotifyTarget.url) {
                return await openWithURLScheme(target: spotifyTarget, request: spotifyRequest)
            }
        }

        // 6. Último recurso: abrir la app por esquema URL (reproduce si el recurso es
        //    concreto; si no, deja al usuario en el buscador).
        return await openWithURLScheme(target: target, request: request)
    }

    /// Abre el recurso en la app correspondiente mediante su esquema URL.
    private func openWithURLScheme(
        target: MusicTarget,
        request: MusicPlaybackRequest
    ) async -> MusicPlaybackResult {
        let url = target.url
        guard await urlOpener.canOpenURL(url) else {
            return MusicPlaybackResult(
                outcome: .appUnavailable,
                platform: request.platform,
                target: target,
                detail: "\(request.platform.displayName) no está instalada o no responde en este dispositivo."
            )
        }

        if launchDelay > 0 {
            // iOS: abrir ahora mandaría la app al fondo en mitad del turno. Se aplaza la
            // apertura y se informa de lo único verificado: que el sistema reconoce la app.
            let opener = urlOpener
            let delay = launchDelay
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                _ = await opener.openURL(url)
            }
            return MusicPlaybackResult(
                outcome: target.isPlayable ? .launching : .searchOpened,
                platform: request.platform,
                target: target,
                detail: target.isPlayable
                    ? "Abriendo \(request.platform.displayName) para reproducir."
                    : "Abriendo la búsqueda de '\(request.query)' en \(request.platform.displayName)."
            )
        }

        let opened = await urlOpener.openURL(url)
        guard opened else {
            return MusicPlaybackResult(
                outcome: .failed,
                platform: request.platform,
                target: target,
                detail: "\(request.platform.displayName) no aceptó la orden de reproducción."
            )
        }

        return MusicPlaybackResult(
            outcome: target.isPlayable ? .launching : .searchOpened,
            platform: request.platform,
            target: target,
            detail: target.isPlayable
                ? "\(request.platform.displayName) abrió el recurso solicitado."
                : "Se abrió la búsqueda de '\(request.query)' en \(request.platform.displayName); elige un resultado para que suene."
        )
    }
}

// MARK: - macOS: la biblioteca de Música como fuente de listas

#if os(macOS)
extension AppleScriptMusicAppController: MusicLibraryReading {

    /// En macOS no hay diálogo de permiso para la biblioteca como en iOS: el acceso lo
    /// gobierna la autorización de Apple Events, que se pide al primer guion. Aquí basta
    /// con saber si Música está instalada.
    public func authorizationGranted() async -> Bool {
        isInstalled(.appleMusic)
    }

    public func playlists() async -> [MusicPlaylist] {
        guard isInstalled(.appleMusic) else { return [] }

        // Se devuelve una línea por lista, con el nombre y el número de canciones
        // separados por tabulador. AppleScript no admite escapes tipo "\t", de ahí el
        // uso de las constantes `tab` y `linefeed`.
        let script = """
        tell application "Music"
            set output to ""
            repeat with aPlaylist in user playlists
                set output to output & (name of aPlaylist) & tab & (count of tracks of aPlaylist) & linefeed
            end repeat
            return output
        end tell
        """

        guard let raw = await Self.run(script) else { return [] }

        return raw.split(separator: "\n").compactMap { line -> MusicPlaylist? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let count = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
            // En macOS el nombre es el identificador: es con lo que AppleScript localiza
            // la lista para reproducirla.
            return MusicPlaylist(id: name, name: name, trackCount: count, platform: .appleMusic)
        }
    }

    public func playPlaylist(id: String) async -> Bool {
        guard isInstalled(.appleMusic) else { return false }
        let name = Self.escapeForAppleScript(id)
        let script = """
        tell application "Music"
            activate
            play playlist "\(name)"
        end tell
        """
        guard await Self.run(script) != nil else { return false }
        return await waitForPlayback(platform: .appleMusic)
    }

    /// Busca en la biblioteca de Música y devuelve **la pista que realmente suena**.
    ///
    /// Antes se devolvía la consulta del usuario como título, así que "pon algo de rock"
    /// se anunciaba como `Reproduciendo 'algo de rock'`: un título que no existe. El
    /// guion ya elige `item 1 of hits`, así que se le pide su nombre y su artista.
    public func playLibraryMatch(for query: String, type: MusicQueryType) async -> MusicPlaybackItem? {
        guard isInstalled(.appleMusic) else { return nil }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return nil }

        let escaped = Self.escapeForAppleScript(needle)
        let script = """
        tell application "Music"
            activate
            set hits to (every track of library playlist 1 whose name contains "\(escaped)")
            if hits is {} then
                set hits to (every track of library playlist 1 whose artist contains "\(escaped)")
            end if
            if hits is {} then
                set hits to (every track of library playlist 1 whose album contains "\(escaped)")
            end if
            if hits is {} then return "none"
            set chosen to item 1 of hits
            play chosen
            return (name of chosen) & tab & (artist of chosen)
        end tell
        """

        guard let raw = await Self.run(script), raw != "none" else { return nil }
        guard await waitForPlayback(platform: .appleMusic) else { return nil }

        let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? needle
        let artist = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return MusicPlaybackItem(
            title: title.isEmpty ? needle : title,
            subtitle: artist.isEmpty ? nil : artist,
            kind: "song"
        )
    }
}
#endif
