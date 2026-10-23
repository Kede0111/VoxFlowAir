import Foundation
import CoreAudio

/// Call return: reads what a call app plays into BlackHole and mixes it into the headphones.
///
/// Why: FaceTime's echo canceller erases everything that plays on its output, including VoxFlowAir's
/// monitoring. So FaceTime plays into BlackHole (its output then only contains the other party),
/// and VoxFlowAir lets you hear the call and your processed voice in the headphones, like a radio
/// console. Nothing from this return goes to the virtual output: no echo on the other end.
public final class CallReturnReader {
    public let ring = DriftRing()
    public let gainDB = RTFloat(0)
    /// Peak of the return since the last read (UI).
    public let peak = RTFloat(0)
    private let maxFrames = 4096
    private let inL: UnsafeMutablePointer<Float>, inR: UnsafeMutablePointer<Float>
    private let mixBuf: UnsafeMutablePointer<Float>
    private var procID: AudioDeviceIOProcID?
    private var device: AudioObjectID = 0
    public private(set) var deviceName: String?

    public init() {
        inL = .allocate(capacity: maxFrames); inL.initialize(repeating: 0, count: maxFrames)
        inR = .allocate(capacity: maxFrames); inR.initialize(repeating: 0, count: maxFrames)
        mixBuf = .allocate(capacity: 2 * maxFrames); mixBuf.initialize(repeating: 0, count: 2 * maxFrames)
    }

    deinit { stop(); inL.deallocate(); inR.deallocate(); mixBuf.deallocate() }

    public var isRunning: Bool { procID != nil }

    public func start(deviceID: AudioObjectID, name: String, sampleRate: Double, bufferFrames: Int) throws {
        stop()
        let rate: Float64 = CA.get(deviceID, kAudioDevicePropertyNominalSampleRate, default: 0)
        if abs(rate - sampleRate) > 0.5 { try? CA.set(deviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(sampleRate)) }
        try? CA.set(deviceID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(bufferFrames))
        let streams = try HALIOUnit.slots(device: deviceID, scope: kAudioObjectPropertyScopeInput)
        guard let first = streams.first, first.isFloat else { throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "Unsupported call return format") }
        let devFrames = Int(CA.get(deviceID, kAudioDevicePropertyBufferFrameSize, default: UInt32(bufferFrames)))
        ring.prepare(producerFrames: devFrames, consumerFrames: bufferFrames)

        var id: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&id, deviceID, nil) { [unowned(unsafe) self] _, inData, _, _, _ in
            self.capture(inData)
        }, "Call return IOProc")
        procID = id
        device = deviceID
        do { try check(AudioDeviceStart(deviceID, id), "Starting call return") }
        catch { stop(); throw error }
        deviceName = name
        vlog(.info, "Call return: \(name) mixed into headphones (target buffer \(ring.targetFrames) frames)")
    }

    public func stop() {
        if let id = procID { AudioDeviceStop(device, id); AudioDeviceDestroyIOProcID(device, id) }
        procID = nil
        deviceName = nil
    }

    /// BlackHole IOProc thread.
    @inline(__always)
    private func capture(_ inData: UnsafePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard bufs.count > 0, let raw = bufs[0].mData else { return }
        let stride = max(Int(bufs[0].mNumberChannels), 1)
        let n = min(Int(bufs[0].mDataByteSize) / (4 * stride), maxFrames)
        let src = raw.assumingMemoryBound(to: Float.self)
        for i in 0..<n {
            inL[i] = src[i * stride]
            inR[i] = stride > 1 ? src[i * stride + 1] : src[i * stride]
        }
        ring.push(inL, inR, count: n)
    }

    /// Engine thread: adds the call return to the headphone signal.
    @inline(__always)
    public func mix(intoL l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>, frames n: Int) {
        guard n <= maxFrames, ring.pull(into: mixBuf, stride: 2, frames: n) else { return }
        let g = dbToLinear(gainDB.load())
        var pk: Float = 0
        for i in 0..<n {
            let a = mixBuf[2 * i] * g, b = mixBuf[2 * i + 1] * g
            pk = max(pk, abs(a))
            l[i] = min(max(l[i] + a, -1), 1)
            r[i] = min(max(r[i] + b, -1), 1)
        }
        peak.storeMax(pk)
    }
}
