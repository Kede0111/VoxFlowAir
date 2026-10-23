import Testing
import Foundation
import AVFoundation
@testable import VoxFlowAirCore

@Suite("Engine: robustness", .serialized)
@MainActor
struct EngineTests {
    init() { setenv("VOXFLOWAIR_SUPPORT_DIR", tempDir().path, 1) }

    @Test("Missing plugin: the node passes audio through and its settings are kept")
    func missingPluginPassthrough() throws {
        var g = ProcessingGraph.testGraph()
        let ref = PluginReference(type: fcc("aufx"), subType: fcc("NONE"), manufacturer: fcc("Nope"), name: "Nonexistent", manufacturerName: "X", version: 1)
        let node = GraphNode(kind: .audioUnit, position: .init(x: 0, y: 0), plugin: ref, pluginState: Data([9, 9]))
        g.appendToMainChain(node)
        let h = try ProcessorHarness(graph: g)
        let status = h.runtime.apply(g, plugins: [:], pluginStatus: [node.id: .missing])
        #expect(status[node.id] == .missing)
        h.run()
        #expect(approx(ProcessorHarness.peak(h.vL), 0.5))
        #expect(GraphValidator.validate(g, missingPlugins: [node.id]).contains { $0.nodeID == node.id })
    }

    @Test("Plugin load error: clear message, no crash")
    func pluginLoadError() async {
        let ref = PluginReference(type: fcc("aufx"), subType: fcc("NONE"), manufacturer: fcc("Nope"), name: "Nonexistent", manufacturerName: "X", version: 1)
        await #expect(throws: RuntimeError.self) { _ = try await PluginHost.instantiate(ref, mode: .inProcess) }
    }

    @Test("Missing device: clear error when creating the aggregate device")
    func missingDevice() {
        let b = AggregateDeviceBuilder()
        #expect(throws: CoreAudioError.self) { _ = try b.create(.init(inputUID: "voxflowair.nonexistent", virtualUID: nil, monitorUID: nil)) }
        #expect(b.deviceID == 0)
    }

    @Test("Engine without audio: editing, undo, saving and reloading the preset")
    func engineEditing() throws {
        let dir = tempDir()
        let e = VoxFlowAirEngine(presetDirectory: dir.appendingPathComponent("p"), settingsURL: dir.appendingPathComponent("s.json"))
        e.launch(startAudio: false)
        let initial = e.graph.nodes.count
        let id = try #require(e.addNode(kind: .gain, appendToChain: true))
        #expect(e.graph.nodes.count == initial + 1)
        #expect(e.isDirty)
        e.setGain(id, db: -9, registerUndo: true)
        e.saveActivePreset()
        #expect(!e.isDirty)
        e.undo()
        #expect(e.graph.node(id)?.parameters["gain"] == 0)
        e.loadPreset(e.activePresetID!)
        #expect(e.graph.node(id)?.parameters["gain"] == -9, "the reloaded preset contains the saved value")
        e.removeNode(id)
        #expect(e.graph.node(id) == nil)
        #expect(GraphValidator.validate(e.graph).filter { $0.severity == .error }.isEmpty)
        // Commands are passed on to the audio thread.
        e.settings.muteVirtual = true
        e.settings.monitorEnabled = true
        e.bypassProcessing = true
        #expect(e.processor.control.muteVirtual.value && e.processor.control.monitorEnabled.value && e.processor.control.bypass.value)
        e.shutdown()
    }
}
