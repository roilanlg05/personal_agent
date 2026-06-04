import XCTest
@testable import Gemma

final class KeychainStoreTests: XCTestCase {
    func test_set_get_delete_roundTrip() {
        let acct = "apiKey.test.\(UUID().uuidString)"
        KeychainStore.shared.set("secret-123", account: acct)
        XCTAssertEqual(KeychainStore.shared.get(account: acct), "secret-123")
        KeychainStore.shared.set("secret-456", account: acct) // overwrite
        XCTAssertEqual(KeychainStore.shared.get(account: acct), "secret-456")
        KeychainStore.shared.delete(account: acct)
        XCTAssertNil(KeychainStore.shared.get(account: acct))
    }
}
