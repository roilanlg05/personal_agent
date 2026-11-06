import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Apertura de URLs del sistema.
///
/// Ambos métodos son `async` porque en iOS `UIApplication` solo puede consultarse desde
/// el actor principal: los tools corren fuera de él, así que la implementación real
/// necesita saltar a `@MainActor`. Llamar a `UIApplication.shared` desde otro hilo
/// dispara el comprobador de hilo principal y puede terminar en caída.
public protocol AppURLOpening: Sendable {
    func canOpenURL(_ url: URL) async -> Bool
    func openURL(_ url: URL) async -> Bool
}

public final class MockAppURLOpener: AppURLOpening, @unchecked Sendable {
    public var openedURLs: [URL] = []
    public var supportedSchemes: Set<String> = []
    public var shouldSucceed: Bool = true

    public init(supportedSchemes: Set<String> = ["spotify", "whatsapp", "youtube", "music", "notes", "camera", "app-prefs"]) {
        self.supportedSchemes = supportedSchemes
    }

    public func canOpenURL(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return supportedSchemes.isEmpty || supportedSchemes.contains(scheme)
    }

    public func openURL(_ url: URL) async -> Bool {
        guard shouldSucceed else { return false }
        openedURLs.append(url)
        return true
    }
}

public final class SystemAppURLOpener: AppURLOpening, Sendable {
    public init() {}

    public func canOpenURL(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run { UIApplication.shared.canOpenURL(url) }
        #elseif canImport(AppKit)
        return await MainActor.run { NSWorkspace.shared.urlForApplication(toOpen: url) != nil }
        #else
        return true
        #endif
    }

    public func openURL(_ url: URL) async -> Bool {
        await Self.openOnMainActor(url)
    }

    @MainActor
    private static func openOnMainActor(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await UIApplication.shared.open(url, options: [:])
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }
}

public final class AppLauncherService: Sendable {
    private let urlOpener: any AppURLOpening

    // Standard URL schemes for iOS / Apple ecosystem apps
    private static let knownApps: [String: String] = [
        "spotify": "spotify://",
        "whatsapp": "whatsapp://",
        "youtube": "youtube://",
        "musica": "music://",
        "apple music": "music://",
        "music": "music://",
        "podcast": "podcast://",
        "podcasts": "podcast://",
        "notas": "mobilenotes://",
        "notes": "mobilenotes://",
        "fotos": "photos-redirect://",
        "photos": "photos-redirect://",
        "ajustes": "App-Prefs:root",
        "configuracion": "App-Prefs:root",
        "settings": "App-Prefs:root",
        "telegram": "tg://",
        "camara": "camera://",
        "camera": "camera://",
        "archivos": "shareddocuments://",
        "files": "shareddocuments://",
        "calculadora": "calculator://",
        "calculator": "calculator://",
        "reloj": "clock-alarm://",
        "clock": "clock-alarm://"
    ]

    public init(urlOpener: any AppURLOpening = SystemAppURLOpener()) {
        self.urlOpener = urlOpener
    }

    public func resolveURL(for appName: String, payload: String? = nil) -> URL? {
        let cleaned = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()

        // Direct custom URL scheme
        if cleaned.contains("://") {
            return URL(string: cleaned)
        }

        if let baseScheme = Self.knownApps[cleaned] {
            if let payload = payload, !payload.isEmpty,
               let encoded = payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                if cleaned == "whatsapp" {
                    return URL(string: "whatsapp://send?text=\(encoded)")
                } else if cleaned == "spotify" {
                    return URL(string: "spotify:search:\(encoded)")
                } else if cleaned == "youtube" {
                    return URL(string: "youtube://results?search_query=\(encoded)")
                }
            }
            return URL(string: baseScheme)
        }

        // Generic fallback scheme: <name>://
        let normalizedScheme = cleaned.replacingOccurrences(of: " ", with: "")
        return URL(string: "\(normalizedScheme)://")
    }

    public func launchApp(name: String, payload: String? = nil) async throws -> (opened: Bool, url: URL) {
        guard let url = resolveURL(for: name, payload: payload) else {
            throw NSError(domain: "AppLauncher", code: 400, userInfo: [NSLocalizedDescriptionKey: "No se pudo formar una URL válida para la app '\(name)'."])
        }

        let success = await urlOpener.openURL(url)
        return (success, url)
    }
}
