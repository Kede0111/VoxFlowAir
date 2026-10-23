import Foundation
import Synchronization

/// Values shared between the real-time thread and the rest of the app.
/// All operations are lock-free and allocation-free.

public final class RTFloat: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    public init(_ v: Float = 0) { bits = Atomic(v.bitPattern) }
    @inline(__always) public var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
    @inline(__always) public func store(_ v: Float) { bits.store(v.bitPattern, ordering: .relaxed) }
    @inline(__always) public func load() -> Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    /// Replaces with 0 and returns the previous value ("peak hold" read on the UI side).
    @inline(__always) public func take() -> Float { Float(bitPattern: bits.exchange(0, ordering: .relaxed)) }
    /// Keeps the maximum (real-time side). Allocation-free CAS loop.
    @inline(__always) public func storeMax(_ v: Float) {
        var current = bits.load(ordering: .relaxed)
        while Float(bitPattern: current) < v {
            let (exchanged, original) = bits.compareExchange(expected: current, desired: v.bitPattern, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }
}

public final class RTBool: @unchecked Sendable {
    private let raw: Atomic<Bool>
    public init(_ v: Bool = false) { raw = Atomic(v) }
    @inline(__always) public var value: Bool {
        get { raw.load(ordering: .sequentiallyConsistent) }
        set { raw.store(newValue, ordering: .sequentiallyConsistent) }
    }
}

public final class RTCounter: @unchecked Sendable {
    private let raw: Atomic<Int>
    public init(_ v: Int = 0) { raw = Atomic(v) }
    @inline(__always) public func increment(by n: Int = 1) { raw.add(n, ordering: .relaxed) }
    @inline(__always) public var value: Int { raw.load(ordering: .relaxed) }
    public func reset() { raw.store(0, ordering: .relaxed) }
}

@inline(__always) public func linearToDB(_ x: Float) -> Float { x <= 0.000_001 ? -120 : 20 * log10f(x) }
@inline(__always) public func dbToLinear(_ db: Float) -> Float { db <= -119 ? 0 : powf(10, db / 20) }
