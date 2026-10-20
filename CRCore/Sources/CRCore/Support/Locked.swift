import Foundation

/// A value protected by a lock. The GRBL layer is a port of multi-threaded C++ code that used
/// mutexes and atomics; this keeps the same model while satisfying Swift 6 strict concurrency.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value {
        get { withLock { $0 } }
        set { withLock { $0 = newValue } }
    }
}

/// Monotonic time in seconds, used for the GRBL idle/timeout logic.
@inline(__always)
func monotonicNow() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

@inline(__always)
func sleep(milliseconds: Int) {
    if milliseconds > 0 { usleep(useconds_t(milliseconds * 1000)) }
}
