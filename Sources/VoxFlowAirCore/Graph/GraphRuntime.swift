import Foundation
import AVFoundation
import VFObjC

/// Runtime state of a logical node.
public enum NodeRuntimeStatus: Equatable, Sendable {
    case ok
    case loading
    /// Plugin not installed: transparent node, settings kept.
    case missing
    /// Load or connection failure: transparent node.
    case failed(String)
    /// Plugin invalidated (e.g. the plugin's host process stopped).
    case crashed

    public var isHealthy: Bool { self == .ok }
    public var label: String {
        switch self {
        case .ok: return String(localized: "Active")
        case .loading: return String(localized: "Loading…")
        case .missing: return String(localized: "Plugin missing")
        case .failed(let m): return String(localized: "Error: \(m)")
        case .crashed: return String(localized: "Plugin stopped")
        }
    }
}

/// Mapping between a logical node and the actual AVAudioEngine nodes.
final class RuntimeNode {
    let id: UUID
    let kind: NodeKind
    /// Sums multiple inputs and adapts the channel count.
    var inMixer: AVAudioMixerNode?
    /// Third-party plugin (nil if missing or failed).
    var unit: AVAudioUnit?
    /// Native node (meter, gain, analyzer, monitoring) — always present except for the output.
    var utility: AVAudioUnitEffect?
    var unitInFormat: AVAudioFormat?
    var unitOutFormat: AVAudioFormat?

    init(id: UUID, kind: NodeKind) { self.id = id; self.kind = kind }

    var utilityUnit: VFUtilityAudioUnit? { utility?.auAudioUnit as? VFUtilityAudioUnit }
    var meter: LevelMeter? { utilityUnit?.kernel.meter }
}

/// Builds and runs the AVAudioEngine graph (real-time manual rendering mode)
/// from the `ProcessingGraph` model.
public final class GraphRuntime {
    public let engine = AVAudioEngine()
    public let format: AVAudioFormat
    public let sampleRate: Double
    let processor: RealtimeProcessor
    private(set) var nodes: [UUID: RuntimeNode] = [:]
    private var attachedUnits = Set<ObjectIdentifier>()

    public init(sampleRate: Double, processor: RealtimeProcessor) throws {
        VFUtilityAudioUnit.registerOnce()
        self.sampleRate = sampleRate
        self.processor = processor
        guard let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw RuntimeError(String(localized: "Invalid audio format (\(sampleRate) Hz)"))
        }
        format = f
        var thrown: Error?
        var objcErr: NSError?
        let ok = VFTryObjC({
            do {
                try self.engine.enableManualRenderingMode(.realtime, format: f, maximumFrameCount: AVAudioFrameCount(processor.maxFrames))
                _ = self.engine.inputNode.setManualRenderingInputPCMFormat(f, inputBlock: processor.makeInputBlock())
            } catch { thrown = error }
        }, &objcErr)
        if let thrown { throw thrown }
        if !ok { throw RuntimeError(String(localized: "Enabling manual rendering: \(objcErr?.localizedDescription ?? "?")")) }
    }

    deinit {
        engine.stop()
    }

    public func meter(for id: UUID) -> LevelMeter? { nodes[id]?.meter }
    public func analyzerTap(for id: UUID) -> StereoAnalysisTap? { nodes[id]?.utilityUnit?.kernel.tap }
    /// Recent samples at a node's output (all kinds).
    public func tap(for id: UUID) -> StereoAnalysisTap? { nodes[id]?.utilityUnit?.kernel.tap }

    /// Rebuilds every connection from the model. The audio thread outputs
    /// transition silence during the operation.
    /// - Parameter plugins: AU instances already loaded, by node identifier.
    /// - Returns: the status of each node.
    @discardableResult
    public func apply(_ graph: ProcessingGraph, plugins: [UUID: AVAudioUnit], pluginStatus: [UUID: NodeRuntimeStatus]) -> [UUID: NodeRuntimeStatus] {
        processor.suspendGraph()
        engine.stop()
        var status: [UUID: NodeRuntimeStatus] = [:]

        // 1. Detach what no longer exists and disconnect everything.
        let wanted = Set(graph.nodes.map(\.id))
        for (id, rn) in nodes where !wanted.contains(id) {
            for n in [rn.inMixer, rn.unit, rn.utility].compactMap({ $0 as AVAudioNode? }) { detach(n) }
            nodes[id] = nil
        }
        for n in engine.attachedNodes where n !== engine.outputNode {
            engine.disconnectNodeOutput(n)
            engine.disconnectNodeInput(n)
        }

        // 2. Create / update the physical nodes.
        for gn in graph.nodes {
            let rn = nodes[gn.id] ?? RuntimeNode(id: gn.id, kind: gn.kind)
            nodes[gn.id] = rn
            switch gn.kind {
            case .input:
                ensureUtility(rn, mode: .meter)
            case .output:
                break
            case .monitorOutput:
                ensureMixer(rn); ensureUtility(rn, mode: .monitorTap)
                rn.utilityUnit?.kernel.monitorSink = processor.monitorSink
            case .gain:
                ensureMixer(rn); ensureUtility(rn, mode: .gain)
                if let g = gn.parameters["gain"] { rn.utilityUnit?.kernel.gainDB.store(Float(g)); rn.utilityUnit?.parameterTree?.parameter(withAddress: 0)?.value = Float(g) }
            case .analyzer:
                ensureMixer(rn); ensureUtility(rn, mode: .analyzer)
            case .audioUnit:
                ensureMixer(rn); ensureUtility(rn, mode: .meter)
                rn.inMixer?.outputVolume = 1
                let newUnit = plugins[gn.id]
                if let old = rn.unit, old !== newUnit { detach(old); rn.unit = nil }
                if let u = newUnit {
                    attach(u)
                    rn.unit = u
                    let (fi, fo) = chooseFormats(for: u)
                    rn.unitInFormat = fi; rn.unitOutFormat = fo
                    // The mixer downmixes stereo to mono at constant power (+3 dB on a signal
                    // identical on both channels, as with a microphone): compensate.
                    rn.inMixer?.outputVolume = fi.channelCount == 1 ? Float(0.5.squareRoot()) : 1
                }
                status[gn.id] = pluginStatus[gn.id] ?? (newUnit == nil ? .missing : .ok)
            }
            if status[gn.id] == nil { status[gn.id] = .ok }
        }

        // 3. Internal connections of each logical node.
        for gn in graph.nodes {
            guard let rn = nodes[gn.id] else { continue }
            switch gn.kind {
            case .input:
                connect(engine.inputNode, rn.utility!, format: format, status: &status, node: gn.id)
            case .output:
                break
            case .gain, .analyzer, .monitorOutput:
                connect(rn.inMixer!, rn.utility!, format: format, status: &status, node: gn.id)
            case .audioUnit:
                if let u = rn.unit, status[gn.id] == .ok,
                   connect(rn.inMixer!, u, format: rn.unitInFormat ?? format, status: &status, node: gn.id),
                   connect(u, rn.utility!, format: rn.unitOutFormat ?? format, status: &status, node: gn.id) {
                    // ok
                } else {
                    // Plugin missing or failed: the node stays transparent.
                    if let u = rn.unit { engine.disconnectNodeOutput(u); engine.disconnectNodeInput(u) }
                    engine.disconnectNodeOutput(rn.inMixer!)
                    connect(rn.inMixer!, rn.utility!, format: format, status: &status, node: gn.id, markFailure: false)
                }
            }
        }

        // 4. Logical connections (with fan-out to several destinations).
        let main = engine.mainMixerNode
        var busCounters: [ObjectIdentifier: Int] = [:]
        func nextBus(_ m: AVAudioMixerNode) -> Int {
            let k = ObjectIdentifier(m)
            let b = busCounters[k, default: 0]
            busCounters[k] = b + 1
            return b
        }
        let valid = graph.topologicalOrder() != nil
        for gn in graph.nodes where gn.kind.hasOutputPort {
            guard valid, let src = nodes[gn.id]?.utility else { continue }
            let points: [AVAudioConnectionPoint] = graph.outgoing(gn.id).compactMap { c in
                guard let dst = graph.node(c.to), let drn = nodes[c.to] else { return nil }
                if dst.kind == .output { return AVAudioConnectionPoint(node: main, bus: nextBus(main)) }
                guard let m = drn.inMixer else { return nil }
                return AVAudioConnectionPoint(node: m, bus: nextBus(m))
            }
            guard !points.isEmpty else { continue }
            let srcFormat = src.outputFormat(forBus: 0)
            let f = srcFormat.channelCount > 0 ? srcFormat : format
            var err: NSError?
            if !VFTryObjC({ self.engine.connect(src, to: points, fromBus: 0, format: f) }, &err) {
                status[gn.id] = .failed(err?.localizedDescription ?? String(localized: "connection"))
                vlog(.error, "Connection from \(gn.title) failed: \(err?.localizedDescription ?? "?")")
            }
        }
        // The monitoring node must be pulled by the engine: it joins the main mix
        // (it feeds silence into it; its signal goes to the headphones).
        if let mon = graph.monitorNode, let u = nodes[mon.id]?.utility {
            connect(u, main, bus: nextBus(main), format: format, status: &status, node: mon.id)
        }
        var err: NSError?
        _ = VFTryObjC({ self.engine.connect(main, to: self.engine.outputNode, format: self.format) }, &err)
        main.outputVolume = 1

        // 5. Bypass.
        for gn in graph.nodes {
            let by = graph.isEffectivelyBypassed(gn)
            nodes[gn.id]?.unit?.auAudioUnit.shouldBypassEffect = by
            if gn.kind == .gain { nodes[gn.id]?.utility?.auAudioUnit.shouldBypassEffect = by }
        }

        // 6. Start.
        do {
            var startErr: Error?
            var objcErr: NSError?
            let ok = VFTryObjC({
                self.engine.prepare()
                do { try self.engine.start() } catch { startErr = error }
            }, &objcErr)
            if let e = startErr ?? (ok ? nil : objcErr) { throw e }
            processor.resumeGraph(renderBlock: engine.manualRenderingBlock, sampleRate: sampleRate)
        } catch {
            vlog(.error, "Could not start the graph: \(error.localizedDescription)")
            for id in status.keys where status[id] == .ok { _ = id }
        }
        return status
    }

    /// Updates the bypass without rebuilding the graph.
    public func setBypass(_ graph: ProcessingGraph) {
        for gn in graph.nodes {
            let by = graph.isEffectivelyBypassed(gn)
            nodes[gn.id]?.unit?.auAudioUnit.shouldBypassEffect = by
            if gn.kind == .gain { nodes[gn.id]?.utility?.auAudioUnit.shouldBypassEffect = by }
        }
    }

    public func setGain(node: UUID, db: Double) {
        guard let u = nodes[node]?.utilityUnit, u.kernel.mode == .gain else { return }
        u.kernel.gainDB.store(Float(db))
        u.parameterTree?.parameter(withAddress: 0)?.value = Float(db)
    }

    /// Detaches the plugins from this engine (to transfer them to another engine).
    public func releasePlugins() {
        processor.suspendGraph()
        engine.stop()
        for rn in nodes.values { if let u = rn.unit { detach(u); rn.unit = nil } }
    }

    public func stop() {
        processor.suspendGraph()
        engine.stop()
    }

    // MARK: Helpers

    private func ensureMixer(_ rn: RuntimeNode) {
        if rn.inMixer == nil {
            let m = AVAudioMixerNode()
            attach(m)
            rn.inMixer = m
        }
    }

    private func ensureUtility(_ rn: RuntimeNode, mode: UtilityMode) {
        if let u = rn.utilityUnit, u.kernel.mode == mode { return }
        if let old = rn.utility { detach(old) }
        let u = AVAudioUnitEffect(audioComponentDescription: mode.componentDescription)
        attach(u)
        rn.utility = u
    }

    private func attach(_ n: AVAudioNode) {
        let k = ObjectIdentifier(n)
        if n.engine === engine { attachedUnits.insert(k); return }
        if let other = n.engine { other.detach(n) }
        engine.attach(n)
        attachedUnits.insert(k)
    }

    private func detach(_ n: AVAudioNode) {
        if n.engine === engine { engine.detach(n) }
        attachedUnits.remove(ObjectIdentifier(n))
    }

    @discardableResult
    private func connect(_ a: AVAudioNode, _ b: AVAudioNode, bus: Int = 0, format f: AVAudioFormat,
                         status: inout [UUID: NodeRuntimeStatus], node: UUID, markFailure: Bool = true) -> Bool {
        var err: NSError?
        let ok = VFTryObjC({ self.engine.connect(a, to: b, fromBus: 0, toBus: bus, format: f) }, &err)
        if !ok {
            vlog(.error, "Internal connection failed (\(f.channelCount) channels): \(err?.localizedDescription ?? "?")")
            if markFailure { status[node] = .failed(err?.localizedDescription ?? String(localized: "incompatible format")) }
        }
        return ok
    }

    /// Chooses a plugin's channel configuration: stereo if possible, otherwise mono.
    private func chooseFormats(for u: AVAudioUnit) -> (AVAudioFormat, AVAudioFormat) {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let stereo = format
        let caps = (u.auAudioUnit.channelCapabilities ?? []).map(\.intValue)
        var pairs: [(Int, Int)] = []
        var i = 0
        while i + 1 < caps.count { pairs.append((caps[i], caps[i + 1])); i += 2 }
        func supports(_ inC: Int, _ outC: Int) -> Bool {
            if pairs.isEmpty { return false }
            return pairs.contains { p in
                let (a, b) = p
                if a == -1 && b == -1 { return true }
                if a == -1 && b == -2 || a == -2 && b == -1 { return inC == outC }
                if a == -1 { return b == outC || b < -2 && outC <= -b }
                if b == -1 { return a == inC }
                if a == -2 || b == -2 { return inC == outC }
                return a == inC && b == outC
            }
        }
        if supports(2, 2) { return (stereo, stereo) }
        if supports(1, 1) { return (mono, mono) }
        if supports(1, 2) { return (mono, stereo) }
        if supports(2, 1) { return (stereo, mono) }
        // No information: try stereo on the plugin's busses.
        let au = u.auAudioUnit
        if au.inputBusses.count > 0, au.outputBusses.count > 0 {
            if (try? au.inputBusses[0].setFormat(stereo)) != nil, (try? au.outputBusses[0].setFormat(stereo)) != nil { return (stereo, stereo) }
            if (try? au.inputBusses[0].setFormat(mono)) != nil, (try? au.outputBusses[0].setFormat(mono)) != nil { return (mono, mono) }
        }
        return (stereo, stereo)
    }
}

public struct RuntimeError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
    public var errorDescription: String? { message }
}
