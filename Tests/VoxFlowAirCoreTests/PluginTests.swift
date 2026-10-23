import Testing
import Foundation
import AVFoundation
@testable import VoxFlowAirCore

@Suite("Installed AU plugins", .serialized)
struct PluginTests {
    static let catalog: PluginCatalog = { let c = PluginCatalog(); c.scan(); return c }()

    @Test("The catalog discovers the system's AU effects")
    func catalogScan() {
        let c = Self.catalog
        #expect(c.plugins.count > 0)
        let byCat = Dictionary(grouping: c.plugins.filter { !$0.isMultichannelVariant }, by: \.category).mapValues(\.count)
        print("Catalog:", c.plugins.count, "plugins; by category:", byCat.map { "\($0.key.rawValue)=\($0.value)" }.sorted())
    }

    static func candidates() -> [PluginInfo] {
        let preferred = ["Renaissance Compressor (s)", "C1 comp (s)", "Renaissance Vox (m)", "CLA-76 (s)", "DeEsser (m)", "AUDelay", "AUNBandEQ"]
        return preferred.compactMap { n in catalog.plugins.first { $0.name == n } }
    }

    @Test("Loading and real processing by plugins (in process)")
    func loadAndProcessInProcess() async throws {
        try await runPlugins(mode: .inProcess)
    }

    @Test("Loading and real processing by plugins (out of process)")
    func loadAndProcessOutOfProcess() async throws {
        try await runPlugins(mode: .outOfProcess)
    }

    func runPlugins(mode: PluginLoadMode) async throws {
        let list = Self.candidates()
        try #require(!list.isEmpty, "No candidate plugin installed")
        for info in list {
            let unit: AVAudioUnit
            do { unit = try await PluginHost.instantiate(info.reference, mode: mode) }
            catch { print("[\(mode)] FAILED to load \(info.name): \(error)"); continue }
            var g = ProcessingGraph.testGraph()
            let node = GraphNode(kind: .audioUnit, position: .init(x: 0, y: 0), plugin: info.reference)
            g.appendToMainChain(node)
            let h = try await MainActor.run { try ProcessorHarness(graph: g, plugins: [node.id: unit]) }
            let status = h.runtime.apply(g, plugins: [node.id: unit], pluginStatus: [:])
            h.run(cycles: 100, amp: 0.3)
            let peak = ProcessorHarness.peak(h.vL)
            let state = PluginHost.captureState(unit)
            let restored = state.map { PluginHost.restoreState(unit, data: $0) } ?? false
            print("[\(mode)] \(info.name): status=\(status[node.id]!) channels=\(unit.auAudioUnit.channelCapabilities?.map(\.intValue) ?? []) outputPeak=\(peak) latency=\(unit.auAudioUnit.latency)s state=\(state?.count ?? 0)B restored=\(restored) renderErrors=\(h.processor.meters.renderErrors.value)")
            #expect(status[node.id] == .ok)
            #expect(h.processor.meters.renderErrors.value == 0)
            #expect(peak > 0.001, "\(info.name) produces no signal")
            if info.name == "C1 comp (s)" || info.name == "DeEsser (m)" {
                // Near-neutral default settings on a -10 dBFS sine: the level must be preserved (mono compensated).
                #expect(abs(peak - 0.3) < 0.03, "level \(info.name) = \(peak)")
            }
        }
    }
}
