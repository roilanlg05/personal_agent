import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Entrega un fichero `.shortcut` firmado al sistema para que el usuario lo añada.
///
/// Es el camino que no depende de iCloud: el atajo se firma una vez en un Mac
/// (`shortcuts sign --mode anyone`), viaja dentro de la app, y aquí se le pasa al
/// sistema. El usuario elige Atajos y acepta la ficha. Gemma no puede saber si la
/// aceptó, así que `present` solo informa de que la hoja llegó a abrirse.
///
/// Se probaron caminos más cortos y ninguno compra nada: `UIApplication.open(_:)`
/// rechaza las URL `file://`, `shortcuts://import-shortcut` solo acepta enlaces de
/// `icloud.com`, y el menú "Abrir en" se dibuja en iOS moderno igual que la hoja de
/// compartir. Al final el usuario siempre tiene que elegir Atajos y aceptar, así que se
/// deja la vía simple.
public protocol ShortcutFileSharing: Sendable {
    /// Devuelve `true` si la hoja llegó a presentarse.
    func present(fileURL: URL) async -> Bool
}

/// Tipo de los ficheros de atajo, según el propio sistema (`mdls`).
public enum ShortcutFileType {
    public static let identifier = "com.apple.shortcut"
    public static let fileExtension = "shortcut"
}

/// Localiza los atajos firmados que viajan dentro de la app.
public enum BundledShortcutFiles {
    /// Devuelve el `.shortcut` del bundle con ese nombre, si existe.
    public static func url(named name: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: ShortcutFileType.fileExtension)
    }
}

#if os(iOS)
/// Presenta el fichero en la hoja de compartir, donde Atajos aparece como destino.
public final class ShareSheetShortcutFileSharer: ShortcutFileSharing, Sendable {
    public init() {}

    public func present(fileURL: URL) async -> Bool {
        await presentOnMain(fileURL: fileURL)
    }

    @MainActor
    private func presentOnMain(fileURL: URL) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?
                .rootViewController else {
            return false
        }

        // Hay que presentar sobre lo que esté más arriba; si no, iOS descarta la
        // petición en silencio.
        var top = root
        while let presented = top.presentedViewController { top = presented }

        let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        // Un `.shortcut` no se copia ni se imprime: quitar esas acciones deja Atajos
        // más a la vista.
        sheet.excludedActivityTypes = [
            .copyToPasteboard, .mail, .message, .print, .assignToContact,
            .addToReadingList, .saveToCameraRoll, .postToFacebook, .postToTwitter,
            .markupAsPDF, .openInIBooks
        ]
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
        return true
    }
}
#endif

#if os(macOS)
/// En macOS basta abrir el fichero: Atajos lo reclama y muestra la ficha.
public final class WorkspaceShortcutFileSharer: ShortcutFileSharing, Sendable {
    public init() {}

    public func present(fileURL: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(fileURL) }
    }
}
#endif

public enum ShortcutFileSharerFactory {
    public static func make() -> (any ShortcutFileSharing)? {
        #if os(iOS)
        return ShareSheetShortcutFileSharer()
        #elseif os(macOS)
        return WorkspaceShortcutFileSharer()
        #else
        return nil
        #endif
    }
}

/// Doble de pruebas.
public final class MockShortcutFileSharer: ShortcutFileSharing, @unchecked Sendable {
    public var shouldSucceed: Bool
    public private(set) var presented: [URL] = []

    public init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    public func present(fileURL: URL) async -> Bool {
        guard shouldSucceed else { return false }
        presented.append(fileURL)
        return true
    }
}
