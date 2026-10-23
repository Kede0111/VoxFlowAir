import Foundation
import AudioToolbox
import CoreAudio

/// Hardware I/O: a Core Audio IOProc registered directly on the private aggregate
/// device. Each cycle provides the buffers of *all* streams (microphone, virtual
/// output, headphones); channels are read and written at their exact position,
/// with no intermediate conversion layer.
///
/// History: a first version used an AUHAL unit; on macOS 27 its writes to the
/// BlackHole stream of an aggregate stayed silent (verified by read-back). The
/// direct IOProc removes that ambiguity.
public final class HALIOUnit {
    public struct Configuration: Equatable, Sendable {
        public var deviceID: AudioObjectID
        public var sampleRate: Double
        public var layout: AggregateChannelLayout
        /// Microphone channels to use (0-based indices in the input device). 1 or 2 values.
        public var inputChannels: [Int]
        public var maxFrames: Int
    }

    /// Position of a logical channel in the IOProc buffers.
    struct Slot { var buffer: Int = -1; var channel: Int = 0; var stride: Int = 1; var valid: Bool { buffer >= 0 } }

    private let processor: RealtimeProcessor
    private var procID: AudioDeviceIOProcID?
    private var device: AudioObjectID = 0
    private let maxFrames: Int
    private let micL: UnsafeMutablePointer<Float>, micR: UnsafeMutablePointer<Float>
    private let vL: UnsafeMutablePointer<Float>, vR: UnsafeMutablePointer<Float>
    private let mL: UnsafeMutablePointer<Float>, mR: UnsafeMutablePointer<Float>
    private var sMicL = Slot(), sMicR = Slot(), sVL = Slot(), sVR = Slot(), sML = Slot(), sMR = Slot()
    private var overloadListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice: AudioObjectID = 0
    public private(set) var configuration: Configuration?
    public private(set) var isRunning = false
    /// Direct destination of the virtual output (outside the aggregate).
    public var virtualWriter: VirtualOutputWriter?
    /// Call return mixed into the headphones (set while the engine is stopped).
    public var callReturn: CallReturnReader?

    public init(processor: RealtimeProcessor) {
        self.processor = processor
        maxFrames = processor.maxFrames
        func buf() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: processor.maxFrames)
            p.initialize(repeating: 0, count: processor.maxFrames)
            return p
        }
        micL = buf(); micR = buf(); vL = buf(); vR = buf(); mL = buf(); mR = buf()
    }

    deinit {
        stop()
        for p in [micL, micR, vL, vR, mL, mR] { p.deallocate() }
    }

    /// Computes the position (stream, channel, interleaving) of an absolute aggregate channel.
    static func slots(device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [(channels: Int, isFloat: Bool)] {
        let streams = CA.getArray(device, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self)
        return streams.map { s in
            let f: AudioStreamBasicDescription = CA.get(s, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
            let isFloat = f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
            return (Int(f.mChannelsPerFrame), isFloat)
        }
    }

    static func locate(_ absolute: Int, in streams: [(channels: Int, isFloat: Bool)]) -> Slot {
        guard absolute >= 0 else { return Slot() }
        var base = 0
        for (i, s) in streams.enumerated() {
            if absolute < base + s.channels { return Slot(buffer: i, channel: absolute - base, stride: s.channels) }
            base += s.channels
        }
        return Slot()
    }

    public func start(_ cfg: Configuration) throws {
        stop()
        let dev = cfg.deviceID
        let ins = try Self.slots(device: dev, scope: kAudioObjectPropertyScopeInput)
        let outs = try Self.slots(device: dev, scope: kAudioObjectPropertyScopeOutput)
        if let bad = (ins + outs).first(where: { !$0.isFloat }) {
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError, String(localized: "Unsupported stream format (\(bad.channels) channels, not Float32)"))
        }
        let l = cfg.layout
        let sel = cfg.inputChannels.isEmpty ? [0, 1] : cfg.inputChannels
        let c0 = l.inputOffset + min(sel[0], max(l.inputCount - 1, 0))
        let c1 = sel.count > 1 ? l.inputOffset + min(sel[1], max(l.inputCount - 1, 0)) : c0
        sMicL = Self.locate(c0, in: ins); sMicR = Self.locate(c1, in: ins)
        let hasV = l.virtualOffset >= 0 && l.virtualCount > 0
        let hasM = l.monitorOffset >= 0 && l.monitorCount > 0
        sVL = hasV ? Self.locate(l.virtualOffset, in: outs) : Slot()
        sVR = hasV ? Self.locate(l.virtualOffset + min(1, l.virtualCount - 1), in: outs) : Slot()
        sML = hasM ? Self.locate(l.monitorOffset, in: outs) : Slot()
        sMR = hasM ? Self.locate(l.monitorOffset + min(1, l.monitorCount - 1), in: outs) : Slot()
        guard sMicL.valid else { throw CoreAudioError(kAudioHardwareBadStreamError, String(localized: "Microphone channel not found in the aggregate device")) }

        var id: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&id, dev, nil) { [unowned(unsafe) self] _, inData, _, outData, _ in
            self.cycle(inData, outData)
        }, String(localized: "Creating the IOProc"))
        procID = id
        device = dev
        do {
            try check(AudioDeviceStart(dev, id), String(localized: "Starting the IOProc"))
        } catch {
            stop()
            throw error
        }
        isRunning = true
        configuration = cfg
        installOverloadListener(dev)
        vlog(.info, "I/O started (IOProc): \(cfg.sampleRate) Hz; input streams \(ins.map(\.channels)), output \(outs.map(\.channels)); mic \(sMicL.buffer):\(sMicL.channel)/\(sMicR.buffer):\(sMicR.channel), virtual \(sVL.buffer):\(sVL.channel), headphones \(sML.buffer):\(sML.channel)")
    }

    public func stop() {
        removeOverloadListener()
        if let id = procID {
            AudioDeviceStop(device, id)
            AudioDeviceDestroyIOProcID(device, id)
        }
        procID = nil
        isRunning = false
    }

    /// Real-time thread: no allocation, no locks.
    @inline(__always)
    private func cycle(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        let inBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outBufs = UnsafeMutableAudioBufferListPointer(outData)
        // Frame count: from the microphone stream (or the first output stream).
        var frames = 0
        if sMicL.valid, sMicL.buffer < inBufs.count {
            frames = Int(inBufs[sMicL.buffer].mDataByteSize) / (4 * max(sMicL.stride, 1))
        } else if outBufs.count > 0 {
            let ch = max(Int(outBufs[0].mNumberChannels), 1)
            frames = Int(outBufs[0].mDataByteSize) / (4 * ch)
        }
        for b in outBufs { b.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(b.mDataByteSize)) }
        guard frames > 0, frames <= maxFrames else { return }

        let inputOK = read(sMicL, inBufs, into: micL, frames) && read(sMicR, inBufs, into: micR, frames)
        if !inputOK { processor.meters.inputErrors.increment() }
        processor.process(frames: frames,
                          inL: inputOK ? UnsafePointer(micL) : nil, inR: inputOK ? UnsafePointer(micR) : nil,
                          virtualL: (sVL.valid || virtualWriter != nil) ? vL : nil, virtualR: (sVR.valid || virtualWriter != nil) ? vR : nil,
                          monitorL: sML.valid ? mL : nil, monitorR: sMR.valid ? mR : nil)
        write(vL, to: sVL, outBufs, frames); write(vR, to: sVR, outBufs, frames)
        virtualWriter?.push(vL, vR, count: frames)
        if sML.valid, let cr = callReturn { cr.mix(intoL: mL, r: mR, frames: frames) }
        write(mL, to: sML, outBufs, frames); write(mR, to: sMR, outBufs, frames)
    }

    @inline(__always)
    private func read(_ s: Slot, _ bufs: UnsafeMutableAudioBufferListPointer, into dst: UnsafeMutablePointer<Float>, _ n: Int) -> Bool {
        guard s.valid, s.buffer < bufs.count, let raw = bufs[s.buffer].mData,
              Int(bufs[s.buffer].mDataByteSize) >= n * s.stride * 4 else { return false }
        let src = raw.assumingMemoryBound(to: Float.self)
        var k = s.channel
        for i in 0..<n { dst[i] = src[k]; k += s.stride }
        return true
    }

    @inline(__always)
    private func write(_ src: UnsafeMutablePointer<Float>, to s: Slot, _ bufs: UnsafeMutableAudioBufferListPointer, _ n: Int) {
        guard s.valid, s.buffer < bufs.count, let raw = bufs[s.buffer].mData,
              Int(bufs[s.buffer].mDataByteSize) >= n * s.stride * 4 else { return }
        let dst = raw.assumingMemoryBound(to: Float.self)
        var k = s.channel
        for i in 0..<n { dst[k] = src[i]; k += s.stride }
    }

    private func installOverloadListener(_ dev: AudioObjectID) {
        let meters = processor.meters
        let block: AudioObjectPropertyListenerBlock = { _, _ in meters.deviceOverloads.increment() }
        var a = CA.address(kAudioDeviceProcessorOverload)
        if AudioObjectAddPropertyListenerBlock(dev, &a, nil, block) == noErr {
            overloadListener = block
            listenedDevice = dev
        }
    }

    private func removeOverloadListener() {
        guard let b = overloadListener else { return }
        var a = CA.address(kAudioDeviceProcessorOverload)
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &a, nil, b)
        overloadListener = nil
    }
}
