import Foundation
import AVFoundation
import Darwin

/// Controls changed from the UI, read lock-free by the audio thread.
public final class RealtimeControl: @unchecked Sendable {
    public let inputGainDB = RTFloat(0)
    public let virtualGainDB = RTFloat(0)
    public let monitorGainDB = RTFloat(-6)
    /// Bypass Processing: the output receives the unprocessed input signal (after input gain).
    public let bypass = RTBool(false)
    /// Mute Output: mutes the virtual output only.
    public let muteVirtual = RTBool(false)
    /// Monitoring: listening on headphones.
    public let monitorEnabled = RTBool(false)
    /// Level correction applied to the unprocessed signal during bypass
    /// (loudness-matched comparison). 0 dB = raw bypass.
    public let bypassMatchDB = RTFloat(0)
    public init() {}
}

/// Measurements produced by the audio thread.
public final class EngineMeters: @unchecked Sendable {
    public let input = LevelMeter()
    public let processed = LevelMeter()
    public let virtualOut = LevelMeter()
    public let monitorOut = LevelMeter()
    public let inputTap = StereoAnalysisTap()
    public let outputTap = StereoAnalysisTap()
    /// Exactly what is written to the virtual output (after gain and mute).
    public let virtualTap = StereoAnalysisTap()
    /// Overloads reported by Core Audio (kAudioDeviceProcessorOverload).
    public let deviceOverloads = RTCounter()
    /// Cycles where processing took more than 90% of the available time.
    public let nearOverruns = RTCounter()
    /// Graph render errors (cycle replaced with silence).
    public let renderErrors = RTCounter()
    /// Input read errors.
    public let inputErrors = RTCounter()
    /// NaN/Inf samples neutralized (misbehaving plugin).
    public let invalidSamples = RTCounter()
    /// Audio cycles rendered during a reconfiguration (transition silence).
    public let transitionCycles = RTCounter()
    public let cycles = RTCounter()
    /// Maximum cycle load (compute time / buffer duration).
    public let maxLoad = RTFloat(0)
    /// Read-back of the virtual output (BlackHole input): proof that the signal gets there.
    public let loopback = LevelMeter()
    public let loopbackTap = StereoAnalysisTap()
    /// Peaks reserved for automatic verification (independent of the UI meters).
    public let verifyVirtualPeak = RTFloat(0)
    public let verifyLoopbackPeak = RTFloat(0)
    public let lastFrames = RTCounter()
    public init() {}
}

/// Real-time core: receives the input, runs the AVAudioEngine graph in manual
/// rendering mode, applies bypass / mute / monitoring and writes the outputs.
/// No allocation, no locks, no disk I/O in `process`.
public final class RealtimeProcessor: @unchecked Sendable {
    public let maxFrames: Int
    public let control: RealtimeControl
    public let meters: EngineMeters
    public let monitorSink: MonitorSink
    public private(set) var sampleRate: Double = 48000

    private let graphReady = RTBool(false)
    private let inRender = RTBool(false)
    private var renderBlock: AVAudioEngineManualRenderingBlock?

    private let dryL: UnsafeMutablePointer<Float>
    private let dryR: UnsafeMutablePointer<Float>
    private let wetL: UnsafeMutablePointer<Float>
    private let wetR: UnsafeMutablePointer<Float>
    private let mainL: UnsafeMutablePointer<Float>
    private let mainR: UnsafeMutablePointer<Float>
    private let monL: UnsafeMutablePointer<Float>
    private let monR: UnsafeMutablePointer<Float>
    private let graphInputABL: UnsafeMutableAudioBufferListPointer
    private let graphOutputABL: UnsafeMutableAudioBufferListPointer
    private var graphInputFrames: UInt32 = 0

    // Ramp state (audio thread only).
    private var inputGain: Float = 1
    private var wetMix: Float = 1
    private var virtualGain: Float = 1
    private var monitorGain: Float = 0
    private var transitionGain: Float = 0
    private var dryMatch: Float = 1
    private var hostTicksToSeconds: Double = 0

    public init(maxFrames: Int = 4096, control: RealtimeControl = RealtimeControl(), meters: EngineMeters = EngineMeters()) {
        self.maxFrames = maxFrames
        self.control = control
        self.meters = meters
        monitorSink = MonitorSink(maxFrames: maxFrames)
        func buf() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            return p
        }
        dryL = buf(); dryR = buf(); wetL = buf(); wetR = buf(); mainL = buf(); mainR = buf(); monL = buf(); monR = buf()
        graphInputABL = AudioBufferList.allocate(maximumBuffers: 2)
        graphOutputABL = AudioBufferList.allocate(maximumBuffers: 2)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        hostTicksToSeconds = Double(tb.numer) / Double(tb.denom) / 1e9
    }

    deinit {
        for p in [dryL, dryR, wetL, wetR, mainL, mainR, monL, monR] { p.deallocate() }
        free(graphInputABL.unsafeMutablePointer)
        free(graphOutputABL.unsafeMutablePointer)
    }

    // MARK: AVAudioEngine binding

    /// Block passed to `AVAudioInputNode.setManualRenderingInputPCMFormat`: returns
    /// the current cycle's input signal directly.
    public func makeInputBlock() -> AVAudioIONodeInputBlock {
        let abl = graphInputABL
        let l = dryL, r = dryR
        return { [unowned(unsafe) self] frames in
            let n = min(frames, self.graphInputFrames)
            abl.count = 2
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: n * 4, mData: UnsafeMutableRawPointer(l))
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: n * 4, mData: UnsafeMutableRawPointer(r))
            return UnsafePointer(abl.unsafeMutablePointer)
        }
    }

    /// Closes the graph gate and waits for any render in progress to finish.
    /// During reconfiguration, the audio thread produces silence (safe transition).
    public func suspendGraph() {
        graphReady.value = false
        let deadline = Date().addingTimeInterval(0.5)
        while inRender.value && Date() < deadline { usleep(200) }
        renderBlock = nil
    }

    public func resumeGraph(renderBlock: @escaping AVAudioEngineManualRenderingBlock, sampleRate: Double) {
        self.renderBlock = renderBlock
        self.sampleRate = sampleRate
        graphReady.value = true
    }

    public var isGraphReady: Bool { graphReady.value }

    // MARK: Audio cycle

    /// Signal read back from the virtual device's input (audio thread).
    @inline(__always)
    public func recordLoopback(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, frames: Int) {
        meters.loopback.measure(l, frames: frames, channel: 0)
        meters.loopback.measure(r, frames: frames, channel: 1)
        meters.loopbackTap.write(l: l, r: r, count: frames)
        var pk: Float = 0
        for i in 0..<frames { pk = max(pk, abs(l[i])) }
        meters.verifyLoopbackPeak.storeMax(pk)
    }

    /// Processes `frames` samples. Output pointers may be nil.
    @inline(__always)
    public func process(frames: Int,
                        inL: UnsafePointer<Float>?, inR: UnsafePointer<Float>?,
                        virtualL: UnsafeMutablePointer<Float>?, virtualR: UnsafeMutablePointer<Float>?,
                        monitorL: UnsafeMutablePointer<Float>?, monitorR: UnsafeMutablePointer<Float>?) {
        let t0 = mach_absolute_time()
        let n = min(frames, maxFrames)
        meters.cycles.increment()
        meters.lastFrames.reset(); meters.lastFrames.increment(by: n)
        let fn = Float(max(n, 1))

        // 1. Input + input gain.
        let ig = dbToLinear(control.inputGainDB.load())
        let igStep = (ig - inputGain) / fn
        var g = inputGain
        if let inL {
            let r = inR ?? inL
            for i in 0..<n { g += igStep; dryL[i] = inL[i] * g; dryR[i] = r[i] * g }
        } else {
            dryL.update(repeating: 0, count: n); dryR.update(repeating: 0, count: n)
        }
        inputGain = ig
        meters.input.measure(dryL, frames: n, channel: 0)
        meters.input.measure(dryR, frames: n, channel: 1)
        meters.inputTap.write(l: dryL, r: dryR, count: n)

        // 2. Processing graph.
        var wetValid = false
        monitorSink.written = false
        inRender.value = true
        if graphReady.value, let rb = renderBlock {
            graphInputFrames = UInt32(n)
            graphOutputABL.count = 2
            graphOutputABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(wetL))
            graphOutputABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(wetR))
            var err: OSStatus = noErr
            let status = rb(AVAudioFrameCount(n), graphOutputABL.unsafeMutablePointer, &err)
            if status == .success {
                wetValid = true
                // The engine may have redirected the pointers to its own buffers.
                if let p = graphOutputABL[0].mData, p != UnsafeMutableRawPointer(wetL) { wetL.update(from: p.assumingMemoryBound(to: Float.self), count: n) }
                if graphOutputABL.count > 1, let p = graphOutputABL[1].mData, p != UnsafeMutableRawPointer(wetR) { wetR.update(from: p.assumingMemoryBound(to: Float.self), count: n) }
                else if graphOutputABL.count == 1 { wetR.update(from: wetL, count: n) }
            } else {
                meters.renderErrors.increment()
            }
        }
        inRender.value = false
        if !wetValid {
            wetL.update(repeating: 0, count: n); wetR.update(repeating: 0, count: n)
            monitorSink.written = false
            meters.transitionCycles.increment()
        }
        // Neutralizes invalid values produced by a plugin.
        var bad = 0
        for i in 0..<n {
            if !wetL[i].isFinite { wetL[i] = 0; bad += 1 }
            if !wetR[i].isFinite { wetR[i] = 0; bad += 1 }
        }
        if bad > 0 { meters.invalidSamples.increment(by: bad) }
        meters.processed.measure(wetL, frames: n, channel: 0)
        meters.processed.measure(wetR, frames: n, channel: 1)

        // 3. Transition fade (after reconfiguration) and crossfaded bypass.
        let transTarget: Float = wetValid ? 1 : 0
        let tStep = (transTarget - transitionGain) / fn
        let wetTarget: Float = control.bypass.value ? 0 : 1
        let wStep = (wetTarget - wetMix) / fn
        let useMonitorTap = monitorSink.written
        let matchTarget = dbToLinear(control.bypassMatchDB.load())
        let mStepDry = (matchTarget - dryMatch) / fn
        var dm = dryMatch
        var t = transitionGain, w = wetMix
        for i in 0..<n {
            t += tStep; w += wStep; dm += mStepDry
            let dl = dryL[i] * dm, dr = dryR[i] * dm
            // In bypass, the dry signal passes even during a reconfiguration.
            let wetGain = w * t
            let dryGain = 1 - w
            mainL[i] = dl * dryGain + wetL[i] * wetGain
            mainR[i] = dr * dryGain + wetR[i] * wetGain
            if useMonitorTap {
                monL[i] = dl * dryGain + monitorSink.left[i] * wetGain
                monR[i] = dr * dryGain + monitorSink.right[i] * wetGain
            }
        }
        transitionGain = transTarget
        wetMix = wetTarget
        dryMatch = matchTarget
        meters.outputTap.write(l: mainL, r: mainR, count: n)

        // 4. Virtual output (Mute Output only affects this one).
        let vt: Float = control.muteVirtual.value ? 0 : dbToLinear(control.virtualGainDB.load())
        let vStep = (vt - virtualGain) / fn
        var vg = virtualGain
        if let virtualL {
            let vr = virtualR ?? virtualL
            for i in 0..<n {
                vg += vStep
                virtualL[i] = clamp(mainL[i] * vg)
                vr[i] = clamp(mainR[i] * vg)
            }
            meters.virtualOut.measure(virtualL, frames: n, channel: 0)
            var vpk: Float = 0
            for i in 0..<n { vpk = max(vpk, abs(virtualL[i])) }
            meters.verifyVirtualPeak.storeMax(vpk)
            meters.virtualTap.write(l: virtualL, r: vr, count: n)
            meters.virtualOut.measure(vr, frames: n, channel: 1)
        }
        virtualGain = vt

        // 5. Monitoring (independent of the virtual output).
        let mt: Float = control.monitorEnabled.value ? dbToLinear(control.monitorGainDB.load()) : 0
        let mStep = (mt - monitorGain) / fn
        var mg = monitorGain
        let srcL = useMonitorTap ? monL : mainL
        let srcR = useMonitorTap ? monR : mainR
        if let monitorL {
            let mr = monitorR ?? monitorL
            for i in 0..<n {
                mg += mStep
                monitorL[i] = clamp(srcL[i] * mg)
                mr[i] = clamp(srcR[i] * mg)
            }
            meters.monitorOut.measure(monitorL, frames: n, channel: 0)
            meters.monitorOut.measure(mr, frames: n, channel: 1)
        }
        monitorGain = mt

        // 6. Cycle load.
        let elapsed = Double(mach_absolute_time() - t0) * hostTicksToSeconds
        let budget = Double(n) / sampleRate
        let load = Float(elapsed / max(budget, 1e-6))
        meters.maxLoad.storeMax(load)
        if load > 0.9 { meters.nearOverruns.increment() }
    }

    @inline(__always) private func clamp(_ x: Float) -> Float { x > 1 ? 1 : (x < -1 ? -1 : x) }
}
