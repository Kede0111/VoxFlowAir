import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring buffer.
/// The audio thread writes, the UI reads for the analyzers.
public final class SPSCRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)

    public init(capacity: Int) {
        // Power of two for fast masking.
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    /// Called from the real-time thread.
    @inline(__always) public func write(_ src: UnsafePointer<Float>, count: Int) {
        var w = writeIndex.load(ordering: .relaxed)
        let mask = capacity - 1
        for i in 0..<count {
            storage[w & mask] = src[i]
            w &+= 1
        }
        writeIndex.store(w, ordering: .releasing)
    }

    /// Writes the average of two channels (mono check).
    @inline(__always) public func writeMix(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>?, count: Int) {
        var w = writeIndex.load(ordering: .relaxed)
        let mask = capacity - 1
        if let r {
            for i in 0..<count { storage[w & mask] = 0.5 * (l[i] + r[i]); w &+= 1 }
        } else {
            for i in 0..<count { storage[w & mask] = l[i]; w &+= 1 }
        }
        writeIndex.store(w, ordering: .releasing)
    }

    /// Copies the last `count` samples (UI side). Returns the write index.
    @discardableResult
    public func readLatest(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(count, capacity)
        let mask = capacity - 1
        var r = w &- n
        for i in 0..<n { dst[i] = storage[r & mask]; r &+= 1 }
        return w
    }

    public var totalWritten: Int { writeIndex.load(ordering: .acquiring) }

    /// Copies samples [start, start+count) if they are still in the buffer.
    public func read(from start: Int, count: Int, into dst: UnsafeMutablePointer<Float>) -> Bool {
        let w = writeIndex.load(ordering: .acquiring)
        guard start >= w - capacity, start + count <= w else { return false }
        let mask = capacity - 1
        for i in 0..<count { dst[i] = storage[(start + i) & mask] }
        return true
    }
}

/// Buffer pair for stereo correlation and the oscilloscope.
public final class StereoAnalysisTap: @unchecked Sendable {
    public let left: SPSCRingBuffer
    public let right: SPSCRingBuffer
    public init(capacity: Int = 16384) {
        left = SPSCRingBuffer(capacity: capacity)
        right = SPSCRingBuffer(capacity: capacity)
    }
    @inline(__always) public func write(l: UnsafePointer<Float>, r: UnsafePointer<Float>, count: Int) {
        left.write(l, count: count)
        right.write(r, count: count)
    }
}
