import Foundation

/// Pure salience/forgetting math. Human-like: exponential decay + reinforcement.
/// No I/O, no dependencies — fully unit-testable.
enum Decay {
    /// Effective salience now, given base salience, decay rate and elapsed seconds.
    static func effectiveSalience(base: Double, decayRate: Double, elapsedSeconds: Double) -> Double {
        base * exp(-decayRate * max(0, elapsedSeconds))
    }

    /// Reinforcement on re-mention: bump salience (capped) and return the new base.
    static func reinforce(current: Double, bump: Double = 0.5, cap: Double = 10) -> Double {
        min(cap, current + bump)
    }

    /// Whether a node should be promoted L2(daily) → L4(identity).
    static func shouldPromote(mentionCount: Int, origin: Origin, permanent: Bool, threshold: Int = 3) -> Bool {
        permanent || origin == .explicit || mentionCount >= threshold
    }

    /// Whether a node is eligible for forgetting (soft-delete). Identity never forgets.
    static func shouldForget(layer: MemoryLayer, effectiveSalience: Double, ttlExpiresAt: Double?, now: Double, floor: Double = 0.05) -> Bool {
        if layer == .identity { return false }
        if let ttl = ttlExpiresAt, now > ttl { return true }
        return effectiveSalience < floor
    }

    /// Default decay rate per layer (per second; tuned so live fades over minutes, daily over days).
    static func defaultDecayRate(for layer: MemoryLayer) -> Double {
        switch layer {
        case .live: return 1.0 / (30 * 60)            // ~30 min
        case .daily: return 1.0 / (5 * 24 * 3600)     // ~5 days
        case .identity: return 1.0 / (365 * 24 * 3600) // ~1 year (near-permanent)
        case .episodic: return 1.0 / (90 * 24 * 3600)  // ~90 days (reserved, S11)
        }
    }
}
