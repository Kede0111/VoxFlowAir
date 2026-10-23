import Testing
import Foundation
import AVFoundation
@testable import VoxFlowAirCore

@Suite("Real-time engine (rendering without hardware)", .serialized)
struct ProcessorTests {
    @Test("The default graph actually passes the signal to the virtual output")
    func passthrough() throws {
        let h = try ProcessorHarness()
        h.run()
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5), "virtual peak = \(ProcessorHarness.peak(h.vL))")
        #expect(h.processor.meters.renderErrors.value == 0)
    }

    @Test("The Gain node actually changes the level (-6 dB)")
    func gainNode() throws {
        var g = ProcessingGraph.testGraph()
        let gid = g.nodes.first { $0.kind == .gain }!.id
        g.nodes[g.index(of: gid)!].parameters["gain"] = -6.0206
        let h = try ProcessorHarness(graph: g)
        h.run()
        #expect(approx(ProcessorHarness.peak(h.vL), 0.25), "peak = \(ProcessorHarness.peak(h.vL))")
    }

    @Test("Bypass Processing outputs the unprocessed signal")
    func bypass() throws {
        var g = ProcessingGraph.testGraph()
        let gid = g.nodes.first { $0.kind == .gain }!.id
        g.nodes[g.index(of: gid)!].parameters["gain"] = -20
        let h = try ProcessorHarness(graph: g)
        h.run()
        #expect(approx(ProcessorHarness.peak(h.vL), 0.05, tol: 0.01))
        h.processor.control.bypass.value = true
        h.run()
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5), "bypass peak = \(ProcessorHarness.peak(h.vL))")
    }

    @Test("Level-matched bypass: the correction only applies to the unprocessed signal")
    func bypassLevelMatch() throws {
        let h = try ProcessorHarness()
        h.processor.control.bypassMatchDB.store(6.0206)
        h.run()
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5), "processed unchanged: \(ProcessorHarness.peak(h.vL))")
        h.processor.control.bypass.value = true
        h.run(amp: 0.25)
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5), "raw corrected by +6 dB: \(ProcessorHarness.peak(h.vL))")
    }

    @Test("Mute Output mutes the virtual output without muting monitoring")
    func muteIndependentOfMonitor() throws {
        let h = try ProcessorHarness()
        h.processor.control.monitorEnabled.value = true
        h.processor.control.monitorGainDB.store(0)
        h.processor.control.muteVirtual.value = true
        h.run()
        #expect(ProcessorHarness.peak(h.vL) < 0.0001)
        #expect(approx(ProcessorHarness.peak(h.mL), 0.5))
    }

    @Test("Monitoring off = silent headphones, virtual output intact")
    func monitorIndependent() throws {
        let h = try ProcessorHarness()
        h.processor.control.monitorEnabled.value = false
        h.run()
        #expect(ProcessorHarness.peak(h.mL) < 0.0001)
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5))
        h.processor.control.monitorEnabled.value = true
        h.processor.control.monitorGainDB.store(-6.0206)
        h.run()
        #expect(approx(ProcessorHarness.peak(h.mL), 0.25))
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5))
    }

    @Test("Clipping detection on the input")
    func clipping() throws {
        let h = try ProcessorHarness()
        h.run(amp: 1.2)
        #expect(h.processor.meters.input.clipCount.value > 0)
        #expect(ProcessorHarness.peak(h.vL) <= 1.0)
    }

    @Test("Parallel branches: two gains summed at the output")
    func parallelBranches() throws {
        var g = ProcessingGraph()
        let input = GraphNode(kind: .input, position: .init(x: 0, y: 0))
        let a = GraphNode(kind: .gain, position: .init(x: 1, y: 0), parameters: ["gain": -6.0206])
        let b = GraphNode(kind: .gain, position: .init(x: 1, y: 1), parameters: ["gain": -6.0206])
        let out = GraphNode(kind: .output, position: .init(x: 2, y: 0))
        g.nodes = [input, a, b, out]
        try g.connect(from: input.id, to: a.id)
        try g.connect(from: input.id, to: b.id)
        try g.connect(from: a.id, to: out.id)
        try g.connect(from: b.id, to: out.id)
        let h = try ProcessorHarness(graph: g)
        h.run()
        // 0.25 + 0.25 = 0.5
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5), "peak = \(ProcessorHarness.peak(h.vL))")
    }

    @Test("Dedicated monitoring node: the headphones listen to a different point than the output")
    func dedicatedMonitorTap() throws {
        var g = ProcessingGraph()
        let input = GraphNode(kind: .input, position: .init(x: 0, y: 0))
        let gain = GraphNode(kind: .gain, position: .init(x: 1, y: 0), parameters: ["gain": -20])
        let out = GraphNode(kind: .output, position: .init(x: 2, y: 0))
        let mon = GraphNode(kind: .monitorOutput, position: .init(x: 2, y: 1))
        g.nodes = [input, gain, out, mon]
        try g.connect(from: input.id, to: gain.id)
        try g.connect(from: gain.id, to: out.id)
        try g.connect(from: input.id, to: mon.id) // headphones = signal before the gain
        let h = try ProcessorHarness(graph: g)
        h.processor.control.monitorEnabled.value = true
        h.processor.control.monitorGainDB.store(0)
        h.run()
        #expect(approx(ProcessorHarness.peak(h.vL), 0.05, tol: 0.01), "virtual = \(ProcessorHarness.peak(h.vL))")
        #expect(approx(ProcessorHarness.peak(h.mL), 0.5), "monitor = \(ProcessorHarness.peak(h.mL))")
    }

    @Test("Live reconfiguration: no stall, signal comes back")
    func liveRewire() throws {
        let h = try ProcessorHarness()
        h.run()
        var g = ProcessingGraph.testGraph()
        g.appendToMainChain(GraphNode(kind: .gain, position: .init(x: 0, y: 0), parameters: ["gain": -6.0206]))
        _ = h.runtime.apply(g, plugins: [:], pluginStatus: [:])
        h.run()
        #expect(h.processor.isGraphReady)
        #expect(approx(ProcessorHarness.peak(h.vL), 0.25), "peak = \(ProcessorHarness.peak(h.vL))")
    }

    @Test("Measured levels come from the real signal")
    func metersAreReal() throws {
        let h = try ProcessorHarness()
        _ = h.processor.meters.input.read()
        h.run(amp: 0.3)
        let r = h.processor.meters.input.read()
        #expect(approx(r.peakL, 0.3))
        #expect(approx(r.rmsL, 0.3 / sqrt(2), tol: 0.02))
        h.run(amp: 0)
        _ = h.processor.meters.input.read()
        h.run(amp: 0)
        #expect(h.processor.meters.input.read().peakL < 0.0001)
    }
}
