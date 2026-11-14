import Foundation

public struct GemmaContact: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let givenName: String
    public let familyName: String
    public let nickname: String?
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(
        id: String = UUID().uuidString,
        givenName: String,
        familyName: String = "",
        nickname: String? = nil,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = []
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }

    public var fullName: String {
        let joined = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? (nickname ?? "Sin nombre") : joined
    }
}
