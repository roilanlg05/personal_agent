import Foundation

/// Minimal thread-safe box for collecting from a Sendable closure in tests.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ initial: Value) { self.value = initial }
    func write(_ f: (inout Value) -> Void) { lock.lock(); f(&value); lock.unlock() }
    func read<T>(_ f: (Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(value) }
}
