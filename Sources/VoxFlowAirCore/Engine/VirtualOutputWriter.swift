import Foundation
import CoreAudio

/// Writes the virtual output directly to the virtual device (BlackHole)
/// with its own IOProc, fed by a lock-free ring buffer.
///
/// Why: writing to BlackHole inside an aggregate device does not reach other
/// applications on macOS 27 (verified by read-back); writing directly does.
/// The two clocks (microphone and BlackHole) drift slightly: `DriftRing`
/// compensates.
public final class VirtualOutputWriter {
    public let ring = DriftRing()
    public var targetFrames: Int { ring.targetFrames }
    public var targetStat: RTFloat { ring.targetStat }
    /// Observed cycle sizes: producer (engine) and consumer (BlackHole).
    public var producerBlock: RTFloat { ring.producerBlock }
    public var consumerBlock: RTFloat { ring.consumerBlock }
    public var underruns: RTCounter { ring.underruns }
    public var overruns: RTCounter { ring.overruns }
    public var ratioPPM: RTFloat { ring.ratioPPM }
    public var fillFrames: RTFloat { ring.fillFrames }

    private var procID: AudioDeviceIOProcID?
    private var device: AudioObjectID = 0
    private var outBuffer = -1

    public init() {}

    deinit { stop() }

    // MARK: Producer (main audio thread)

    @inline(__always)
    public func push(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, count n: Int) {
        ring.push(l, r, count: n)
    }

    // MARK: Consumer

    public func start(deviceID: AudioObjectID, sampleRate: Double, bufferFrames: Int) throws {
        stop()
        // Same sample rate and buffer size as the engine.
        let rate: Float64 = CA.get(deviceID, kAudioDevicePropertyNominalSampleRate, default: 0)
        if abs(rate - sampleRate) > 0.5 { try? CA.set(deviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(sampleRate)) }
        try? CA.set(deviceID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(bufferFrames))
        let streams = try HALIOUnit.slots(device: deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard let first = streams.first, first.isFloat else { throw CoreAudioError(kAudioDeviceUnsupportedFormatError, String(localized: "Unsupported virtual output format")) }
        outBuffer = 0
        let bhFrames = Int(CA.get(deviceID, kAudioDevicePropertyBufferFrameSize, default: UInt32(bufferFrames)))
        ring.prepare(producerFrames: bufferFrames, consumerFrames: bhFrames)

        var id: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&id, deviceID, nil) { [unowned(unsafe) self] _, _, _, outData, _ in
            self.render(outData)
        }, String(localized: "Virtual output IOProc"))
        procID = id
        device = deviceID
        do { try check(AudioDeviceStart(deviceID, id), String(localized: "Starting virtual output")) }
        catch { stop(); throw error }
        vlog(.info, "Direct virtual output started: \(Int(sampleRate)) Hz, engine buffer \(bufferFrames), BlackHole buffer \(bhFrames), target buffer \(ring.targetFrames) frames (\(String(format: "%.1f", Double(ring.targetFrames) / sampleRate * 1000)) ms)")
    }

    public func stop() {
        if let id = procID { AudioDeviceStop(device, id); AudioDeviceDestroyIOProcID(device, id) }
        procID = nil
    }

    @inline(__always)
    private func render(_ outData: UnsafeMutablePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(outData)
        guard outBuffer >= 0, outBuffer < bufs.count, let raw = bufs[outBuffer].mData else { return }
        let stride = max(Int(bufs[outBuffer].mNumberChannels), 1)
        let n = Int(bufs[outBuffer].mDataByteSize) / (4 * stride)
        ring.pull(into: raw.assumingMemoryBound(to: Float.self), stride: stride, frames: n)
    }
}
