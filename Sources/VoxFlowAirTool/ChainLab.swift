import Foundation
import AVFoundation
import Accelerate
import VoxFlowAirCore

/// One chain step: a real AU plugin set by its displayed parameter values.
struct Stage {
    let plugin: String
    let title: String
    let role: String
    var settings: [(String, String)]
}

func opt(_ args: [String], _ key: String) -> String? {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fmt(_ v: Double) -> String { v.isFinite && v > -119 ? String(format: "%.1f", v) : "-∞" }

/// Offline test bench: runs a real chain (same classes as the app:
/// GraphRuntime + RealtimeProcessor) on an audio file and measures each stage.
final class ChainLab {
    let sr: Double = 48000
    let block = 256
    let processor = RealtimeProcessor(maxFrames: 4096)
    var runtime: GraphRuntime!
    var graph = ProcessingGraph()
    var units: [UUID: AVAudioUnit] = [:]
    var stageNodes: [(stage: Stage, id: UUID)] = []
    var trimID: UUID!
    var outGainID: UUID!
    let input: [Float]

    init(input: [Float]) throws {
        self.input = input
        runtime = try GraphRuntime(sampleRate: sr, processor: processor)
    }

    /// Builds the graph: Input → Input gain → stages → Output gain → Virtual output.
    func build(stages: [Stage], loaded: [AVAudioUnit]) {
        graph = ProcessingGraph()
        let inNode = GraphNode(kind: .input, position: .init(x: 60, y: 60))
        let trim = GraphNode(kind: .gain, title: "Input Gain (calibrated)", position: .init(x: 0, y: 0), parameters: ["gain": 0])
        trimID = trim.id
        graph.nodes = [inNode, trim]
        _ = try? graph.connect(from: inNode.id, to: trim.id)
        var prev = trim.id
        stageNodes = []
        for (s, u) in zip(stages, loaded) {
            guard let info = PluginCatalog.shared.info(name: s.plugin) else { continue }
            var n = GraphNode(kind: .audioUnit, title: s.title, position: .init(x: 0, y: 0), plugin: info.reference)
            n.loadMode = .inProcess
            graph.nodes.append(n)
            _ = try? graph.connect(from: prev, to: n.id)
            prev = n.id
            units[n.id] = u
            stageNodes.append((s, n.id))
            // The output gain goes right before the final limiter.
            if s.plugin == "Sibilance (m)" {
                let g = GraphNode(kind: .gain, title: "Output Level (calibrated)", position: .init(x: 0, y: 0), parameters: ["gain": 0])
                outGainID = g.id
                graph.nodes.append(g)
                _ = try? graph.connect(from: prev, to: g.id)
                prev = g.id
            }
        }
        let out = GraphNode(kind: .output, position: .init(x: 0, y: 0))
        graph.nodes.append(out)
        _ = try? graph.connect(from: prev, to: out.id)
        graph.arrangeMainChain(rowWidth: 1100)
        runtime.apply(graph, plugins: units, pluginStatus: [:])
    }

    /// Loads an existing graph (preset) with its plugin instances already restored.
    func load(graph g: ProcessingGraph, units u: [UUID: AVAudioUnit]) {
        graph = g; units = u
        runtime.apply(graph, plugins: units, pluginStatus: [:])
    }

    func setGain(_ id: UUID, _ db: Double) {
        if let i = graph.index(of: id) { graph.nodes[i].parameters["gain"] = db }
        runtime.setGain(node: id, db: db)
    }

    struct Report {
        var inputPeak: Float = 0, inputVoicedRMS: Double = -120, noiseFloor: Double = -120
        var stageRMS: [UUID: Double] = [:]          // mean level (voice) at the output of each node
        var meters: [String: [Double]] = [:]        // gain reduction meters read from the plugins
        var outPeak: Float = 0, outClips = 0
        var outIntegrated: Double = -120, outShortMax: Double = -120, outLRA: Double = 0, outTP: Double = -120
        var output: [Float] = []
    }

    /// Runs the file through the chain. `meterParams`: meter parameters to sample (plugin → name).
    func run(meterParams: [(UUID, String)] = []) -> Report {
        var r = Report()
        // No graph rebuild between two passes: stopping the engine would make Waves
        // plugins lose parameter changes not yet applied.
        let loud = LoudnessMeter(sampleRate: sr)
        loud.update(left: processor.meters.virtualTap.left, right: processor.meters.virtualTap.right)
        var vl = [Float](repeating: 0, count: block), vr = vl, ml = vl, mr = vl
        var inBlockRMS: [Double] = []
        var sums: [UUID: (Double, Int)] = [:]
        var meterVals: [String: [Double]] = [:]
        processor.control.monitorEnabled.value = false
        processor.control.muteVirtual.value = false
        processor.control.bypass.value = false
        processor.control.inputGainDB.store(0); processor.control.virtualGainDB.store(0)
        // Warm-up: 1 s of silence (clears compressor state, applies parameters).
        let silence = [Float](repeating: 0, count: block)
        for _ in 0..<Int(1.0 * sr) / block { silence.withUnsafeBufferPointer { s in vl.withUnsafeMutableBufferPointer { v in vr.withUnsafeMutableBufferPointer { w in
            processor.process(frames: block, inL: s.baseAddress, inR: s.baseAddress, virtualL: v.baseAddress, virtualR: w.baseAddress, monitorL: nil, monitorR: nil) } } } }
        for id in graph.nodes.map(\.id) { _ = runtime.meter(for: id)?.read() }
        loud.reset(); loud.update(left: processor.meters.virtualTap.left, right: processor.meters.virtualTap.right)

        var output = [Float](); output.reserveCapacity(input.count)
        var i = 0
        while i + block <= input.count {
            input.withUnsafeBufferPointer { inp in
                let p = inp.baseAddress! + i
                vl.withUnsafeMutableBufferPointer { v in vr.withUnsafeMutableBufferPointer { w in ml.withUnsafeMutableBufferPointer { m in mr.withUnsafeMutableBufferPointer { n in
                    processor.process(frames: block, inL: p, inR: p, virtualL: v.baseAddress, virtualR: w.baseAddress, monitorL: m.baseAddress, monitorR: n.baseAddress)
                } } } }
            }
            var ss: Float = 0
            input.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + i, 1, &ss, vDSP_Length(block)) }
            let brms = 10 * log10(Double(ss) / Double(block) + 1e-12)
            inBlockRMS.append(brms)
            r.inputPeak = max(r.inputPeak, input[i..<(i + block)].map(abs).max() ?? 0)
            for n in graph.nodes {
                if let rd = runtime.meter(for: n.id)?.read() {
                    let db = Double(linearToDB(max(rd.rmsL, rd.rmsR)))
                    // Energy average over voice blocks (computed below).
                    var cur = sums[n.id] ?? (0, 0)
                    cur.0 += brms > -50 ? pow(10, db / 10) : 0; cur.1 += brms > -50 ? 1 : 0
                    sums[n.id] = cur
                }
            }
            for (id, name) in meterParams {
                if let u = units[id], let p = ParameterSetter.parameter(u.auAudioUnit, name) {
                    let v = abs(Double(ParameterSetter.number(p.currentValueString) ?? 0))
                    if brms > -50 { meterVals["\(id)|\(name)", default: []].append(v) }
                }
            }
            output.append(contentsOf: vl)
            r.outPeak = max(r.outPeak, vl.map(abs).max() ?? 0)
            r.outClips += vl.filter { abs($0) >= 0.999 }.count
            loud.update(left: processor.meters.virtualTap.left, right: processor.meters.virtualTap.right)
            r.outShortMax = max(r.outShortMax, loud.shortTermLUFS.isFinite ? loud.shortTermLUFS : -120)
            i += block
        }
        let sorted = inBlockRMS.sorted()
        r.noiseFloor = sorted.isEmpty ? -120 : sorted[sorted.count / 10]
        let voiced = inBlockRMS.filter { $0 > -50 }
        r.inputVoicedRMS = voiced.isEmpty ? -120 : 10 * log10(voiced.map { pow(10, $0 / 10) }.reduce(0, +) / Double(voiced.count))
        for (id, s) in sums where s.1 > 0 { r.stageRMS[id] = 10 * log10(s.0 / Double(s.1) + 1e-12) }
        r.meters = meterVals
        r.outIntegrated = loud.integratedLUFS; r.outLRA = loud.loudnessRange; r.outTP = loud.truePeakDB
        r.output = output
        return r
    }
}

extension PluginCatalog {
    static let shared: PluginCatalog = { let c = PluginCatalog(); c.scan(); return c }()
    func info(name: String) -> PluginInfo? { plugins.first { $0.name == name } }
}

/// Reads an audio file as mono (channel average), resampled to 48 kHz if needed.
func readMono48k(_ url: URL) throws -> [Float] {
    let f = try AVAudioFile(forReading: url)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    if f.processingFormat.sampleRate == 48000 {
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        var out = [Float](repeating: 0, count: n)
        for c in 0..<ch { let p = buf.floatChannelData![c]; for i in 0..<n { out[i] += p[i] / Float(ch) } }
        return out
    }
    let conv = AVAudioConverter(from: f.processingFormat, to: fmt)!
    let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 48000 / f.processingFormat.sampleRate) + 1024)!
    var fed = false
    _ = conv.convert(to: outBuf, error: nil) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return buf }
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
}

func writeWav(_ samples: [Float], to url: URL) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    b.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try f.write(from: b)
}

/// Technical test signal (no substitute for a real voice): speech-shaped noise,
/// modulated at 4 Hz, phrases at varying levels, sibilant bursts and silences.
func synthVoiceLike(seconds: Double) -> [Float] {
    let sr = 48000.0, n = Int(seconds * sr)
    var out = [Float](repeating: 0, count: n)
    var seed: UInt64 = 42
    func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1 }
    var lp1: Float = 0, lp2: Float = 0, hp: Float = 0, prev: Float = 0
    for i in 0..<n {
        let t = Double(i) / sr
        let phrase = Int(t / 2.5)
        let level: Float = [0.08, 0.25, 0.12, 0.35, 0.05, 0.2, 0.3, 0.1][phrase % 8]
        let inPhrase = t.truncatingRemainder(dividingBy: 2.5) < 2.0
        let env = inPhrase ? Float(0.55 + 0.45 * sin(2 * .pi * 4.3 * t)) : 0.003
        let w = rnd()
        lp1 += 0.08 * (w - lp1); lp2 += 0.3 * (w - lp2)
        var s = (lp1 * 3 + lp2 * 0.8) * level * env
        // Occasional sibilants.
        if inPhrase && Int(t * 3) % 7 == 3 { hp = w - prev; s += hp * level * 0.6 }
        prev = w
        out[i] = s
    }
    return out
}

/// Levels per 10 ms frame in a frequency band (biquad band-pass filter).
func bandFrameDB(_ x: [Float], lowHz: Double, highHz: Double, sr: Double = 48000) -> [Double] {
    let f0 = sqrt(lowHz * highHz), bw = log2(highHz / lowHz)
    let w0 = 2 * Double.pi * f0 / sr
    let alpha = sin(w0) * sinh(log(2) / 2 * bw * w0 / sin(w0))
    let a0 = 1 + alpha
    let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
    var z1 = 0.0, z2 = 0.0
    let frame = Int(sr / 100)
    var out: [Double] = []
    var acc = 0.0, n = 0
    for v in x {
        let xv = Double(v)
        let y = b0 * xv + z1
        z1 = -a1 * y + z2
        z2 = b2 * xv - a2 * y
        acc += y * y; n += 1
        if n == frame { out.append(10 * log10(acc / Double(frame) + 1e-14)); acc = 0; n = 0 }
    }
    return out
}


/// Metrics comparable across presets, computed on the full render.
struct VoiceMetrics {
    var integrated = -120.0, lra = 0.0, tp = -120.0, peak = -120.0
    var voicedRMS = -120.0
    /// Standard deviation of the level over 400 ms windows during speech (level stability).
    var levelStdDev = 0.0
    /// Spread between loud (p90) and soft (p10) phrases, 400 ms windows.
    var loudSoftSpread = 0.0
    /// Level between phrases (where the input is silent).
    var pauseLevel = -120.0
    /// Sibilance: 5–10 kHz / 1–3 kHz ratio, 95th percentile.
    var sibilanceP95 = 0.0
    var clips = 0
}

func metrics(input: [Float], output: [Float], report r: ChainLab.Report) -> VoiceMetrics {
    var m = VoiceMetrics()
    m.integrated = r.outIntegrated; m.lra = r.outLRA; m.tp = r.outTP; m.peak = Double(linearToDB(r.outPeak)); m.clips = r.outClips
    let n = min(input.count, output.count)
    let win = 19200 // 400 ms
    var inW: [Double] = [], outW: [Double] = []
    for s in stride(from: 0, to: n - win, by: win / 4) {
        var ei = 0.0, eo = 0.0
        for i in s..<(s + win) { ei += Double(input[i] * input[i]); eo += Double(output[i] * output[i]) }
        inW.append(10 * log10(ei / Double(win) + 1e-14)); outW.append(10 * log10(eo / Double(win) + 1e-14))
    }
    let sortedIn = inW.sorted()
    let noise = sortedIn.isEmpty ? -120 : sortedIn[sortedIn.count / 20]
    let voiced = inW.indices.filter { inW[$0] > noise + 20 }
    let pauses = inW.indices.filter { inW[$0] < noise + 4 }
    let vo = voiced.map { outW[$0] }.sorted()
    if !vo.isEmpty {
        let mean = vo.reduce(0, +) / Double(vo.count)
        m.voicedRMS = 10 * log10(vo.map { pow(10, $0 / 10) }.reduce(0, +) / Double(vo.count))
        m.levelStdDev = sqrt(vo.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(vo.count))
        m.loudSoftSpread = vo[Int(Double(vo.count - 1) * 0.9)] - vo[Int(Double(vo.count - 1) * 0.1)]
    }
    let po = pauses.map { outW[$0] }
    if !po.isEmpty { m.pauseLevel = 10 * log10(po.map { pow(10, $0 / 10) }.reduce(0, +) / Double(po.count)) }
    let out = Array(output[0..<n])
    let hf = bandFrameDB(out, lowHz: 5000, highHz: 10000), mid = bandFrameDB(out, lowHz: 1000, highHz: 3000)
    let ratios = zip(hf, mid).filter { $0.1 > -60 }.map { $0.0 - $0.1 }.sorted()
    if !ratios.isEmpty { m.sibilanceP95 = ratios[Int(Double(ratios.count - 1) * 0.95)] }
    return m
}

func describe(_ name: String, _ m: VoiceMetrics) -> String {
    String(format: "%@ | %.1f LUFS | LRA %.1f LU | true peak %.1f dBTP | peak %.1f dBFS | voice %.1f dBFS RMS | level std dev %.1f dB | loud/soft %.1f dB | pauses %.1f dBFS (%.1f dB below voice) | sibilance p95 %+.1f dB | clips %d",
           name, m.integrated, m.lra, m.tp, m.peak, m.voicedRMS, m.levelStdDev, m.loudSoftSpread, m.pauseLevel, m.voicedRMS - m.pauseLevel, m.sibilanceP95, m.clips)
}

/// Renders a saved preset (plugins restored from the file) on a signal and measures it.
@MainActor
func renderPreset(_ p: Preset, input: [Float]) async throws -> (VoiceMetrics, [Float]) {
    var units: [UUID: AVAudioUnit] = [:]
    for n in p.graph.nodes where n.kind == .audioUnit {
        guard let ref = n.plugin else { continue }
        let u = try await PluginHost.instantiate(ref, mode: .inProcess)
        if let st = n.pluginState { PluginHost.restoreState(u, data: st) }
        units[n.id] = u
    }
    let lab = try ChainLab(input: input)
    lab.load(graph: p.graph, units: units)
    if let r = p.routing {
        lab.processor.control.inputGainDB.store(Float(r.inputGainDB ?? 0))
    }
    let rep = lab.run()
    return (metrics(input: input, output: rep.output, report: rep), rep.output)
}
