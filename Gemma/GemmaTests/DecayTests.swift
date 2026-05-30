import XCTest
@testable import Gemma

final class DecayTests: XCTestCase {
    func testDecaysOverTime() {
        let s0 = Decay.effectiveSalience(base: 10, decayRate: 0.001, elapsedSeconds: 0)
        let s1 = Decay.effectiveSalience(base: 10, decayRate: 0.001, elapsedSeconds: 1000)
        XCTAssertEqual(s0, 10, accuracy: 0.001)
        XCTAssertLessThan(s1, s0)
    }

    func testReinforceCaps() {
        XCTAssertEqual(Decay.reinforce(current: 9.8, bump: 0.5, cap: 10), 10, accuracy: 0.001)
        XCTAssertEqual(Decay.reinforce(current: 1.0, bump: 0.5, cap: 10), 1.5, accuracy: 0.001)
    }

    func testPromote() {
        XCTAssertTrue(Decay.shouldPromote(mentionCount: 3, origin: .extracted, permanent: false))
        XCTAssertTrue(Decay.shouldPromote(mentionCount: 1, origin: .explicit, permanent: false))
        XCTAssertTrue(Decay.shouldPromote(mentionCount: 1, origin: .extracted, permanent: true))
        XCTAssertFalse(Decay.shouldPromote(mentionCount: 1, origin: .extracted, permanent: false))
    }

    func testForget() {
        let now = 1000.0
        XCTAssertFalse(Decay.shouldForget(layer: .identity, effectiveSalience: 0, ttlExpiresAt: 1, now: now))
        XCTAssertTrue(Decay.shouldForget(layer: .daily, effectiveSalience: 0.01, ttlExpiresAt: nil, now: now))
        XCTAssertTrue(Decay.shouldForget(layer: .live, effectiveSalience: 5, ttlExpiresAt: 999, now: now))
        XCTAssertFalse(Decay.shouldForget(layer: .daily, effectiveSalience: 5, ttlExpiresAt: nil, now: now))
    }
}
