import Foundation
import Testing
@testable import VoxFlowAirCore

@Suite("Factory presets: save, replace, restore")
@MainActor
struct FactoryPresetTests {
    private func dirs() -> (factory: URL, presets: URL, settings: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-factory-\(UUID().uuidString)")
        let f = root.appendingPathComponent("factory")
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return (f, root.appendingPathComponent("p"), root.appendingPathComponent("s.json"))
    }

    private func writeFactory(_ p: Preset, to dir: URL) throws {
        try PresetMigrator.encode(p).write(to: dir.appendingPathComponent("\(p.name).voxpreset"))
    }

    @Test("Installed once, modified and saved (overwritten), then restored to its original version")
    func modifySaveRestore() throws {
        let d = dirs()
        var factory = Preset(name: "Factory", graph: .testGraph(), routing: PresetRouting(inputGainDB: -2))
        factory.notes = "original"
        try writeFactory(factory, to: d.factory)

        let e = VoxFlowAirEngine(presetDirectory: d.presets, settingsURL: d.settings, factoryPresetsDirectory: d.factory)
        e.launch(startAudio: false)
        #expect(e.presets.contains { $0.id == factory.id }, "installed on first launch")
        e.loadPreset(factory.id)
        #expect(!e.isModifiedFromFactory(factory.id))

        // Modify then “Save”: the preset is overwritten.
        let node = try #require(e.addNode(kind: .gain, appendToChain: true))
        e.setGain(node, db: -9, registerUndo: true)
        e.saveActivePreset()
        #expect(!e.isDirty)
        #expect(e.presetStore.preset(factory.id)?.graph.node(node) != nil, "change saved in the same preset")
        #expect(e.presets.filter { $0.name == "Factory" }.count == 1, "no duplicate")
        #expect(e.isModifiedFromFactory(factory.id))

        // Restore: exact return to the original version, including in the editor.
        e.restoreFactoryVersion(factory.id)
        #expect(e.graph == factory.graph)
        #expect(e.presetStore.preset(factory.id)?.graph == factory.graph)
        #expect(!e.isModifiedFromFactory(factory.id))
        #expect(!e.isDirty)
    }

    @Test("“Save As” to an existing name replaces that preset instead of creating a second one")
    func overwriteByName() throws {
        let d = dirs()
        let e = VoxFlowAirEngine(presetDirectory: d.presets, settingsURL: d.settings, factoryPresetsDirectory: d.factory)
        e.launch(startAudio: false)
        e.newPreset(name: "Studio")
        let studio = try #require(e.activePresetID)
        e.newPreset(name: "Radio")
        let node = try #require(e.addNode(kind: .gain, appendToChain: true))
        let count = e.presets.count
        e.overwritePreset(studio)
        #expect(e.presets.count == count)
        #expect(e.activePresetID == studio)
        #expect(e.presetStore.preset(studio)?.graph.node(node) != nil)
        #expect(!e.isDirty)
    }

    @Test("Deleted factory preset: not reinstalled automatically, but restorable on demand")
    func deletedFactoryPreset() throws {
        let d = dirs()
        let factory = Preset(name: "Factory 2")
        try writeFactory(factory, to: d.factory)
        do {
            let e = VoxFlowAirEngine(presetDirectory: d.presets, settingsURL: d.settings, factoryPresetsDirectory: d.factory)
            e.launch(startAudio: false)
            e.deletePreset(factory.id)
            #expect(e.missingFactoryPresets.map(\.id) == [factory.id])
            e.shutdown()
        }
        let e2 = VoxFlowAirEngine(presetDirectory: d.presets, settingsURL: d.settings, factoryPresetsDirectory: d.factory)
        e2.launch(startAudio: false)
        #expect(!e2.presets.contains { $0.id == factory.id }, "the user's choice is respected")
        e2.restoreMissingFactoryPresets()
        #expect(e2.presets.contains { $0.id == factory.id })
        #expect(e2.missingFactoryPresets.isEmpty)
    }
}
