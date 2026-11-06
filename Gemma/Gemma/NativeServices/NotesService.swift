import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Presenta la hoja de compartir del sistema con un texto.
///
/// Es la misma hoja que usan otras apps: desde ahí el usuario puede mandar el texto a
/// Notas de Apple, a Mensajes, a Correo o a quien quiera. Gemma no puede preseleccionar
/// un destino ni saber si el usuario completa el envío, así que el resultado nunca
/// afirma que el texto llegara a ningún sitio: solo que la hoja se abrió.
public protocol TextSharing: Sendable {
    /// Devuelve `true` si la hoja llegó a presentarse.
    func share(text: String, subject: String?) async -> Bool
}

#if os(iOS)
public final class ShareSheetTextSharer: TextSharing, Sendable {
    public init() {}

    public func share(text: String, subject: String?) async -> Bool {
        await present(text: text)
    }

    @MainActor
    private func present(text: String) -> Bool {
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

        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
        return true
    }
}
#endif

#if os(macOS)
public final class SharingServiceTextSharer: TextSharing, Sendable {
    public init() {}

    public func share(text: String, subject: String?) async -> Bool {
        await present(text: text)
    }

    @MainActor
    private func present(text: String) -> Bool {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first,
              let view = window.contentView else {
            return false
        }
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        return true
    }
}
#endif

/// Compartidor adecuado para la plataforma actual.
public enum TextSharingFactory {
    public static func make() -> (any TextSharing)? {
        #if os(iOS)
        return ShareSheetTextSharer()
        #elseif os(macOS)
        return SharingServiceTextSharer()
        #else
        return nil
        #endif
    }
}
