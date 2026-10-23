import Foundation
import AVFoundation
import AudioToolbox

/// Native VoxFlowAir nodes. They are distinct from third-party plugins: they are
/// internal Audio Units v3, registered only in the VoxFlowAir process.
public enum UtilityMode: UInt32, Sendable {
    case meter, gain, analyzer, monitorTap

    public var subType: FourCharCode {
        switch self {
        case .meter: return fcc("vfmt")
        case .gain: return fcc("vfgn")
        case .analyzer: return fcc("vfan")
        case .monitorTap: return fcc("vfmn")
        }
    }

    init(subType: FourCharCode) {
        switch subType {
        case fcc("vfgn"): self = .gain
        case fcc("vfan"): self = .analyzer
        case fcc("vfmn"): self = .monitorTap
        default: self = .meter
        }
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subType,
                                  componentManufacturer: fcc("VxFl"), componentFlags: 0, componentFlagsMask: 0)
    }
}

public func fcc(_ s: String) -> FourCharCode {
    var r: FourCharCode = 0
    for b in s.utf8.prefix(4) { r = (r << 8) | FourCharCode(b) }
    return r
}

public func fccString(_ c: FourCharCode) -> String {
    let bytes = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    return String(bytes: bytes, encoding: .macOSRoman) ?? "\(c)"
}

/// Buffer where the "Monitoring output" node puts the signal to hear on the headphones.
public final class MonitorSink: @unchecked Sendable {
    public let maxFrames: Int
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    /// Written and read only by the audio thread, within the same cycle.
    public var written = false

    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
        left = .allocate(capacity: maxFrames); left.initialize(repeating: 0, count: maxFrames)
        right = .allocate(capacity: maxFrames); right.initialize(repeating: 0, count: maxFrames)
    }
    deinit { left.deallocate(); right.deallocate() }
}

/// Levels measured by a node (peak and RMS, held until the UI reads them).
public final class LevelMeter: @unchecked Sendable {
    public let peak = [RTFloat(), RTFloat()]
    public let rms = [RTFloat(), RTFloat()]
    public let clipCount = RTCounter()
    public init() {}

    @inline(__always) func measure(_ p: UnsafePointer<Float>, frames: Int, channel: Int) {
        var pk: Float = 0, sum: Float = 0
        for i in 0..<frames { let v = p[i]; let a = abs(v); if a > pk { pk = a }; sum += v * v }
        let ch = min(channel, 1)
        peak[ch].storeMax(pk)
        rms[ch].storeMax(frames > 0 ? sqrtf(sum / Float(frames)) : 0)
        if pk >= 0.999 { clipCount.increment() }
    }

    public struct Reading: Sendable, Equatable {
        public var peakL: Float, peakR: Float, rmsL: Float, rmsR: Float
        public static let silent = Reading(peakL: 0, peakR: 0, rmsL: 0, rmsR: 0)
        public var maxPeak: Float { max(peakL, peakR) }
    }

    /// UI-side read (resets the maxima).
    public func read() -> Reading {
        Reading(peakL: peak[0].take(), peakR: peak[1].take(), rmsL: rms[0].take(), rmsR: rms[1].take())
    }
}

public final class UtilityKernel: @unchecked Sendable {
    public let mode: UtilityMode
    public let meter = LevelMeter()
    public let gainDB = RTFloat(0)
    public let bypass = RTBool(false)
    public let tap: StereoAnalysisTap?
    /// Set while the engine is locked (no concurrent render).
    public var monitorSink: MonitorSink?

    private var currentGain: Float = 1
    fileprivate var maxFrames = 0
    fileprivate var inChannels = 2
    fileprivate var outChannels = 2
    fileprivate var storage: [UnsafeMutablePointer<Float>] = []
    fileprivate var inputABL: UnsafeMutableAudioBufferListPointer

    init(mode: UtilityMode) {
        self.mode = mode
        // Each node keeps its latest samples (live mini visualization in the editor).
        tap = StereoAnalysisTap(capacity: mode == .analyzer ? 16384 : 4096)
        inputABL = AudioBufferList.allocate(maximumBuffers: 2)
    }

    deinit {
        free()
        Foundation.free(inputABL.unsafeMutablePointer)
    }

    func allocate(maxFrames: Int, inChannels: Int, outChannels: Int) {
        free()
        self.maxFrames = maxFrames
        self.inChannels = max(1, min(2, inChannels))
        self.outChannels = max(1, min(2, outChannels))
        storage = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            return p
        }
        currentGain = dbToLinear(gainDB.load())
    }

    func free() {
        for p in storage { p.deallocate() }
        storage = []
    }

    @inline(__always) func prepareInput(frames: UInt32) {
        inputABL.count = inChannels
        for ch in 0..<inChannels {
            inputABL[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(storage[ch]))
        }
    }

    @inline(__always) func process(output: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        let n = out.count
        // Point empty outputs at the input (in-place processing).
        for ch in 0..<n {
            let src = inputABL[min(ch, inChannels - 1)].mData
            if out[ch].mData == nil { out[ch].mData = src }
            out[ch].mDataByteSize = UInt32(frames * 4)
            if out[ch].mData != src, let s = src, let d = out[ch].mData {
                d.copyMemory(from: s, byteCount: frames * 4)
            }
        }
        let bypassed = bypass.value

        if mode == .gain && !bypassed {
            let target = dbToLinear(gainDB.load())
            let start = currentGain
            let step = (target - start) / Float(max(frames, 1))
            for ch in 0..<n {
                guard let d = out[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var g = start
                for i in 0..<frames { g += step; d[i] *= g }
            }
            currentGain = target
        }

        for ch in 0..<min(n, 2) {
            if let d = out[ch].mData?.assumingMemoryBound(to: Float.self) { meter.measure(d, frames: frames, channel: ch) }
        }

        if let tap, n > 0, let l = out[0].mData?.assumingMemoryBound(to: Float.self) {
            let r = n > 1 ? out[1].mData!.assumingMemoryBound(to: Float.self) : l
            tap.write(l: l, r: r, count: frames)
        }

        if mode == .monitorTap {
            if let sink = monitorSink, frames <= sink.maxFrames, n > 0,
               let l = out[0].mData?.assumingMemoryBound(to: Float.self) {
                let r = n > 1 ? out[1].mData!.assumingMemoryBound(to: Float.self) : l
                sink.left.update(from: l, count: frames)
                sink.right.update(from: r, count: frames)
                sink.written = true
            }
            // This node does not contribute to the virtual output mix.
            for ch in 0..<n { out[ch].mData?.initializeMemory(as: Float.self, repeating: 0, count: frames) }
        }
    }
}

public final class VFUtilityAudioUnit: AUAudioUnit {
    public let kernel: UtilityKernel
    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    private static let registration: Void = {
        for mode in [UtilityMode.meter, .gain, .analyzer, .monitorTap] {
            AUAudioUnit.registerSubclass(VFUtilityAudioUnit.self, as: mode.componentDescription,
                                         name: "VoxFlowAir: \(mode)", version: 1)
        }
    }()

    /// Registers the native nodes with the system (once, in this process).
    public static func registerOnce() { _ = registration }

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        kernel = UtilityKernel(mode: UtilityMode(subType: componentDescription.componentSubType))
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        inBus = try AUAudioUnitBus(format: fmt)
        outBus = try AUAudioUnitBus(format: fmt)
        inBus.maximumChannelCount = 2
        outBus.maximumChannelCount = 2
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        maximumFramesToRender = 4096

        if kernel.mode == .gain {
            let p = AUParameterTree.createParameter(withIdentifier: "gain", name: "Gain", address: 0,
                                                    min: -60, max: 24, unit: .decibels, unitName: nil,
                                                    flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil,
                                                    dependentParameters: nil)
            p.value = 0
            let tree = AUParameterTree.createTree(withChildren: [p])
            let k = kernel
            tree.implementorValueObserver = { _, value in k.gainDB.store(value) }
            tree.implementorValueProvider = { _ in k.gainDB.load() }
            parameterTree = tree
        }
    }

    public override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    public override var canProcessInPlace: Bool { true }
    public override var channelCapabilities: [NSNumber]? { [1, 1, 2, 2] }

    public override var shouldBypassEffect: Bool {
        get { kernel.bypass.value }
        set { kernel.bypass.value = newValue }
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.allocate(maxFrames: Int(maximumFramesToRender),
                        inChannels: Int(inBus.format.channelCount),
                        outChannels: Int(outBus.format.channelCount))
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        kernel.free()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let k = kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            guard Int(frameCount) <= k.maxFrames, !k.storage.isEmpty else { return kAudioUnitErr_TooManyFramesToProcess }
            k.prepareInput(frames: frameCount)
            var flags = AudioUnitRenderActionFlags()
            let st = pull(&flags, timestamp, frameCount, 0, k.inputABL.unsafeMutablePointer)
            if st != noErr { return st }
            k.process(output: outputData, frames: Int(frameCount))
            return noErr
        }
    }

    // Persistent state (gain).
    public override var fullState: [String: Any]? {
        get { ["gain": kernel.gainDB.load()] }
        set {
            if let g = newValue?["gain"] as? Float { kernel.gainDB.store(g); parameterTree?.parameter(withAddress: 0)?.value = g }
            else if let g = newValue?["gain"] as? Double { kernel.gainDB.store(Float(g)); parameterTree?.parameter(withAddress: 0)?.value = Float(g) }
        }
    }
}
