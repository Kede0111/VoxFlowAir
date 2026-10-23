import Foundation
import AudioToolbox
import CoreAudio

/// Diagnostics: writes a test tone straight to an output device (no aggregate),
/// to isolate a routing problem. Never used in normal operation.
public final class DirectToneWriter {
    private var unit: AudioUnit?
    private var phase: Double = 0
    private var sampleRate: Double = 48000
    public let amplitude: Float

    public init(amplitude: Float = 0.03) { self.amplitude = amplitude }

    public func start(deviceID: AudioObjectID, sampleRate: Double) throws {
        self.sampleRate = sampleRate
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "Tone: create")
        guard let unit = u else { return }
        self.unit = unit
        var dev = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4), "Tone: device")
        var fmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Tone: format")
        var cb = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, io in
            let w = Unmanaged<DirectToneWriter>.fromOpaque(ref).takeUnretainedValue()
            guard let io else { return noErr }
            let b = UnsafeMutableAudioBufferListPointer(io)
            let step = 2 * Double.pi * 440 / w.sampleRate
            for i in 0..<Int(frames) {
                let v = Float(sin(w.phase)) * w.amplitude
                w.phase += step
                for c in 0..<b.count { b[c].mData?.assumingMemoryBound(to: Float.self)[i] = v }
            }
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Tone: callback")
        try check(AudioUnitInitialize(unit), "Tone: init")
        try check(AudioOutputUnitStart(unit), "Tone: start")
    }

    public func stop() {
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil
    }
}
