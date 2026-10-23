import Testing
import Foundation
@testable import VoxFlowAirCore

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("voxflowair-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite("Presets and persistence")
struct PresetTests {
    @Test("Creating, saving and faithfully reloading a preset")
    func roundTrip() throws {
        let dir = tempDir()
        let store = PresetStore(directory: dir)
        var g = ProcessingGraph.testGraph()
        let ref = PluginReference(type: fcc("aufx"), subType: fcc("TEST"), manufacturer: fcc("Fake"), name: "Fake Plugin", manufacturerName: "Test", version: 1)
        let node = GraphNode(kind: .audioUnit, position: .init(x: 10, y: 20), bypassed: true, plugin: ref, pluginState: Data([1, 2, 3, 4]))
        g.appendToMainChain(node)
        g.groups.append(NodeGroup(name: "Dynamics"))
        let p = try store.create(name: "Podcast Voice", graph: g, routing: PresetRouting(inputGainDB: 3, monitorGainDB: -10, inputChannels: [0]))
        let reloaded = PresetStore(directory: dir).load()
        let r = try #require(reloaded.first { $0.id == p.id })
        #expect(r.graph == p.graph)
        #expect(r.routing?.inputChannels == [0])
        #expect(r.graph.node(node.id)?.pluginState == Data([1, 2, 3, 4]), "a missing plugin's state is kept as is")
        #expect(r.graph.node(node.id)?.bypassed == true)
        // Chain order: input → gain → plugin → output.
        let order = try #require(r.graph.topologicalOrder())
        #expect(order.firstIndex(of: node.id)! > order.firstIndex(of: r.graph.inputNode!.id)!)
    }

    @Test("Duplicate, rename, delete (Trash), export and import")
    func operations() throws {
        let dir = tempDir()
        let store = PresetStore(directory: dir)
        let a = try store.create(name: "A")
        let b = try store.duplicate(a.id)
        #expect(b.id != a.id && b.name.contains("copy"))
        try store.rename(b.id, to: "B")
        #expect(store.preset(b.id)?.name == "B")
        let exportURL = dir.appendingPathComponent("export.voxpreset")
        try store.export(b.id, to: exportURL)
        let imported = try store.importPreset(from: exportURL)
        #expect(imported.id != b.id, "a duplicate identifier is replaced")
        #expect(imported.name == "B 2")
        try store.delete(a.id)
        #expect(store.preset(a.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: a.id).path))
    }

    @Test("A corrupted preset is restored from its backup copy")
    func corruptedPresetUsesBackup() throws {
        let dir = tempDir()
        let store = PresetStore(directory: dir)
        var p = try store.create(name: "Saved")
        p.notes = "v2"
        try store.write(p) // creates the .bak
        try Data("{ corrupted".utf8).write(to: store.url(for: p.id))
        let s2 = PresetStore(directory: dir)
        let loaded = s2.load()
        #expect(loaded.contains { $0.id == p.id })
        #expect(!s2.loadErrors.isEmpty)
    }

    @Test("An unreadable preset with no backup is set aside, never deleted")
    func unreadableQuarantined() throws {
        let dir = tempDir()
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("x.voxpreset"))
        let s = PresetStore(directory: dir)
        _ = s.load()
        let q = try FileManager.default.contentsOfDirectory(atPath: s.quarantineDirectory.path)
        #expect(q.count == 1)
    }

    @Test("Newer format version: explicit refusal, no data loss")
    func futureVersion() throws {
        let dir = tempDir()
        let store = PresetStore(directory: dir)
        let p = try store.create(name: "Future")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url(for: p.id))) as! [String: Any]
        json["formatVersion"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: store.url(for: p.id))
        try? FileManager.default.removeItem(at: store.url(for: p.id).appendingPathExtension("bak"))
        let s2 = PresetStore(directory: dir)
        _ = s2.load()
        #expect(s2.loadErrors.contains { $0.contains("v99") })
        #expect(FileManager.default.fileExists(atPath: store.url(for: p.id).path), "the file stays in place")
    }

    @Test("Settings: persistence, missing keys and corrupted file")
    func settings() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("settings.json")
        let st = SettingsStore(url: url)
        var s = AppSettings()
        s.monitorEnabled = true; s.monitorGainDB = -12; s.inputUID = "MIC"; s.latency = .low
        st.save(s)
        #expect(SettingsStore(url: url).load() == s)
        // Missing keys → default values, no failure.
        try Data(#"{"inputUID":"X"}"#.utf8).write(to: url)
        let partial = SettingsStore(url: url).load()
        #expect(partial.inputUID == "X" && partial.monitorGainDB == -6)
        // Corrupted with no backup → defaults + file kept aside.
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        try Data("###".utf8).write(to: url)
        let st3 = SettingsStore(url: url)
        let d = st3.load()
        #expect(d == AppSettings())
        #expect(st3.lastLoadWarning != nil)
    }
}

@Suite("Processing graph")
struct GraphTests {
    @Test("Cycles, self-loops and invalid ports are rejected")
    func invalidConnections() throws {
        var g = ProcessingGraph.testGraph()
        let input = g.inputNode!.id, out = g.outputNode!.id
        let gain = g.nodes.first { $0.kind == .gain }!.id
        #expect(throws: ProcessingGraph.EditError.invalidPorts) { _ = try g.connect(from: gain, to: input) }
        let second = GraphNode(kind: .gain, position: .init(x: 0, y: 0))
        g.addNode(second)
        try g.connect(from: gain, to: second.id)
        #expect(throws: ProcessingGraph.EditError.cycle) { _ = try g.connect(from: second.id, to: gain) }
        #expect(throws: ProcessingGraph.EditError.selfLoop) { _ = try g.connect(from: gain, to: gain) }
        #expect(throws: ProcessingGraph.EditError.invalidPorts) { _ = try g.connect(from: out, to: gain) }
        #expect(throws: ProcessingGraph.EditError.duplicate) { _ = try g.connect(from: input, to: gain) }
    }

    @Test("Reorder: removing a node reconnects its neighbors, inserting on a connection")
    func reorder() throws {
        var g = ProcessingGraph.testGraph()
        let gain = g.nodes.first { $0.kind == .gain }!
        let an = GraphNode(kind: .analyzer, position: .init(x: 0, y: 0))
        let c = g.connections.first { $0.from == gain.id }!
        g.insert(an, on: c.id)
        #expect(g.outgoing(gain.id).first?.to == an.id)
        #expect(g.outgoing(an.id).first?.to == g.outputNode!.id)
        g.removeNode(gain.id)
        #expect(g.outgoing(g.inputNode!.id).first?.to == an.id)
        #expect(GraphValidator.validate(g).filter { $0.severity == .error }.isEmpty)
    }

    @Test("Validation: unconnected output, node off the path, missing plugin")
    func validation() {
        var g = ProcessingGraph.testGraph()
        let stray = GraphNode(kind: .gain, position: .init(x: 0, y: 0))
        g.addNode(stray)
        let issues = GraphValidator.validate(g, missingPlugins: [stray.id])
        #expect(issues.contains { $0.nodeID == stray.id && $0.severity == .info })
        #expect(issues.contains { $0.message.contains("Plugin not found") })
        let outID = g.outputNode!.id
        g.connections.removeAll { $0.to == outID }
        #expect(GraphValidator.validate(g).contains { $0.message.contains("silence") })
    }

    @Test("Categorizing Waves plugins by name")
    func categories() {
        #expect(PluginCatalog.categorize(name: "CLA-76 (s)", tags: []) == .dynamics)
        #expect(PluginCatalog.categorize(name: "Renaissance Equalizer (s)", tags: []) == .eq)
        #expect(PluginCatalog.categorize(name: "Clarity Vx (m)", tags: []) == .voice)
        #expect(PluginCatalog.categorize(name: "Abbey Road Chambers (s)", tags: []) == .temporal)
        #expect(PluginCatalog.isMultichannel("C1 comp (5.1)"))
        #expect(!PluginCatalog.isMultichannel("C1 comp (s)"))
    }
}

@Suite("Analysis")
struct AnalysisTests {
    @Test("BS.1770 loudness: 1 kHz sine at -20 dBFS on two channels ≈ -20 LUFS")
    func loudness() {
        let sr = 48000.0
        let l = SPSCRingBuffer(capacity: 16384), r = SPSCRingBuffer(capacity: 16384)
        let meter = LoudnessMeter(sampleRate: sr)
        meter.update(left: l, right: r)
        var phase = 0.0
        var block = [Float](repeating: 0, count: 2400)
        for _ in 0..<80 { // 4 s
            for i in 0..<block.count { block[i] = Float(sin(phase)) * 0.1; phase += 2 * .pi * 1000 / sr }
            block.withUnsafeBufferPointer { l.write($0.baseAddress!, count: $0.count); r.write($0.baseAddress!, count: $0.count) }
            meter.update(left: l, right: r)
        }
        #expect(abs(meter.momentaryLUFS - (-20)) < 0.5, "M = \(meter.momentaryLUFS)")
        #expect(abs(meter.shortTermLUFS - (-20)) < 0.5, "S = \(meter.shortTermLUFS)")
        #expect(abs(meter.integratedLUFS - (-20)) < 0.5, "I = \(meter.integratedLUFS)")
        #expect(meter.loudnessRange < 1, "LRA = \(meter.loudnessRange)")
        #expect(abs(meter.truePeakDB - (-20)) < 0.6, "TP = \(meter.truePeakDB)")
    }

    @Test("Spectrum: peak at the right frequency")
    func spectrum() {
        let ring = SPSCRingBuffer(capacity: 8192)
        var s = [Float](repeating: 0, count: 8192)
        for i in 0..<s.count { s[i] = Float(sin(2 * .pi * 1000 * Double(i) / 48000)) * 0.5 }
        s.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        let a = SpectrumAnalyzer(size: 4096)
        let db = a.update(from: ring, smoothing: 0)
        let peakBin = db.indices.max { db[$0] < db[$1] }!
        #expect(abs(a.frequency(bin: peakBin, sampleRate: 48000) - 1000) < 24)
    }

    @Test("Correlation: mono = +1, phase inversion = -1")
    func correlation() {
        let l = SPSCRingBuffer(capacity: 8192), r = SPSCRingBuffer(capacity: 8192), r2 = SPSCRingBuffer(capacity: 8192)
        var a = [Float](repeating: 0, count: 4096), b = a
        for i in 0..<a.count { a[i] = Float(sin(Double(i) * 0.05)); b[i] = -a[i] }
        a.withUnsafeBufferPointer { l.write($0.baseAddress!, count: 4096); r.write($0.baseAddress!, count: 4096) }
        b.withUnsafeBufferPointer { r2.write($0.baseAddress!, count: 4096) }
        #expect(stereoCorrelation(left: l, right: r) > 0.99)
        #expect(stereoCorrelation(left: l, right: r2) < -0.99)
    }
}
