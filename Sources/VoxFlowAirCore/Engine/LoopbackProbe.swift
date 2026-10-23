import Foundation
import AudioToolbox
import CoreAudio

/// Independent reader of the virtual device's input, exactly as OBS or FaceTime
/// would read it: a second input-only AUHAL unit, opened directly on BlackHole.
/// Used to prove that the processed signal actually arrives there.
public final class LoopbackProbe {
    private var unit: AudioUnit?
    private let meters: EngineMeters
    private var abl: UnsafeMutableAudioBufferListPointer
    private let l: UnsafeMutablePointer<Float>
    private let r: UnsafeMutablePointer<Float>
    private let maxFrames = 4096
    public let callbacks = RTCounter()
    public let errors = RTCounter()
    public let lastError = RTCounter()

    public init(meters: EngineMeters) {
        self.meters = meters
        abl = AudioBufferList.allocate(maximumBuffers: 2)
        l = .allocate(capacity: maxFrames); l.initialize(repeating: 0, count: maxFrames)
        r = .allocate(capacity: maxFrames); r.initialize(repeating: 0, count: maxFrames)
    }

    deinit { stop(); free(abl.unsafeMutablePointer); l.deallocate(); r.deallocate() }

    public func start(deviceID: AudioObjectID, sampleRate: Double) throws {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CoreAudioError(-1, "AUHAL not found") }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "Probe: creation")
        guard let unit = u else { return }
        self.unit = unit
        do {
            var one: UInt32 = 1, zero: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "Probe: input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "Probe: output")
            var dev = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size)), "Probe: device")
            var maxF = UInt32(maxFrames)
            _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, 4)
            var fmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                  mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Probe: format")
            var cb = AURenderCallbackStruct(inputProc: probeInputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Probe: callback")
            try check(AudioUnitInitialize(unit), "Probe: initialization")
            try check(AudioOutputUnitStart(unit), "Probe: start")
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil
    }

    fileprivate func input(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        callbacks.increment()
        guard let unit, Int(frames) <= maxFrames else { return noErr }
        abl.count = 2
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(l))
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(r))
        let st = AudioUnitRender(unit, flags, ts, 1, frames, abl.unsafeMutablePointer)
        guard st == noErr else { errors.increment(); lastError.reset(); lastError.increment(by: Int(st)); return st }
        let n = Int(frames)
        meters.loopback.measure(l, frames: n, channel: 0)
        meters.loopback.measure(r, frames: n, channel: 1)
        meters.loopbackTap.write(l: l, r: r, count: n)
        var pk: Float = 0
        for i in 0..<n { pk = max(pk, abs(l[i])) }
        meters.verifyLoopbackPeak.storeMax(pk)
        return noErr
    }
}

private func probeInputCallback(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                                _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<LoopbackProbe>.fromOpaque(refCon).takeUnretainedValue().input(flags, ts, frames)
}
