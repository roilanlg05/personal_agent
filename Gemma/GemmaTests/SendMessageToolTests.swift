import XCTest
@testable import Gemma

final class MockMessageSender: MessageSending, @unchecked Sendable {
    var availableChannels: Set<MessageChannel>
    var result: MessageSendResult
    private(set) var sent: [(number: String, body: String, channel: MessageChannel)] = []

    init(
        availableChannels: Set<MessageChannel> = [.messages, .whatsapp],
        result: MessageSendResult = MessageSendResult(outcome: .sent)
    ) {
        self.availableChannels = availableChannels
        self.result = result
    }

    func canSend(channel: MessageChannel) async -> Bool { availableChannels.contains(channel) }

    func send(to number: String, body: String, channel: MessageChannel) async -> MessageSendResult {
        sent.append((number, body, channel))
        return result
    }
}

final class MockContactsManager: ContactsManaging, @unchecked Sendable {
    var contacts: [GemmaContact]
    var errorToThrow: Error?

    init(contacts: [GemmaContact] = [], errorToThrow: Error? = nil) {
        self.contacts = contacts
        self.errorToThrow = errorToThrow
    }

    func requestAccess() async throws -> Bool {
        if let errorToThrow { throw errorToThrow }
        return true
    }

    func searchContacts(query: String) async throws -> [GemmaContact] {
        if let errorToThrow { throw errorToThrow }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        return contacts.filter {
            $0.fullName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased().contains(needle)
        }
    }
}

final class SendMessageToolTests: XCTestCase {

    private func contact(_ given: String, family: String = "", phones: [String] = ["+15551234567"]) -> GemmaContact {
        GemmaContact(givenName: given, familyName: family, phoneNumbers: phones)
    }

    private func tool(
        sender: MockMessageSender,
        contacts: MockContactsManager = MockContactsManager()
    ) -> SendMessageTool {
        SendMessageTool(sender: sender, contacts: contacts, aliases: ContactAliasStore())
    }

    func test_metadata() {
        XCTAssertEqual(SendMessageTool.name, "send_message")
        XCTAssertTrue(SendMessageTool.parameters.contains { $0.name == "to" && $0.required })
        XCTAssertTrue(SendMessageTool.parameters.contains { $0.name == "message" && $0.required })
    }

    // MARK: - Número directo

    func test_sendsToADirectNumber() async throws {
        let sender = MockMessageSender()
        let out = await tool(sender: sender)
            .run(argsJSON: #"{"to": "+1 (555) 123-4567", "message": "voy de camino"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "sent")
        XCTAssertEqual(sender.sent.first?.number, "+15551234567", "El número debe ir normalizado")
        XCTAssertEqual(sender.sent.first?.body, "voy de camino")
    }

    func test_numberDetection() {
        XCTAssertTrue(SendMessageTool.looksLikePhoneNumber("+1 (555) 123-4567"))
        XCTAssertTrue(SendMessageTool.looksLikePhoneNumber("5551234"))
        XCTAssertFalse(SendMessageTool.looksLikePhoneNumber("mamá"), "Un nombre no es un número")
        XCTAssertFalse(SendMessageTool.looksLikePhoneNumber("Juan 123"))
        XCTAssertFalse(SendMessageTool.looksLikePhoneNumber("12345"), "Cinco dígitos no es un teléfono")
    }

    func test_normalizeNumber_keepsInternationalPrefix() {
        XCTAssertEqual(SendMessageTool.normalizeNumber("+1 (555) 123-4567"), "+15551234567")
        XCTAssertEqual(SendMessageTool.normalizeNumber("555.123.4567"), "5551234567")
    }

    // MARK: - Resolución de contactos

    func test_resolvesContactByName() async throws {
        let sender = MockMessageSender()
        let contacts = MockContactsManager(contacts: [contact("Marcos", family: "Pérez", phones: ["555-999-1111"])])
        let out = await tool(sender: sender, contacts: contacts)
            .run(argsJSON: #"{"to": "Marcos", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "sent")
        XCTAssertEqual(parsed["contact"] as? String, "Marcos Pérez")
        XCTAssertEqual(sender.sent.first?.number, "5559991111")
    }

    func test_resolvesRelationshipAlias() async throws {
        // 'mamá' debe pasar por el alias antes de buscar en la libreta.
        let sender = MockMessageSender()
        let contacts = MockContactsManager(contacts: [contact("Mamá")])
        let out = await tool(sender: sender, contacts: contacts)
            .run(argsJSON: #"{"to": "mi madre", "message": "te llamo luego"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "sent")
        XCTAssertEqual(parsed["contact"] as? String, "Mamá")
    }

    func test_severalContactsMatch_asksInsteadOfGuessing() async throws {
        let sender = MockMessageSender()
        let contacts = MockContactsManager(contacts: [
            contact("Marcos", family: "Pérez", phones: ["5551110000"]),
            contact("Marcos", family: "Gómez", phones: ["5552220000"])
        ])
        let out = await tool(sender: sender, contacts: contacts)
            .run(argsJSON: #"{"to": "Marcos", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ambiguous")
        XCTAssertEqual((parsed["candidates"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(sender.sent.isEmpty, "Mandar el mensaje a la persona equivocada no se deshace")
    }

    func test_contactWithoutPhone_isReported() async throws {
        let sender = MockMessageSender()
        let contacts = MockContactsManager(contacts: [contact("Ana", phones: [])])
        let out = await tool(sender: sender, contacts: contacts)
            .run(argsJSON: #"{"to": "Ana", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "no_phone_number")
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func test_unknownContact_isReported() async throws {
        let sender = MockMessageSender()
        let out = await tool(sender: sender, contacts: MockContactsManager(contacts: [contact("Ana")]))
            .run(argsJSON: #"{"to": "Fulano", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "not_found")
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func test_permissionDenied_isReportedAsActionable() async throws {
        let denied = NSError(
            domain: "ContactsService", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Permiso denegado para acceder a Contactos"]
        )
        let sender = MockMessageSender()
        let out = await tool(sender: sender, contacts: MockContactsManager(errorToThrow: denied))
            .run(argsJSON: #"{"to": "Marcos", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "permission_required")
        XCTAssertTrue((parsed["message"] as? String ?? "").contains("Ajustes"))
        XCTAssertTrue(sender.sent.isEmpty)
    }

    // MARK: - Resultados honestos

    func test_cancelled_isNotReportedAsSent() async throws {
        let sender = MockMessageSender(result: MessageSendResult(outcome: .cancelled))
        let out = await tool(sender: sender).run(argsJSON: #"{"to": "5551234567", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "cancelled")
        let message = try XCTUnwrap(parsed["message"] as? String)
        XCTAssertTrue(message.contains("No se envió"))
    }

    func test_composePresented_asksUserToPressSend() async throws {
        let sender = MockMessageSender(result: MessageSendResult(outcome: .composePresented))
        let out = await tool(sender: sender)
            .run(argsJSON: #"{"to": "5551234567", "message": "hola", "channel": "whatsapp"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "compose_presented")
        XCTAssertEqual(parsed["channel"] as? String, "whatsapp")
        XCTAssertTrue((parsed["message"] as? String ?? "").contains("todavía no ha salido"))
    }

    func test_failure_includesErrorMessage() async throws {
        let sender = MockMessageSender(
            result: MessageSendResult(outcome: .failed, errorMessage: "sin cobertura")
        )
        let out = await tool(sender: sender).run(argsJSON: #"{"to": "5551234567", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "failed")
        XCTAssertEqual(parsed["error_message"] as? String, "sin cobertura")
    }

    func test_noSenderAvailable_reportsUnavailable() async throws {
        let out = await SendMessageTool(
            sender: nil, contacts: MockContactsManager(), aliases: ContactAliasStore()
        ).run(argsJSON: #"{"to": "5551234567", "message": "hola"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "unavailable")
    }

    // MARK: - Canal y argumentos

    func test_channelParsing() {
        XCTAssertEqual(MessageChannel.parse(nil), .messages)
        XCTAssertEqual(MessageChannel.parse("whatsapp"), .whatsapp)
        XCTAssertEqual(MessageChannel.parse("WhatsApp"), .whatsapp)
        XCTAssertEqual(MessageChannel.parse("sms"), .messages)
        XCTAssertEqual(MessageChannel.parse("imessage"), .messages)
    }

    func test_missingArguments_returnValidErrorJSON() async throws {
        let toolUnderTest = tool(sender: MockMessageSender())
        for args in ["{}", #"{"to": "5551234567"}"#, #"{"message": "hola"}"#, #"{"to": "", "message": "hola"}"#] {
            let out = await toolUnderTest.run(argsJSON: args)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
            XCTAssertNotNil(parsed["error"], "Argumentos '\(args)' deberían dar error")
        }
    }

    func test_outputIsValidJSONWithQuotesInMessage() async throws {
        let args = try String(
            data: JSONSerialization.data(withJSONObject: [
                "to": "5551234567",
                "message": #"Él dijo "vamos" \ ahora"#
            ]),
            encoding: .utf8
        ) ?? "{}"
        let sender = MockMessageSender()
        let out = await tool(sender: sender).run(argsJSON: args)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            "Salida inválida: \(out)"
        )
        XCTAssertEqual(parsed["status"] as? String, "sent")
        XCTAssertEqual(sender.sent.first?.body, #"Él dijo "vamos" \ ahora"#)
    }

    #if os(macOS)
    func test_appleScriptEscaping_preventsScriptInjection() {
        let escaped = AppleScriptMessagesSender.escape(#"hola" & do shell script "rm -rf ~"#)
        // Toda comilla debe quedar precedida de barra invertida: una suelta cerraría el
        // literal y el resto del texto se ejecutaría como guion.
        let quotes = escaped.filter { $0 == "\"" }.count
        let escapedQuotes = escaped.ranges(of: #"\""#).count
        XCTAssertEqual(quotes, escapedQuotes, "Queda alguna comilla sin escapar en: \(escaped)")
        XCTAssertEqual(escaped.filter { $0 == "\n" }.count, 0)
    }
    #endif
}
