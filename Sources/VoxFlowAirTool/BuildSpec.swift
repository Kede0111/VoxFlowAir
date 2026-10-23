import Foundation
import AVFoundation
import VoxFlowAirCore

/// Builds a preset from a JSON description (plugin chain + displayed settings).
///
///     VoxFlowAirTool build-spec <spec.json> --input <take.wav> [--out render.wav] [--report report.json]
///                            [--write] [--export <folder>]
///
/// The chain runs offline through the same classes as the app (GraphRuntime +
/// RealtimeProcessor, 256-sample blocks at 48 kHz). Detailed analysis of the render (spectrum,
/// comparison with a reference) is done separately on the file written by --out.
struct ChainSpec: Codable {
    struct Step: Codable {
        /// Exact AU plugin name (e.g. “Q10 (m)”), or absent for a native VoxFlowAir gain.
        var plugin: String?
        var title: String
        var role: String?
        /// Settings by parameter name and displayed value, applied in order.
        var settings: [[String]]?
        /// Native gain (dB), if `plugin` is absent.
        var gain: Double?
        var bypassed: Bool?
    }
    var name: String
    var id: UUID
    var notes: String?
    var bufferFrames: Int?
    var steps: [Step]
}

struct SpecReport: Codable {
    struct StepReport: Codable {
        var title: String
        var plugin: String?
        var version: String?
        var latencyMs: Double
        var voiceRMS: Double
        var applied: [String: String]
        var mismatches: [String]
    }
    var steps: [StepReport] = []
    var pluginLatencyMs = 0.0
    var integratedLUFS = -120.0, lra = 0.0, truePeak = -120.0, samplePeak = -120.0, shortTermMax = -120.0
    var clips = 0
    var renderSeconds = 0.0
}

extension ChainLab {
    /// Builds the graph Input → steps → Virtual output (one step = plugin or native gain).
    func build(spec: ChainSpec, units loaded: [Int: AVAudioUnit]) -> [UUID] {
        graph = ProcessingGraph()
        let inNode = GraphNode(kind: .input, position: .init(x: 60, y: 60))
        graph.nodes = [inNode]
        var prev = inNode.id
        var ids: [UUID] = []
        for (i, s) in spec.steps.enumerated() {
            var n: GraphNode
            if let name = s.plugin, let info = PluginCatalog.shared.info(name: name) {
                n = GraphNode(kind: .audioUnit, title: s.title, position: .init(x: 0, y: 0), plugin: info.reference)
                n.loadMode = .inProcess
                units[n.id] = loaded[i]
            } else {
                n = GraphNode(kind: .gain, title: s.title, position: .init(x: 0, y: 0), parameters: ["gain": s.gain ?? 0])
            }
            n.bypassed = s.bypassed ?? false
            graph.nodes.append(n)
            _ = try? graph.connect(from: prev, to: n.id)
            prev = n.id
            ids.append(n.id)
        }
        let out = GraphNode(kind: .output, position: .init(x: 0, y: 0))
        graph.nodes.append(out)
        _ = try? graph.connect(from: prev, to: out.id)
        graph.arrangeMainChain(rowWidth: 1100)
        runtime.apply(graph, plugins: units, pluginStatus: [:])
        return ids
    }
}

@MainActor
func buildSpec(_ args: [String]) async throws {
    guard let specPath = args.first, let inputPath = opt(args, "--input") else {
        throw RuntimeError("Usage: build-spec <spec.json> --input <take.wav> [--out render.wav] [--report r.json] [--write] [--export folder]")
    }
    let spec = try JSONDecoder().decode(ChainSpec.self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
    let write = args.contains("--write"), exportDir = opt(args, "--export")

    // 1. Real plugins, set by displayed values.
    // Waves plugins only show the new value after a render, so the applied values
    // are checked after the render (see below).
    var loaded: [Int: AVAudioUnit] = [:]
    for (i, s) in spec.steps.enumerated() {
        guard let name = s.plugin else { continue }
        guard let info = PluginCatalog.shared.info(name: name) else { throw RuntimeError("Plugin missing: \(name)") }
        let u = try await PluginHost.instantiate(info.reference, mode: .inProcess)
        for kv in s.settings ?? [] where kv.count == 2 { ParameterSetter.set(u.auAudioUnit, kv[0], kv[1]) }
        loaded[i] = u
    }

    // 2. Render.
    let input = try readMono48k(URL(fileURLWithPath: inputPath))
    let lab = try ChainLab(input: input)
    let ids = lab.build(spec: spec, units: loaded)
    let t0 = Date()
    let r = lab.run()
    var rep = SpecReport()
    rep.renderSeconds = Date().timeIntervalSince(t0)
    rep.integratedLUFS = r.outIntegrated.isFinite ? r.outIntegrated : -120
    rep.lra = r.outLRA; rep.truePeak = r.outTP.isFinite ? r.outTP : -120
    rep.samplePeak = Double(linearToDB(r.outPeak)); rep.shortTermMax = r.outShortMax; rep.clips = r.outClips
    for (i, s) in spec.steps.enumerated() {
        let u = loaded[i]
        let lat = (u?.auAudioUnit.latency ?? 0) * 1000
        rep.pluginLatencyMs += lat
        let applied = u.map { ParameterSetter.read($0.auAudioUnit, (s.settings ?? []).map { $0[0] }) } ?? [:]
        let mismatches = (s.settings ?? []).compactMap { kv -> String? in
            guard let shown = applied[kv[0]] else { return "\(kv[0]) not found" }
            if kv[1].hasPrefix("raw:") { return nil }
            if shown.caseInsensitiveCompare(kv[1]) == .orderedSame { return nil }
            if let a = ParameterSetter.number(shown), let b = ParameterSetter.number(kv[1]), abs(a - b) <= max(0.06 * abs(b), 0.11) { return nil }
            return "\(kv[0]) = \(shown) (requested \(kv[1]))"
        }
        rep.steps.append(.init(title: s.title, plugin: s.plugin, version: s.plugin.flatMap { PluginCatalog.shared.info(name: $0)?.versionString },
                               latencyMs: lat, voiceRMS: r.stageRMS[ids[i]] ?? -120, applied: applied, mismatches: mismatches))
    }
    if let out = opt(args, "--out") { try writeWav(r.output, to: URL(fileURLWithPath: out)) }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let repData = try enc.encode(rep)
    if let rp = opt(args, "--report") { try repData.write(to: URL(fileURLWithPath: rp)) }
    print(String(format: "%@: %.1f LUFS, LRA %.1f LU, true peak %.1f dBTP, peak %.1f dBFS, clips %d, plugin latency %.2f ms",
                 spec.name, rep.integratedLUFS, rep.lra, rep.truePeak, rep.samplePeak, rep.clips, rep.pluginLatencyMs))
    for s in rep.steps {
        print(String(format: "  %-40@ %6.1f dBFS  %5.2f ms", s.title as NSString, s.voiceRMS, s.latencyMs) + (s.mismatches.isEmpty ? "" : "  ⚠︎ " + s.mismatches.joined(separator: " ; ")))
    }

    guard write else { return }

    // 3. Save: full plugin states, order, bypass, routing (buffer 256 by default).
    var g = lab.graph
    for (i, id) in ids.enumerated() {
        guard let u = loaded[i], let k = g.index(of: id) else { continue }
        g.nodes[k].pluginState = PluginHost.captureState(u)
    }
    g.viewport = GraphViewport()
    let store = PresetStore(directory: AppPaths.presets)
    store.load()
    if let other = store.presets.first(where: { $0.name == spec.name && $0.id != spec.id }) {
        throw RuntimeError("Another preset is already named “\(spec.name)” (\(other.id)): nothing was overwritten.")
    }
    var preset = store.preset(spec.id) ?? Preset(id: spec.id, name: spec.name)
    preset.name = spec.name
    preset.graph = g
    preset.routing = PresetRouting(inputGainDB: 0, virtualGainDB: 0, monitorGainDB: nil, inputChannels: [0, 1], bufferFrames: spec.bufferFrames ?? 256)
    preset.notes = spec.notes
    try store.write(preset)
    print("Preset saved: \(store.url(for: preset.id).path)")
    if let dir = exportDir {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(spec.name.replacingOccurrences(of: "—", with: "-") + ".voxpreset")
        try store.export(preset.id, to: dest)
        print("Exported copy: \(dest.path)")
    }

    // 4. Check: reload from disk, restore into fresh instances.
    let reloaded = PresetStore(directory: AppPaths.presets)
    reloaded.load()
    guard let p2 = reloaded.preset(preset.id) else { throw RuntimeError("Preset not found after reloading") }
    print("Graph identical after reload: \(p2.graph == g ? "yes" : "NO")")
    var allOK = p2.graph == g
    for (i, s) in spec.steps.enumerated() {
        guard s.plugin != nil else { continue }
        guard let n = p2.graph.node(ids[i]), let ref = n.plugin, let st = n.pluginState else { print("• \(s.title): state missing"); allOK = false; continue }
        let fresh = try await PluginHost.instantiate(ref, mode: .inProcess)
        let restored = PluginHost.restoreState(fresh, data: st)
        let names = (s.settings ?? []).map { $0[0] }
        let now = ParameterSetter.read(fresh.auAudioUnit, names)
        let diffs = names.filter { now[$0] != rep.steps[i].applied[$0] }
        allOK = allOK && restored && diffs.isEmpty
        print("• \(s.title): state restored \(restored ? "yes" : "NO"), \(names.count - diffs.count)/\(names.count) parameters identical"
              + (diffs.isEmpty ? "" : " — differences: " + diffs.map { "\($0) \(rep.steps[i].applied[$0] ?? "?")→\(now[$0] ?? "?")" }.joined(separator: ", ")))
    }
    // Render of the reloaded preset (fresh restored instances): must match the build render.
    let (m2, out2) = try await renderPreset(p2, input: input)
    let n = min(out2.count, r.output.count)
    var diffMax: Float = 0
    for k in 0..<n { diffMax = max(diffMax, abs(out2[k] - r.output[k])) }
    print(String(format: "Reloaded preset render: %.1f LUFS; max difference from the build render %.1f dBFS", m2.integrated, linearToDB(diffMax)))
    print(allOK ? "RESULT: preset saved and restored identically." : "RESULT: differences on restore (see above).")
}
