import Foundation
import AVFoundation
import VoxFlowAirCore

// Command-line tool (development): plugin audit and tuning, preset building.
// Usage: VoxFlowAirTool find <word> | audit <exact name>... | params <exact name> | probe <plugin> <param> <value>
//        | analyze <wav> | solo <wav> <plugin> <param=value>... | compare <wav> | build-spec <spec.json> --input <wav>

let args = Array(CommandLine.arguments.dropFirst())
let catalog = PluginCatalog()
catalog.scan()

func plugin(_ name: String) -> PluginInfo? { catalog.plugins.first { $0.name == name } }

func runAsync(_ body: @escaping () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { do { try await body() } catch { print("ERROR:", error) }; sem.signal() }
    while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
}

/// Instantiates a plugin and initializes it at 48 kHz to get its actual reported latency.
func load(_ info: PluginInfo, mode: PluginLoadMode = .inProcess) async throws -> AVAudioUnit {
    let u = try await PluginHost.instantiate(info.reference, mode: mode)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: info.name.hasSuffix("(m)") ? 1 : 2)!
    try? u.auAudioUnit.inputBusses[0].setFormat(fmt)
    try? u.auAudioUnit.outputBusses[0].setFormat(fmt)
    u.auAudioUnit.maximumFramesToRender = 4096
    try u.auAudioUnit.allocateRenderResources()
    return u
}

switch args.first {
case "find":
    for p in catalog.plugins where args.dropFirst().allSatisfy({ p.name.localizedCaseInsensitiveContains($0) }) {
        print(p.name, "|", p.manufacturer, p.versionString, "|", p.category.rawValue, "|", p.reference.identifier)
    }
case "audit":
    runAsync {
        for name in args.dropFirst() {
            guard let info = plugin(name) else { print("MISSING:", name); continue }
            let u = try await load(info)
            let au = u.auAudioUnit
            let params = au.parameterTree?.allParameters ?? []
            print(String(format: "%@ | v%@ | latency %.2f ms (%d samples) | tail %.2f s | %d parameters | %d factory presets | channels %@",
                         name, info.versionString, au.latency * 1000, Int((au.latency * 48000).rounded()), au.tailTime,
                         params.count, au.factoryPresets?.count ?? 0, "\(au.channelCapabilities?.map(\.intValue) ?? [])"))
            au.deallocateRenderResources()
        }
    }
case "params":
    runAsync {
        guard let name = args.dropFirst().first, let info = plugin(name) else { print("plugin ?"); return }
        let u = try await load(info)
        for p in u.auAudioUnit.parameterTree?.allParameters ?? [] {
            print(String(format: "[%llu] %@ = %@ (%.3f) [%.3f … %.3f] %@", p.address, p.displayName, p.currentValueString, p.value, p.minValue, p.maxValue,
                         p.valueStrings.map { "{\($0.joined(separator: "|"))}" } ?? ""))
        }
        for fp in u.auAudioUnit.factoryPresets ?? [] { print("factory preset:", fp.number, fp.name) }
    }
case "compare":
    // vftool compare <wav>: measures every saved preset on the same take.
    runAsync {
        let input = try readMono48k(URL(fileURLWithPath: args[1]))
        let store = PresetStore(directory: AppPaths.presets)
        store.load()
        let raw = metrics(input: input, output: input, report: ChainLab.Report())
        print(describe("Raw (unprocessed)", raw).replacingOccurrences(of: "-120.0 LUFS", with: "— LUFS"))
        for p in store.presets {
            let (m, _) = try await renderPreset(p, input: input)
            print(describe(p.name, m))
        }
    }
case "build-spec":
    runAsync { try await buildSpec(Array(args.dropFirst())) }
default:
    print("Usage: VoxFlowAirTool find <word> | audit <name>... | params <name> | probe <plugin> <param> <value> | analyze <wav> | solo <wav> <plugin> <param=value>... | compare <wav> | build-spec <spec.json> --input <wav>")
}

// Parameter diagnostics: vftool probe "<plugin>" "<param>" "<value>"
if args.first == "probe" {
    runAsync {
        let info = plugin(args[1])!
        let u = try await load(info)
        let au = u.auAudioUnit
        print("before:", ParameterSetter.read(au, [args[2]]))
        let a = ParameterSetter.set(au, args[2], args[3])
        print("immediate:", a)
        try await Task.sleep(for: .milliseconds(300))
        print("after 300 ms:", ParameterSetter.read(au, [args[2]]))
        if let p = ParameterSetter.parameter(au, args[2]) { print("address", p.address, "raw value", p.value) }
        let st = PluginHost.captureState(u)!
        let u2 = try await load(info)
        PluginHost.restoreState(u2, data: st)
        try await Task.sleep(for: .milliseconds(300))
        print("restored:", ParameterSetter.read(u2.auAudioUnit, [args[2]]))
    }
}

// Recording analysis: vftool analyze <wav>
if args.first == "analyze" {
    let url = URL(fileURLWithPath: args[1])
    let f = try! AVAudioFile(forReading: url)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: buf)
    let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
    let L = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))
    let R = ch > 1 ? Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n)) : L
    var diff: Float = 0; for i in 0..<n { diff = max(diff, abs(L[i] - R[i])) }
    print(String(format: "Duration %.1f s, %d channels, %.0f Hz; max L/R difference %.6f", Double(n) / f.processingFormat.sampleRate, ch, f.processingFormat.sampleRate, diff))
    let mono = (0..<n).map { (L[$0] + R[$0]) / 2 }
    let pk = mono.map(abs).max() ?? 0
    var frames: [Double] = []
    let fr = 480
    for s in stride(from: 0, to: n - fr, by: fr) { var e = 0.0; for i in s..<(s + fr) { e += Double(mono[i] * mono[i]) }; frames.append(10 * log10(e / Double(fr) + 1e-14)) }
    let sorted = frames.sorted()
    let noise = sorted[sorted.count / 20], p50 = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count) * 0.95)]
    print(String(format: "Peak %.1f dBFS; 10 ms level: noise (p5) %.1f, median %.1f, p95 %.1f dBFS; frames > -50 dBFS: %d %%", linearToDB(pk), noise, p50, p95, frames.filter { $0 > -50 }.count * 100 / frames.count))
    // Spectral profile (active voice) by band.
    let bands: [(String, Double, Double)] = [("40–80", 40, 80), ("80–160", 80, 160), ("160–320", 160, 320), ("320–640", 320, 640), ("640–1250", 640, 1250), ("1.25–2.5k", 1250, 2500), ("2.5–5k", 2500, 5000), ("5–10k", 5000, 10000), ("10–16k", 10000, 16000)]
    let voiced = Set(frames.indices.filter { frames[$0] > p50 - 6 })
    let silent = Set(frames.indices.filter { frames[$0] < noise + 3 })
    var line = "Voice spectrum (relative dB):", nline = "Background noise spectrum (dBFS):"
    var ref = 0.0
    for (i, b) in bands.enumerated() {
        let fd = bandFrameDB(mono, lowHz: b.1, highHz: b.2)
        let v = voiced.compactMap { $0 < fd.count ? fd[$0] : nil }
        let sl = silent.compactMap { $0 < fd.count ? fd[$0] : nil }
        let ve = 10 * log10(v.map { pow(10, $0 / 10) }.reduce(0, +) / Double(max(v.count, 1)))
        let se = 10 * log10(sl.map { pow(10, $0 / 10) }.reduce(0, +) / Double(max(sl.count, 1)))
        if i == 4 { ref = ve }
        line += " \(b.0)=\(String(format: "%.1f", ve))"
        nline += " \(b.0)=\(String(format: "%.1f", se))"
    }
    print(line); print("(reference 640–1250 Hz = \(String(format: "%.1f", ref)) dBFS)"); print(nline)
    // Sibilance: 5–10k / 1–3k ratio on the brightest frames.
    let hf = bandFrameDB(mono, lowHz: 5000, highHz: 10000), mid = bandFrameDB(mono, lowHz: 1000, highHz: 3000)
    let ratios = zip(hf, mid).enumerated().filter { voiced.contains($0.offset) }.map { $0.element.0 - $0.element.1 }.sorted()
    if !ratios.isEmpty { print(String(format: "Sibilance: 5–10k / 1–3k ratio median %.1f dB, p95 %.1f dB, max %.1f dB", ratios[ratios.count / 2], ratios[Int(Double(ratios.count - 1) * 0.95)], ratios.last!)) }
    let lf = bandFrameDB(mono, lowHz: 20, highHz: 90)
    print(String(format: "Plosives / lows < 90 Hz: max %.1f dBFS over 10 ms", lf.max() ?? -120))
}

// Single-plugin test: vftool solo <wav> "<plugin>" "<param=value>"...
if args.first == "solo" {
    runAsync {
        let input = try readMono48k(URL(fileURLWithPath: args[1]))
        let info = plugin(args[2])!
        let u = try await PluginHost.instantiate(info.reference, mode: .inProcess)
        for kv in args.dropFirst(3) { let p = kv.split(separator: "=", maxSplits: 1).map(String.init); print(ParameterSetter.set(u.auAudioUnit, p[0], p[1])) }
        var g = ProcessingGraph.defaultGraph()
        let n = GraphNode(kind: .audioUnit, position: .init(x: 0, y: 0), plugin: info.reference)
        g.appendToMainChain(n)
        let lab = try ChainLab(input: input)
        lab.load(graph: g, units: [n.id: u])
        let r = lab.run()
        print(describe(args[2], metrics(input: input, output: r.output, report: r)))
        print(ParameterSetter.read(u.auAudioUnit, ["Park On", "Rider Fader", "VocalsLoudness", "VADThreshLED", "Graph"]))
    }
}
