import Foundation
import AVFoundation

/// Measurement point watched by an external meter monitor.
/// These are the points already used by VoxFlowAir's analyzers (tabs of the bottom panel).
public enum MonitorPoint: String, CaseIterable, Identifiable, Sendable {
    /// Input: microphone after input gain, before the chain (`EngineMeters.inputTap`).
    case input
    /// Output: final processed signal (bypass included), before the virtual output gain (`EngineMeters.outputTap`).
    case output

    public var id: String { rawValue }
    public var displayName: String { self == .input ? String(localized: "Input") : String(localized: "Output") }
    public var signalDescription: String {
        self == .input ? String(localized: "Microphone after input gain, before the chain")
                       : String(localized: "Final processed signal, before the output gain")
    }
    public func tap(in meters: EngineMeters) -> StereoAnalysisTap {
        self == .input ? meters.inputTap : meters.outputTap
    }
}

/// Plugins offered as meter monitors: every plugin of the Analyzers category, with
/// well-known meters first. Any effect Audio Unit can be fed, since its output is discarded.
public enum MeterPlugins {
    public struct Known: Sendable {
        public let manufacturer: String
        public let subType: String
        public let summary: String
    }

    /// Meters listed first, with a short description (stereo variants).
    public static let known: [Known] = [
        Known(manufacturer: "ksWV", subType: "WWLS", summary: "LUFS loudness (momentary, short-term, integrated), true peak, LRA"),
        Known(manufacturer: "ksWV", subType: "WLMS", summary: "LUFS loudness (momentary, short-term, integrated), true peak, LRA"),
        Known(manufacturer: "ksWV", subType: "DRGS", summary: "Peak and average on one scale (Dorrough)"),
        Known(manufacturer: "ksWV", subType: "VUMS", summary: "Analog VU meter"),
        Known(manufacturer: "ksWV", subType: "PPMS", summary: "VU and PPM meter bridge"),
        Known(manufacturer: "ksWV", subType: "WAES", summary: "Full analyzer: spectrum, stereo image, peaks"),
        Known(manufacturer: "ksWV", subType: "WAAS", summary: "Spectrum"),
        Known(manufacturer: "ksWV", subType: "WVUS", summary: "Peak and RMS"),
        Known(manufacturer: "ksWV", subType: "WAPS", summary: "Stereo image and phase"),
    ]

    private static func knownEntry(_ ref: PluginReference) -> Known? {
        known.first { fcc($0.manufacturer) == ref.manufacturer && fcc($0.subType) == ref.subType }
    }

    /// Meters available among `plugins`: the known ones in the order of `known`, then the
    /// other analyzers by name. Multichannel variants are left out.
    public static func available(in plugins: [PluginInfo]) -> [PluginInfo] {
        let first = known.compactMap { k in
            plugins.first { $0.reference.manufacturer == fcc(k.manufacturer) && $0.reference.subType == fcc(k.subType) }
        }
        let firstIDs = Set(first.map(\.id))
        let others = plugins
            .filter { $0.category == .analyzer && !$0.isMultichannelVariant && !firstIDs.contains($0.id) }
            .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
        return first + others
    }

    public static func summary(for ref: PluginReference) -> String? {
        knownEntry(ref).map { String(localized: String.LocalizationValue($0.summary)) }
    }
}

/// Feeds meter plugins with a copy of the signal read from the existing analysis buffers,
/// on a dedicated thread off the audio path. The audio sent to apps is neither changed
/// nor delayed: the plugins' output is discarded (only its peak is recorded, to prove
/// that the plugin does receive the signal).
public final class MeterMonitorFeeder: @unchecked Sendable {
    public static let blockFrames: AVAudioFrameCount = 256

    private final class Slot {
        let unit: AVAudioUnit
        let tap: StereoAnalysisTap
        let renderBlock: AURenderBlock
        var readPos: Int
        var inBuf: AVAudioPCMBuffer
        var outBuf: AVAudioPCMBuffer
        var timeStamp = AudioTimeStamp()
        let receivedPeak = RTFloat(0)
        var renderErrors = 0
        var gaps = 0

        init(unit: AVAudioUnit, tap: StereoAnalysisTap, inBuf: AVAudioPCMBuffer, outBuf: AVAudioPCMBuffer) {
            self.unit = unit; self.tap = tap; self.inBuf = inBuf; self.outBuf = outBuf
            renderBlock = unit.auAudioUnit.renderBlock
            readPos = min(tap.left.totalWritten, tap.right.totalWritten)
            timeStamp.mFlags = .sampleTimeValid
        }
    }

    private let lock = NSLock()
    private var slots: [MonitorPoint: Slot] = [:]
    private var thread: Thread?
    private let running = RTBool(false)
    public private(set) var sampleRate: Double = 48000

    public init() {}

    deinit { running.value = false }

    /// Prepares the plugin (formats, resources) and attaches it to the `tap` buffer.
    /// Replaces any plugin already attached to this point (returned so it can be released).
    @discardableResult
    public func attach(_ unit: AVAudioUnit, tap: StereoAnalysisTap, at point: MonitorPoint) throws -> AVAudioUnit? {
        let (inBuf, outBuf) = try Self.configure(unit, sampleRate: sampleRate)
        let slot = Slot(unit: unit, tap: tap, inBuf: inBuf, outBuf: outBuf)
        lock.lock()
        let old = slots[point]
        slots[point] = slot
        lock.unlock()
        old?.unit.auAudioUnit.deallocateRenderResources()
        startThreadIfNeeded()
        return old?.unit
    }

    /// Detaches the plugin from the point (it stops receiving the signal).
    @discardableResult
    public func detach(_ point: MonitorPoint) -> AVAudioUnit? {
        lock.lock()
        let old = slots.removeValue(forKey: point)
        lock.unlock()
        old?.unit.auAudioUnit.deallocateRenderResources()
        return old?.unit
    }

    /// Reconfigures the plugins at the engine's sample rate (after a device change).
    public func setSampleRate(_ sr: Double) {
        guard sr > 0, abs(sr - sampleRate) > 0.5 else { return }
        lock.lock()
        defer { lock.unlock() }
        sampleRate = sr
        for (point, s) in slots {
            s.unit.auAudioUnit.deallocateRenderResources()
            do {
                let (i, o) = try Self.configure(s.unit, sampleRate: sr)
                s.inBuf = i; s.outBuf = o
                s.readPos = min(s.tap.left.totalWritten, s.tap.right.totalWritten)
            } catch {
                vlog(.error, "Meter monitor \(point.rawValue): could not reconfigure at \(Int(sr)) Hz (\(error))")
                slots[point] = nil
            }
        }
    }

    /// Peak (linear) recorded at the plugin's output since the last call.
    public func takeReceivedPeak(_ point: MonitorPoint) -> Float? {
        lock.lock(); defer { lock.unlock() }
        return slots[point]?.receivedPeak.take()
    }

    public func stats(_ point: MonitorPoint) -> (renderErrors: Int, gaps: Int)? {
        lock.lock(); defer { lock.unlock() }
        return slots[point].map { ($0.renderErrors, $0.gaps) }
    }

    // MARK: Configuration

    private static func configure(_ unit: AVAudioUnit, sampleRate: Double) throws -> (AVAudioPCMBuffer, AVAudioPCMBuffer) {
        let au = unit.auAudioUnit
        guard au.inputBusses.count > 0, au.outputBusses.count > 0 else { throw RuntimeError(String(localized: "The plugin has no audio input or no audio output")) }
        // Stereo if the plugin accepts it, otherwise its native channel count.
        func set(_ bus: AUAudioUnitBus) throws -> AVAudioFormat {
            let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            if (try? bus.setFormat(stereo)) != nil { return stereo }
            let native = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: max(bus.format.channelCount, 1))!
            try bus.setFormat(native)
            return native
        }
        let inFormat = try set(au.inputBusses[0])
        let outFormat = try set(au.outputBusses[0])
        // AU v2 bridges require enabled busses to call the input block.
        au.inputBusses[0].isEnabled = true
        au.outputBusses[0].isEnabled = true
        au.maximumFramesToRender = 4096
        try au.allocateRenderResources()
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: blockFrames)!
        inBuf.frameLength = blockFrames
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: blockFrames)!
        return (inBuf, outBuf)
    }

    // MARK: Feeding thread

    private func startThreadIfNeeded() {
        guard thread == nil else { return }
        running.value = true
        let t = Thread { [weak self] in
            while let self, self.running.value {
                self.pumpAll()
                usleep(3000)
            }
        }
        t.name = "VoxFlowAir.MeterMonitors"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func pumpAll() {
        lock.lock()
        for s in slots.values { pump(s) }
        lock.unlock()
    }

    private func pump(_ s: Slot) {
        let n = Int(Self.blockFrames)
        let w = min(s.tap.left.totalWritten, s.tap.right.totalWritten)
        // Too far behind (thread suspended) or buffer reset: resync to the present.
        if w < s.readPos || w - s.readPos > s.tap.left.capacity - 4 * n {
            s.readPos = max(w - n, 0)
            s.gaps += 1
        }
        var blocks = 0
        while w - s.readPos >= n && blocks < 64 {
            let channels = Int(s.inBuf.format.channelCount)
            let dst = s.inBuf.floatChannelData!
            let okL = s.tap.left.read(from: s.readPos, count: n, into: dst[0])
            var okR = true
            if channels > 1 {
                okR = s.tap.right.read(from: s.readPos, count: n, into: dst[1])
                for c in 2..<max(channels, 2) { dst[c].update(from: dst[c - 2], count: n) }
            }
            guard okL, okR else { s.readPos = w; s.gaps += 1; return }
            render(s, frames: AVAudioFrameCount(n))
            s.readPos += n
            blocks += 1
        }
    }

    private func render(_ s: Slot, frames: AVAudioFrameCount) {
        s.outBuf.frameLength = frames
        let outABL = UnsafeMutableAudioBufferListPointer(s.outBuf.mutableAudioBufferList)
        // The plugin may provide its own buffers: reset the pointers on every cycle.
        for (i, b) in outABL.enumerated() {
            outABL[i] = AudioBuffer(mNumberChannels: b.mNumberChannels, mDataByteSize: frames * 4,
                                    mData: UnsafeMutableRawPointer(s.outBuf.floatChannelData![i]))
        }
        let input = s.inBuf
        var flags = AudioUnitRenderActionFlags()
        let status = s.renderBlock(&flags, &s.timeStamp, frames, 0, s.outBuf.mutableAudioBufferList) { _, _, count, _, abl in
            let src = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(abl)
            for c in 0..<min(dst.count, src.count) {
                let bytes = Int(count) * 4
                if dst[c].mData == nil { dst[c].mData = src[c].mData }
                else { memcpy(dst[c].mData, src[c].mData, bytes) }
                dst[c].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }
        s.timeStamp.mSampleTime += Double(frames)
        if status != noErr { s.renderErrors += 1; return }
        var pk: Float = 0
        if let p = outABL[0].mData?.assumingMemoryBound(to: Float.self) {
            for i in 0..<Int(frames) { pk = max(pk, abs(p[i])) }
        }
        s.receivedPeak.storeMax(pk)
    }
}
