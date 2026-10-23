import Foundation
import Synchronization

/// Lock-free stereo buffer between two audio clocks (one producer, one consumer).
///
/// The two clocks drift slightly: a cubic resampler continuously adjusts the read
/// rate (±0.5% max) to keep the fill level around the target.
/// Used for the virtual output (engine → virtual device) and the call return
/// (virtual device → headphones).
public final class DriftRing {
    public let capacity = 32768
    private let mask: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    // Consumer state (its thread only, after `prepare`).
    private var readPos: Double = 0
    private var running = false
    private var fillAvg: Double = 0
    private var target: Double = 512
    /// Current buffer target (raised after each underrun).
    public let targetStat = RTFloat(512)
    /// Observed cycle sizes on the producer and consumer sides.
    public let producerBlock = RTFloat(0)
    public let consumerBlock = RTFloat(0)
    public let underruns = RTCounter()
    public let overruns = RTCounter()
    public let ratioPPM = RTFloat(0)
    public let fillFrames = RTFloat(0)

    public init() {
        mask = capacity - 1
        bufL = .allocate(capacity: capacity); bufL.initialize(repeating: 0, count: capacity)
        bufR = .allocate(capacity: capacity); bufR.initialize(repeating: 0, count: capacity)
    }

    deinit { bufL.deallocate(); bufR.deallocate() }

    /// Call before starting the consumer (no active consumer).
    public func prepare(producerFrames: Int, consumerFrames: Int) {
        // Measured on an Apple Silicon Mac with a USB interface: jitter between the two clocks reaches
        // ≈ 400 frames; starting at 448 avoids dropouts while adapting.
        target = Double(max(producerFrames + consumerFrames + 64, 448))
        targetStat.store(Float(target))
        running = false
        fillAvg = target
        // Read from what gets written from now on (the write counter is never reset).
        readPos = Double(written.load(ordering: .acquiring))
    }

    public var targetFrames: Int { Int(targetStat.load()) }

    // MARK: Producer

    @inline(__always)
    public func push(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, count n: Int) {
        let w = written.load(ordering: .relaxed)
        producerBlock.store(Float(n))
        for i in 0..<n { bufL[(w + i) & mask] = l[i]; bufR[(w + i) & mask] = r[i] }
        written.store(w + n, ordering: .releasing)
    }

    // MARK: Consumer

    /// Reads `n` interleaved frames (`stride` channels, only the first two are written).
    /// Writes silence until the buffer has reached its target, and returns false in that case.
    @inline(__always) @discardableResult
    public func pull(into dst: UnsafeMutablePointer<Float>, stride: Int, frames n: Int) -> Bool {
        dst.update(repeating: 0, count: n * stride)
        let w = Double(written.load(ordering: .acquiring))
        consumerBlock.store(Float(n))

        if !running {
            // Priming, or resuming after an underrun: wait for the buffer to reach the target
            // without ever moving back. Moving the read position back replayed audio already sent
            // (up to 40 ms), heard as an echo or choppy sound in OBS or FaceTime.
            guard w - readPos >= target else { return false }
            running = true
            fillAvg = target
        }
        var avail = w - readPos
        if avail < Double(n) + 4 {
            // Underrun: silence until back at the target, which grows by 32 frames
            // (capped at 2048) so it does not happen again.
            underruns.increment()
            target = min(target + 32, 2048)
            targetStat.store(Float(target))
            running = false
            return false
        }
        if avail > Double(capacity - 4 * n) {
            overruns.increment()
            readPos = w - target
            avail = target
        }
        fillAvg += (avail - fillAvg) * 0.01
        // Proportional drift correction, bounded to ±0.5%.
        let ratio = 1 + min(max((fillAvg - target) * 0.00002, -0.005), 0.005)
        ratioPPM.store(Float((ratio - 1) * 1_000_000))
        fillFrames.store(Float(avail))

        for i in 0..<n {
            let ip = Int(readPos.rounded(.down))
            let t = Float(readPos - Double(ip))
            dst[i * stride] = cubic(bufL, ip, t)
            if stride > 1 { dst[i * stride + 1] = cubic(bufR, ip, t) }
            readPos += ratio
        }
        return true
    }

    /// Cubic Hermite interpolation (Catmull-Rom).
    @inline(__always)
    private func cubic(_ b: UnsafeMutablePointer<Float>, _ i: Int, _ t: Float) -> Float {
        let y0 = b[(i - 1) & mask], y1 = b[i & mask], y2 = b[(i + 1) & mask], y3 = b[(i + 2) & mask]
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }
}
