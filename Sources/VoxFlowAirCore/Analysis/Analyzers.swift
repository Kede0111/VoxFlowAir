import Foundation
import Accelerate

/// Spectrum analyzer (vDSP FFT, Hann window) fed by a ring buffer.
/// Runs on the UI side, never on the audio thread.
public final class SpectrumAnalyzer {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var input: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    public private(set) var smoothedDB: [Float]

    public init(size: Int = 4096) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        input = .init(repeating: 0, count: size)
        real = .init(repeating: 0, count: size / 2)
        imag = .init(repeating: 0, count: size / 2)
        magnitudes = .init(repeating: 0, count: size / 2)
        smoothedDB = .init(repeating: -120, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Computes the spectrum of the last `size` samples. Returns the levels in dBFS per bin.
    @discardableResult
    public func update(from ring: SPSCRingBuffer, smoothing: Float = 0.6) -> [Float] {
        input.withUnsafeMutableBufferPointer { _ = ring.readLatest(into: $0.baseAddress!, count: size) }
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { inp in
                    inp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }
        // Normalization: full-scale sine ≈ 0 dBFS (normalized Hann window, real FFT ×2).
        let scale = 1.0 / Float(size)
        for i in 0..<(size / 2) {
            let db = 20 * log10f(max(magnitudes[i] * scale, 1e-7))
            smoothedDB[i] = smoothedDB[i] * smoothing + db * (1 - smoothing)
        }
        return smoothedDB
    }

    /// Center frequency of bin `i`.
    public func frequency(bin i: Int, sampleRate: Double) -> Double { Double(i) * sampleRate / Double(size) }
}

/// Loudness measurement per ITU-R BS.1770-4 / EBU R128: K-weighting filter,
/// momentary (400 ms) and short-term (3 s) loudness, in LUFS.
/// Consumes the ring buffer samples since the last read;
/// if the UI fell too far behind, `gapDetected` reports it.
public final class LoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
    public let sampleRate: Double
    private var shelfL: Biquad, shelfR: Biquad, hpL: Biquad, hpR: Biquad
    private var lastIndex: Int?
    private var blockPower: [Double] = []   // power per 100 ms block
    private var accPower = 0.0
    private var accCount = 0
    private let blockSize: Int
    private var scratchL: [Float], scratchR: [Float]
    public private(set) var momentaryLUFS: Double = -.infinity
    public private(set) var shortTermLUFS: Double = -.infinity
    /// Integrated loudness (dual gate: -70 LUFS absolute / -10 LU relative).
    public private(set) var integratedLUFS: Double = -.infinity
    /// Loudness range (LRA, EBU Tech 3342: P95 - P10 of the gated short-term values).
    public private(set) var loudnessRange: Double = 0
    /// Approximate true peak (×4 oversampling), in dBTP.
    public private(set) var truePeakDB: Double = -.infinity
    private var momentaryHistory: [Double] = []   // power of 400 ms blocks, every 100 ms
    private var shortTermHistory: [Double] = []   // power of 3 s blocks, every 100 ms
    private var tpHistL = [Float](repeating: 0, count: 12), tpHistR = [Float](repeating: 0, count: 12)
    private var tpPos = 0
    private static let tpTaps: [[Float]] = {
        // Interpolation filter: windowed sinc (Hann), 4 phases × 12 coefficients.
        var phases: [[Float]] = []
        for p in 0..<4 {
            var c: [Float] = []
            for k in 0..<12 {
                let t = Double(k - 6) + Double(p) / 4
                let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
                let w = 0.5 * (1 + cos(.pi * t / 6.5))
                c.append(Float(sinc * w))
            }
            phases.append(c)
        }
        return phases
    }()
    public private(set) var gapDetected = false

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        blockSize = Int(sampleRate / 10)
        // BS.1770 coefficients recomputed for the sample rate.
        let (s, h) = LoudnessMeter.coefficients(sampleRate)
        shelfL = s; shelfR = s; hpL = h; hpR = h
        scratchL = .init(repeating: 0, count: 16384)
        scratchR = .init(repeating: 0, count: 16384)
    }

    private static func coefficients(_ fs: Double) -> (Biquad, Biquad) {
        // Stage 1: high shelf (+4 dB around 1.68 kHz).
        var f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        var K = tan(.pi * f0 / fs)
        let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        let shelf = Biquad(b0: (Vh + Vb * K / Q + K * K) / a0, b1: 2 * (K * K - Vh) / a0, b2: (Vh - Vb * K / Q + K * K) / a0,
                           a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
        // Stage 2: RLB high-pass (~38 Hz).
        f0 = 38.13547087602444; Q = 0.5003270373238773
        K = tan(.pi * f0 / fs)
        a0 = 1 + K / Q + K * K
        let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
        G = 0
        return (shelf, hp)
    }

    public func update(left: SPSCRingBuffer, right: SPSCRingBuffer) {
        let w = left.totalWritten
        guard let last = lastIndex else { lastIndex = w; return }
        var count = w - last
        if count <= 0 { return }
        if count > min(left.capacity, scratchL.count) { gapDetected = true; count = min(left.capacity, scratchL.count) }
        lastIndex = w
        scratchL.withUnsafeMutableBufferPointer { _ = left.readLatest(into: $0.baseAddress!, count: count) }
        scratchR.withUnsafeMutableBufferPointer { _ = right.readLatest(into: $0.baseAddress!, count: count) }
        var tp: Float = 0
        for i in 0..<count {
            // True peak: ×4 interpolation over a sliding 12-sample window.
            tpHistL[tpPos] = scratchL[i]; tpHistR[tpPos] = scratchR[i]
            tpPos = (tpPos + 1) % 12
            for ph in Self.tpTaps {
                var yl: Float = 0, yr: Float = 0
                for k in 0..<12 { let idx = (tpPos + k) % 12; yl += tpHistL[idx] * ph[k]; yr += tpHistR[idx] * ph[k] }
                tp = max(tp, abs(yl), abs(yr))
            }
            let l = hpL.process(shelfL.process(Double(scratchL[i])))
            let r = hpR.process(shelfR.process(Double(scratchR[i])))
            accPower += l * l + r * r
            accCount += 1
            if accCount == blockSize {
                blockPower.append(accPower / Double(blockSize))
                if blockPower.count > 30 { blockPower.removeFirst(blockPower.count - 30) }
                accPower = 0; accCount = 0
                if blockPower.count >= 4 { momentaryHistory.append(blockPower.suffix(4).reduce(0, +) / 4) }
                if blockPower.count >= 30 { shortTermHistory.append(blockPower.reduce(0, +) / 30) }
                if momentaryHistory.count > 36000 { momentaryHistory.removeFirst(momentaryHistory.count - 36000) }
                if shortTermHistory.count > 36000 { shortTermHistory.removeFirst(shortTermHistory.count - 36000) }
            }
        }
        func lufs(_ blocks: Int) -> Double {
            guard blockPower.count >= blocks else { return -.infinity }
            let p = blockPower.suffix(blocks).reduce(0, +) / Double(blocks)
            return p > 0 ? -0.691 + 10 * log10(p) : -.infinity
        }
        momentaryLUFS = lufs(4)
        shortTermLUFS = lufs(30)
        if tp > 0 { truePeakDB = max(truePeakDB, 20 * log10(Double(tp))) }
        integratedLUFS = Self.gatedLoudness(momentaryHistory, relativeGate: -10)
        loudnessRange = Self.range(shortTermHistory)
    }

    static func toLUFS(_ p: Double) -> Double { p > 0 ? -0.691 + 10 * log10(p) : -.infinity }

    static func gatedLoudness(_ blocks: [Double], relativeGate: Double) -> Double {
        let abs = blocks.filter { toLUFS($0) > -70 }
        guard !abs.isEmpty else { return -.infinity }
        let rel = toLUFS(abs.reduce(0, +) / Double(abs.count)) + relativeGate
        let gated = abs.filter { toLUFS($0) > rel }
        guard !gated.isEmpty else { return -.infinity }
        return toLUFS(gated.reduce(0, +) / Double(gated.count))
    }

    static func range(_ blocks: [Double]) -> Double {
        let abs = blocks.filter { toLUFS($0) > -70 }
        guard abs.count >= 2 else { return 0 }
        let rel = toLUFS(abs.reduce(0, +) / Double(abs.count)) - 20
        let vals = abs.map(toLUFS).filter { $0 > rel }.sorted()
        guard vals.count >= 2 else { return 0 }
        func pct(_ p: Double) -> Double { vals[min(vals.count - 1, Int((Double(vals.count - 1) * p).rounded()))] }
        return pct(0.95) - pct(0.10)
    }

    public func reset() {
        blockPower.removeAll(); accPower = 0; accCount = 0; lastIndex = nil; gapDetected = false
        momentaryLUFS = -.infinity; shortTermLUFS = -.infinity; integratedLUFS = -.infinity
        loudnessRange = 0; truePeakDB = -.infinity
        momentaryHistory.removeAll(); shortTermHistory.removeAll()
    }
}

/// Stereo correlation (-1 … +1) over the last N samples.
public func stereoCorrelation(left: SPSCRingBuffer, right: SPSCRingBuffer, count: Int = 4096) -> Float {
    var l = [Float](repeating: 0, count: count), r = l
    l.withUnsafeMutableBufferPointer { _ = left.readLatest(into: $0.baseAddress!, count: count) }
    r.withUnsafeMutableBufferPointer { _ = right.readLatest(into: $0.baseAddress!, count: count) }
    var lr: Float = 0, ll: Float = 0, rr: Float = 0
    vDSP_dotpr(l, 1, r, 1, &lr, vDSP_Length(count))
    vDSP_dotpr(l, 1, l, 1, &ll, vDSP_Length(count))
    vDSP_dotpr(r, 1, r, 1, &rr, vDSP_Length(count))
    let d = sqrtf(ll * rr)
    return d > 1e-9 ? lr / d : 0
}
