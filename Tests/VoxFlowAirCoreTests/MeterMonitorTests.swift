import Testing
import Foundation
import AVFoundation
@testable import VoxFlowAirCore

/// Waves input and output meter monitors: each plugin receives the signal at its metering
/// point, and attaching them does not change the audio sent to apps.
@Suite("Meter monitors (Waves)", .serialized)
struct MeterMonitorTests {
    static let catalog: PluginCatalog = { let c = PluginCatalog(); c.scan(); return c }()

    @Test("Installed Waves meters are recognized")
    func available() {
        let list = MeterPlugins.available(in: Self.catalog.plugins)
        print("Waves meters:", list.map(\.name))
        #expect(list.allSatisfy { $0.category == .analyzer || MeterPlugins.summary(for: $0.reference) != nil })
        #expect(Set(list.map(\.id)).count == list.count, "each meter listed once")
    }

    /// Graph: input → gain -12 dB → output. 1 kHz sine at 0.5 on the input.
    private func harness() throws -> ProcessorHarness {
        var g = ProcessingGraph.testGraph()
        let gid = g.nodes.first { $0.kind == .gain }!.id
        g.nodes[g.index(of: gid)!].parameters["gain"] = -12
        return try ProcessorHarness(graph: g)
    }

    @Test("Input and output: each plugin meters its point, the audio is not changed", arguments: [PluginLoadMode.inProcess, .outOfProcess])
    func feedsRealSignal(mode: PluginLoadMode) async throws {
        let list = MeterPlugins.available(in: Self.catalog.plugins)
        let inInfo = list.first { $0.name.hasPrefix("VU Meter") } ?? list.first
        let outInfo = list.first { $0.name.hasPrefix("WLM Plus") } ?? list.last
        guard let inInfo, let outInfo else { print("No Waves meter: test skipped"); return }
        let inUnit = try await PluginHost.instantiate(inInfo.reference, mode: mode)
        let outUnit = try await PluginHost.instantiate(outInfo.reference, mode: mode)

        // Reference: same signal, no monitor, processed in parallel cycle by cycle.
        let ref = try harness()
        let h = try harness()
        let feeder = MeterMonitorFeeder()
        feeder.setSampleRate(h.sampleRate)
        try feeder.attach(inUnit, tap: MonitorPoint.input.tap(in: h.processor.meters), at: .input)
        try feeder.attach(outUnit, tap: MonitorPoint.output.tap(in: h.processor.meters), at: .output)
        _ = feeder.takeReceivedPeak(.input); _ = feeder.takeReceivedPeak(.output)
        var identical = true
        var inPeak: Float = 0, outPeak: Float = 0
        for c in 0..<200 {
            h.run(cycles: 1); ref.run(cycles: 1)
            if h.vL != ref.vL || h.vR != ref.vR || h.mL != ref.mL { identical = false }
            // Close to real-time pacing (512 samples ≈ 10.7 ms) so the thread can keep up.
            try await Task.sleep(nanoseconds: 2_000_000)
            if c >= 20 { inPeak = max(inPeak, feeder.takeReceivedPeak(.input) ?? 0); outPeak = max(outPeak, feeder.takeReceivedPeak(.output) ?? 0) }
            else { _ = feeder.takeReceivedPeak(.input); _ = feeder.takeReceivedPeak(.output) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        inPeak = max(inPeak, feeder.takeReceivedPeak(.input) ?? 0)
        outPeak = max(outPeak, feeder.takeReceivedPeak(.output) ?? 0)
        let st = (feeder.stats(.input)!, feeder.stats(.output)!)
        print("[\(mode)] \(inInfo.name) (input) received peak \(linearToDB(inPeak)) dB; \(outInfo.name) (output) received peak \(linearToDB(outPeak)) dB; errors \(st.0.renderErrors)/\(st.1.renderErrors); resyncs \(st.0.gaps)/\(st.1.gaps); identical output \(identical)")
        #expect(abs(linearToDB(inPeak) - linearToDB(0.5)) < 0.5, "input: \(linearToDB(inPeak)) dB")
        #expect(abs(linearToDB(outPeak) - (linearToDB(0.5) - 12)) < 0.5, "output: \(linearToDB(outPeak)) dB")
        #expect(st.0.renderErrors == 0 && st.1.renderErrors == 0)
        #expect(identical, "the virtual output changed with the monitors attached")
        feeder.detach(.input); feeder.detach(.output)
    }
}
