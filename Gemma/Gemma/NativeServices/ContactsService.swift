import Foundation
import Contacts

public protocol ContactsManaging: Sendable {
    func requestAccess() async throws -> Bool
    func searchContacts(query: String) async throws -> [GemmaContact]
}

public final class AppleContactsManager: ContactsManaging, @unchecked Sendable {
    private let contactStore = CNContactStore()

    public init() {}

    public func requestAccess() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func searchContacts(query: String) async throws -> [GemmaContact] {
        let hasAccess = try await requestAccess()
        guard hasAccess else {
            throw NSError(
                domain: "ContactsService",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Permiso denegado para acceder a Contactos"]
            )
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        let predicate = CNContact.predicateForContacts(matchingName: query)
        let cnContacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

        return cnContacts.map { c in
            let phones = c.phoneNumbers.map { $0.value.stringValue }
            let emails = c.emailAddresses.map { String($0.value) }
            return GemmaContact(
                id: c.identifier,
                givenName: c.givenName,
                familyName: c.familyName,
                nickname: c.nickname.isEmpty ? nil : c.nickname,
                phoneNumbers: phones,
                emailAddresses: emails
            )
        }
    }
}
