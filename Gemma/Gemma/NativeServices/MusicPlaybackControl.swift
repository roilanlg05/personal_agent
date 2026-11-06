import Foundation
#if os(iOS)
import MediaPlayer
#endif

/// Controlar la música que ya está sonando: pausar, seguir, parar, cambiar de canción.
///
/// ## Por qué hace falta
///
/// `MusicService` solo sabía **poner** música. No había forma de quitarla, que es una de
/// las órdenes más obvias que se le puede dar a un asistente de voz: Gemma ponía la lista
/// y el usuario se quedaba sin poder decirle "para".
///
/// Lo que se puede controlar depende de la plataforma, y aquí se dice en vez de fingir:
///
/// - **macOS**: Spotify y Música se guionan con Apple Events, las dos.
/// - **iOS**: la app Música del sistema se controla con `MPMusicPlayerController`.
///   Spotify no expone nada equivalente (haría falta su SDK con autenticación), así que
///   la respuesta honesta es `unsupported` y no un "pausado" que no pausó nada.

/// Qué se le puede pedir al reproductor.
public enum MusicCommand: String, Sendable, Equatable, CaseIterable {
    case pause
    case resume
    case stop
    case next
    case previous
    /// No cambia nada: solo dice qué está sonando.
    case status

    public static var allNames: [String] { allCases.map(\.rawValue) }

    /// Traduce lo que escribe el modelo, que usa las palabras del usuario.
    ///
    /// Un modelo pequeño escribe "parar", "quitar" o "siguiente" con la misma facilidad
    /// que el nombre canónico; rechazarlo obligaría al usuario a repetir la orden.
    public static func parse(_ raw: String?) -> MusicCommand? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        switch text {
        case "pause", "pausa", "pausar", "pausala", "espera":
            return .pause
        case "resume", "reanudar", "continuar", "sigue", "seguir", "play", "reproducir":
            return .resume
        case "stop", "parar", "para", "detener", "quitar", "quita", "apagar", "apaga":
            return .stop
        case "next", "siguiente", "saltar", "salta", "pasar", "pasa", "otra":
            return .next
        case "previous", "prev", "anterior", "atras", "volver":
            return .previous
        case "status", "estado", "que suena", "que esta sonando", "nowplaying", "now_playing":
            return .status
        default:
            return nil
        }
    }

    public var spanishName: String {
        switch self {
        case .pause: return "pausar"
        case .resume: return "seguir reproduciendo"
        case .stop: return "parar"
        case .next: return "pasar a la siguiente"
        case .previous: return "volver a la anterior"
        case .status: return "ver qué suena"
        }
    }
}

/// Qué pasó al dar la orden.
public enum MusicControlOutcome: String, Sendable, Equatable {
    /// Se dio la orden y el estado del reproductor lo confirma.
    case done
    /// No había nada sonando, así que no había nada que pausar o pasar.
    case notPlaying = "not_playing"
    /// Esta plataforma no se puede controlar en este dispositivo.
    case unsupported
    /// Se dio la orden y el reproductor no obedeció.
    case failed
}

/// Lo que está sonando ahora mismo.
public struct NowPlayingInfo: Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let isPlaying: Bool

    public init(title: String?, artist: String?, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
    }
}

/// Estado del reproductor, en la forma mínima que hace falta para decidir y verificar.
public enum MusicPlaybackState: String, Sendable, Equatable {
    case playing
    case paused
    case stopped
}

public protocol MusicPlaybackControlling: Sendable {
    /// Da la orden y devuelve lo que de verdad pasó, comprobado contra el reproductor.
    func control(_ command: MusicCommand, platform: MusicPlatform) async -> MusicControlOutcome
    /// Qué está sonando, o `nil` si nada o no se puede saber.
    func nowPlaying(platform: MusicPlatform) async -> NowPlayingInfo?
}

// MARK: - iOS: la app Música del sistema

#if os(iOS)
/// Controla la app Música con `MPMusicPlayerController.systemMusicPlayer`.
///
/// Solo Apple Music: Spotify en iOS no se puede controlar desde otra app sin su SDK, y
/// mentir sobre eso dejaría al usuario pulsando una orden que no llega a ninguna parte.
public final class MediaPlayerPlaybackController: MusicPlaybackControlling, Sendable {
    public init() {}

    public func control(_ command: MusicCommand, platform: MusicPlatform) async -> MusicControlOutcome {
        guard platform == .appleMusic else { return .unsupported }
        return await MainActor.run {
            let player = MPMusicPlayerController.systemMusicPlayer
            switch command {
            case .status:
                return player.playbackState == .playing ? .done : .notPlaying
            case .pause:
                guard player.playbackState == .playing else { return .notPlaying }
                player.pause()
                return player.playbackState == .playing ? .failed : .done
            case .resume:
                player.play()
                return player.playbackState == .playing ? .done : .failed
            case .stop:
                guard player.playbackState != .stopped else { return .notPlaying }
                player.stop()
                return .done
            case .next:
                guard player.playbackState == .playing || player.nowPlayingItem != nil else { return .notPlaying }
                player.skipToNextItem()
                return .done
            case .previous:
                guard player.playbackState == .playing || player.nowPlayingItem != nil else { return .notPlaying }
                player.skipToPreviousItem()
                return .done
            }
        }
    }

    public func nowPlaying(platform: MusicPlatform) async -> NowPlayingInfo? {
        guard platform == .appleMusic else { return nil }
        return await MainActor.run {
            let player = MPMusicPlayerController.systemMusicPlayer
            guard let item = player.nowPlayingItem else { return nil }
            return NowPlayingInfo(
                title: item.title,
                artist: item.artist,
                isPlaying: player.playbackState == .playing
            )
        }
    }
}
#endif

/// Plataforma donde no se puede controlar nada.
public final class UnsupportedPlaybackController: MusicPlaybackControlling, Sendable {
    public init() {}
    public func control(_ command: MusicCommand, platform: MusicPlatform) async -> MusicControlOutcome { .unsupported }
    public func nowPlaying(platform: MusicPlatform) async -> NowPlayingInfo? { nil }
}

public enum MusicPlaybackControllerFactory {
    public static func make() -> any MusicPlaybackControlling {
        #if os(macOS)
        return AppleScriptMusicAppController()
        #elseif os(iOS)
        return MediaPlayerPlaybackController()
        #else
        return UnsupportedPlaybackController()
        #endif
    }
}

/// Doble de pruebas que lleva la cuenta del estado, para poder comprobar que la orden se
/// verifica y no solo se envía.
public final class MockMusicPlaybackController: MusicPlaybackControlling, @unchecked Sendable {
    public var state: MusicPlaybackState
    public var controllable: Set<MusicPlatform>
    public var nowPlayingInfo: NowPlayingInfo?
    public private(set) var commands: [MusicCommand] = []

    public init(
        state: MusicPlaybackState = .playing,
        controllable: Set<MusicPlatform> = [.appleMusic, .spotify],
        nowPlayingInfo: NowPlayingInfo? = nil
    ) {
        self.state = state
        self.controllable = controllable
        self.nowPlayingInfo = nowPlayingInfo
    }

    public func control(_ command: MusicCommand, platform: MusicPlatform) async -> MusicControlOutcome {
        guard controllable.contains(platform) else { return .unsupported }
        if command == .status { return state == .playing ? .done : .notPlaying }
        commands.append(command)
        switch command {
        case .pause:
            guard state == .playing else { commands.removeLast(); return .notPlaying }
            state = .paused
            return .done
        case .resume:
            state = .playing
            return .done
        case .stop:
            guard state != .stopped else { commands.removeLast(); return .notPlaying }
            state = .stopped
            return .done
        case .next, .previous:
            guard state == .playing else { commands.removeLast(); return .notPlaying }
            return .done
        case .status:
            return .done
        }
    }

    public func nowPlaying(platform: MusicPlatform) async -> NowPlayingInfo? {
        guard controllable.contains(platform) else { return nil }
        return nowPlayingInfo
    }
}

// MARK: - La herramienta

/// control_music — pausar, seguir, parar, cambiar de canción, o ver qué suena.
public final class ControlMusicTool: AgentTool, Sendable {
    public static let name = "control_music"
    public static let description = """
    Controla la música que ya está sonando. 'action' puede ser: 'pause' (pausar), \
    'resume' (seguir), 'stop' (parar), 'next' (siguiente canción), 'previous' (anterior) \
    o 'status' (saber qué suena, sin cambiar nada). Úsalo cuando el usuario diga "para la \
    música", "pon otra", "¿qué está sonando?" y parecidos; para EMPEZAR a sonar algo usa \
    play_music, no esto. Lee 'status': 'done' = la orden se dio y el reproductor lo \
    confirma; 'playing' (solo con action 'status') = está sonando, y vienen 'title' y \
    'artist'; 'not_playing' = no había nada sonando, dilo tal cual y no afirmes que \
    pausaste algo; 'unsupported' = esa app no se puede controlar en este dispositivo \
    (Spotify en iPhone, por ejemplo), explícaselo al usuario; 'invalid_action' = la \
    acción no existe, mira 'valid_actions'; 'failed' = se dio la orden y no obedeció.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "action", type: .string, description: "pause, resume, stop, next, previous o status", required: true),
        AgentToolParam(name: "platform", type: .string, description: "'apple_music' (por defecto) o 'spotify'", required: false)
    ]

    private let controller: any MusicPlaybackControlling

    public init(controller: any MusicPlaybackControlling = MusicPlaybackControllerFactory.make()) {
        self.controller = controller
    }

    public func run(argsJSON: String) async -> String {
        guard let command = MusicCommand.parse(CreateNoteTool.parseString(named: "action", from: argsJSON)) else {
            return ToolJSONOutput.object([
                "status": "invalid_action",
                "valid_actions": MusicCommand.allNames,
                "message": "No entendí esa acción. Usa una de 'valid_actions'."
            ])
        }
        let platform = MusicPlatform.parse(CreateNoteTool.parseString(named: "platform", from: argsJSON)) ?? .appleMusic

        if command == .status {
            let info = await controller.nowPlaying(platform: platform)
            let outcome = await controller.control(.status, platform: platform)
            if outcome == .unsupported {
                return Self.unsupported(platform: platform, command: command)
            }
            guard let info, info.isPlaying || outcome == .done else {
                return ToolJSONOutput.object([
                    "status": "not_playing",
                    "platform": platform.rawValue,
                    "message": "No hay nada sonando en \(platform.displayName)."
                ])
            }
            return ToolJSONOutput.object([
                "status": "playing",
                "platform": platform.rawValue,
                "title": info.title,
                "artist": info.artist,
                "message": [info.title, info.artist].compactMap { $0 }.isEmpty
                    ? "Está sonando algo en \(platform.displayName)."
                    : "Suena «\(info.title ?? "?")»\(info.artist.map { " de \($0)" } ?? "") en \(platform.displayName)."
            ])
        }

        let outcome = await controller.control(command, platform: platform)
        switch outcome {
        case .done:
            let info = await controller.nowPlaying(platform: platform)
            return ToolJSONOutput.object([
                "status": "done",
                "action": command.rawValue,
                "platform": platform.rawValue,
                "title": info?.title,
                "artist": info?.artist,
                "message": Self.doneMessage(command: command, platform: platform, info: info)
            ])
        case .notPlaying:
            return ToolJSONOutput.object([
                "status": "not_playing",
                "action": command.rawValue,
                "platform": platform.rawValue,
                "message": "No hay nada sonando en \(platform.displayName), así que no había nada que \(command.spanishName)."
            ])
        case .unsupported:
            return Self.unsupported(platform: platform, command: command)
        case .failed:
            return ToolJSONOutput.object([
                "status": "failed",
                "action": command.rawValue,
                "platform": platform.rawValue,
                "message": "Se dio la orden a \(platform.displayName) y no obedeció. No afirmes que la música cambió."
            ])
        }
    }

    private static func unsupported(platform: MusicPlatform, command: MusicCommand) -> String {
        ToolJSONOutput.object([
            "status": "unsupported",
            "action": command.rawValue,
            "platform": platform.rawValue,
            "message": "En este dispositivo no se puede controlar \(platform.displayName) desde Gemma. Dile al usuario que lo haga desde la app."
        ])
    }

    private static func doneMessage(command: MusicCommand, platform: MusicPlatform, info: NowPlayingInfo?) -> String {
        switch command {
        case .pause: return "Música pausada en \(platform.displayName)."
        case .resume: return "Música reanudada en \(platform.displayName)."
        case .stop: return "Música parada en \(platform.displayName)."
        case .next, .previous:
            guard let title = info?.title else {
                return command == .next
                    ? "Pasé a la siguiente en \(platform.displayName)."
                    : "Volví a la anterior en \(platform.displayName)."
            }
            return "Ahora suena «\(title)»\(info?.artist.map { " de \($0)" } ?? "")."
        case .status: return "Estado consultado."
        }
    }
}
