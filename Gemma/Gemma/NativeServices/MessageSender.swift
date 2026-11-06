import Foundation
#if os(iOS)
import MessageUI
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

public enum MessageChannel: String, Sendable {
    /// iMessage o SMS, según decida el sistema con ese número.
    case messages
    case whatsapp

    public static func parse(_ raw: String?) -> MessageChannel {
        let cleaned = (raw ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return cleaned.contains("whats") ? .whatsapp : .messages
    }

    public var displayName: String {
        switch self {
        case .messages: return "Mensajes"
        case .whatsapp: return "WhatsApp"
        }
    }
}

public enum MessageSendOutcome: String, Sendable {
    /// El mensaje salió. Verificado por el sistema.
    case sent
    /// Se abrió la app con el mensaje preparado: el usuario debe pulsar enviar.
    case composePresented = "compose_presented"
    /// El usuario descartó el mensaje sin enviarlo.
    case cancelled
    case failed
    /// El canal no está disponible en este dispositivo.
    case unavailable
}

public struct MessageSendResult: Sendable, Equatable {
    public let outcome: MessageSendOutcome
    public let errorMessage: String?

    public init(outcome: MessageSendOutcome, errorMessage: String? = nil) {
        self.outcome = outcome
        self.errorMessage = errorMessage
    }
}

/// Envía un mensaje de texto a un número.
public protocol MessageSending: Sendable {
    /// ¿Puede este dispositivo enviar por este canal?
    func canSend(channel: MessageChannel) async -> Bool
    func send(to number: String, body: String, channel: MessageChannel) async -> MessageSendResult
}

// MARK: - iOS: compositor nativo del sistema

#if os(iOS)
/// Usa `MFMessageComposeViewController`, el compositor de Mensajes del sistema.
///
/// Es mejor que abrir una URL `sms:`: el destinatario y el texto llegan ya rellenos, el
/// usuario solo pulsa enviar, y **el sistema nos dice si se envió, se canceló o falló**,
/// así que Gemma puede informar de la verdad en lugar de suponerla. Apple no permite
/// enviar un SMS sin que el usuario lo confirme, y eso es deliberado.
public final class MessageComposerSender: MessageSending, Sendable {
    private let whatsAppOpener: any AppURLOpening

    public init(whatsAppOpener: any AppURLOpening = SystemAppURLOpener()) {
        self.whatsAppOpener = whatsAppOpener
    }

    public func canSend(channel: MessageChannel) async -> Bool {
        switch channel {
        case .messages:
            return await MainActor.run { MFMessageComposeViewController.canSendText() }
        case .whatsapp:
            guard let url = URL(string: "whatsapp://send") else { return false }
            return await whatsAppOpener.canOpenURL(url)
        }
    }

    public func send(to number: String, body: String, channel: MessageChannel) async -> MessageSendResult {
        switch channel {
        case .whatsapp:
            return await sendViaWhatsApp(number: number, body: body)
        case .messages:
            guard await canSend(channel: .messages) else {
                return MessageSendResult(
                    outcome: .unavailable,
                    errorMessage: "Este dispositivo no puede enviar mensajes de texto."
                )
            }
            return await presentComposer(number: number, body: body)
        }
    }

    private func sendViaWhatsApp(number: String, body: String) async -> MessageSendResult {
        let digits = number.replacingOccurrences(of: "+", with: "")
            .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        guard let url = URL(string: "whatsapp://send?phone=\(digits)&text=\(encoded)") else {
            return MessageSendResult(outcome: .failed, errorMessage: "No se pudo formar la URL de WhatsApp.")
        }
        guard await whatsAppOpener.canOpenURL(url) else {
            return MessageSendResult(outcome: .unavailable, errorMessage: "WhatsApp no está instalado.")
        }
        guard await whatsAppOpener.openURL(url) else {
            return MessageSendResult(outcome: .failed, errorMessage: "WhatsApp no aceptó la petición.")
        }
        // WhatsApp abre la conversación con el texto puesto; enviar lo hace el usuario.
        return MessageSendResult(outcome: .composePresented)
    }

    @MainActor
    private func presentComposer(number: String, body: String) async -> MessageSendResult {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?
                .rootViewController else {
            return MessageSendResult(outcome: .failed, errorMessage: "No hay ninguna ventana donde mostrar el mensaje.")
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }

        return await withCheckedContinuation { continuation in
            let composer = MFMessageComposeViewController()
            composer.recipients = [number]
            composer.body = body

            // El delegado tiene que seguir vivo mientras la hoja esté en pantalla: él
            // mismo guarda la referencia y la suelta al terminar.
            let delegate = ComposerDelegate { result in
                continuation.resume(returning: result)
            }
            composer.messageComposeDelegate = delegate
            top.present(composer, animated: true)
        }
    }

    /// Traduce el resultado del compositor y mantiene vivo el delegado.
    @MainActor
    private final class ComposerDelegate: NSObject, MFMessageComposeViewControllerDelegate {
        private var onFinish: ((MessageSendResult) -> Void)?
        private var strongSelf: ComposerDelegate?

        init(onFinish: @escaping (MessageSendResult) -> Void) {
            self.onFinish = onFinish
            super.init()
            self.strongSelf = self
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
            let outcome: MessageSendResult
            switch result {
            case .sent: outcome = MessageSendResult(outcome: .sent)
            case .cancelled: outcome = MessageSendResult(outcome: .cancelled)
            case .failed: outcome = MessageSendResult(outcome: .failed, errorMessage: "El sistema no pudo enviar el mensaje.")
            @unknown default: outcome = MessageSendResult(outcome: .failed)
            }
            // Solo una vez: si el sistema llamara de nuevo, la continuación ya se
            // habría reanudado y el proceso caería.
            let callback = onFinish
            onFinish = nil
            strongSelf = nil
            callback?(outcome)
        }
    }
}
#endif

// MARK: - macOS: envío real por Apple Events

#if os(macOS)
/// Envía por Mensajes guionando la app. En macOS el envío sí es automático.
///
/// Requiere `NSAppleEventsUsageDescription` y que el usuario autorice a Gemma a
/// controlar Mensajes la primera vez.
public final class AppleScriptMessagesSender: MessageSending, Sendable {
    private let whatsAppOpener: any AppURLOpening

    public init(whatsAppOpener: any AppURLOpening = SystemAppURLOpener()) {
        self.whatsAppOpener = whatsAppOpener
    }

    public func canSend(channel: MessageChannel) async -> Bool {
        switch channel {
        case .messages:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") != nil
        case .whatsapp:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") != nil
        }
    }

    public func send(to number: String, body: String, channel: MessageChannel) async -> MessageSendResult {
        if channel == .whatsapp {
            let digits = number.replacingOccurrences(of: "+", with: "")
                .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
            guard let url = URL(string: "whatsapp://send?phone=\(digits)&text=\(encoded)"),
                  await whatsAppOpener.canOpenURL(url) else {
                return MessageSendResult(outcome: .unavailable, errorMessage: "WhatsApp no está instalado.")
            }
            guard await whatsAppOpener.openURL(url) else {
                return MessageSendResult(outcome: .failed, errorMessage: "WhatsApp no aceptó la petición.")
            }
            return MessageSendResult(outcome: .composePresented)
        }

        guard await canSend(channel: .messages) else {
            return MessageSendResult(outcome: .unavailable, errorMessage: "Mensajes no está disponible.")
        }

        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(Self.escape(number))" of targetService
            send "\(Self.escape(body))" to targetBuddy
        end tell
        """

        if let failure = await Self.run(script) {
            return MessageSendResult(outcome: .failed, errorMessage: failure)
        }
        return MessageSendResult(outcome: .sent)
    }

    /// `nil` si el guion se ejecutó bien; si no, el mensaje de error de AppleScript.
    @MainActor
    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            return "No se pudo compilar el guion de Mensajes."
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Mensajes rechazó el envío."
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
#endif

public enum MessageSenderFactory {
    public static func make() -> (any MessageSending)? {
        #if os(iOS)
        // En iOS el compositor del sistema siempre exige que el usuario pulse enviar, y
        // no hay forma de evitarlo: se probó delegar en un atajo con "Enviar mensaje" y
        // acaba en el mismo sitio, con un paso manual más.
        return MessageComposerSender()
        #elseif os(macOS)
        // En macOS los Apple Events sí envían de verdad, sin confirmación.
        return AppleScriptMessagesSender()
        #else
        return nil
        #endif
    }
}
