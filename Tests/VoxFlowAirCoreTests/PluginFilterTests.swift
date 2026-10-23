import Testing
import Foundation
import AudioToolbox
@testable import VoxFlowAirCore

@Suite("Plugin library filter")
struct PluginFilterTests {
    private func plugin(_ name: String, maker: String, sub: String, type: OSType = kAudioUnitType_Effect,
                        category: PluginCategory = .other, auv3: Bool = false) -> PluginInfo {
        let ref = PluginReference(type: type, subType: fcc(sub), manufacturer: fcc(String(maker.prefix(4)).padding(toLength: 4, withPad: "x", startingAt: 0)),
                                  name: name, manufacturerName: maker, version: 1)
        return PluginInfo(reference: ref, category: category, channelHint: nil, isMultichannelVariant: false,
                          isAUv3: auv3, versionString: "1", tags: [])
    }

    private var sample: [PluginInfo] {
        [plugin("EQ", maker: "Acme", sub: "eqqq", category: .eq),
         plugin("Comp", maker: "Acme", sub: "cmpp", category: .dynamics),
         plugin("Verb", maker: "Other", sub: "verb", category: .temporal),
         plugin("Arp", maker: "Other", sub: "arpp", type: kAudioUnitType_MusicEffect),
         plugin("App FX", maker: "Apps", sub: "appf", auv3: true)]
    }

    @Test("All mode shows everything but hidden plugins")
    func allMode() {
        var f = PluginFilter()
        #expect(f.apply(to: sample).count == 5)
        f.setHidden(sample[1].id, true)
        #expect(f.apply(to: sample).map(\.name) == ["EQ", "Verb", "Arp", "App FX"])
        f.setHidden(sample[1].id, false)
        #expect(f.apply(to: sample).count == 5)
    }

    @Test("Allowlist mode keeps chosen manufacturers and plugins")
    func allowlist() {
        var f = PluginFilter()
        f.mode = .allowlist
        #expect(f.apply(to: sample).isEmpty)
        f.setAllowed(manufacturer: "Acme", true)
        f.setAllowed(plugin: sample[2].id, true)
        #expect(f.apply(to: sample).map(\.name) == ["EQ", "Comp", "Verb"])
        f.setHidden(sample[0].id, true)
        #expect(f.apply(to: sample).map(\.name) == ["Comp", "Verb"], "hidden wins over allowed")
    }

    @Test("AUv3 and music effects can be left out")
    func kinds() {
        var f = PluginFilter()
        f.includeAUv3 = false
        f.includeMusicEffects = false
        #expect(f.apply(to: sample).map(\.name) == ["EQ", "Comp", "Verb"])
    }

    @Test("Category override replaces the automatic category")
    func categoryOverride() {
        var f = PluginFilter()
        f.categoryOverrides[sample[2].id] = .voice
        #expect(f.apply(to: sample).first { $0.name == "Verb" }?.category == .voice)
    }

    @Test("Settings without a filter (older versions) decode with the defaults")
    func decoding() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":1,"inputGainDB":-3}"#.utf8))
        #expect(old.pluginFilter == PluginFilter())
        var s = AppSettings()
        s.pluginFilter.mode = .allowlist
        s.pluginFilter.categoryOverrides["x"] = .eq
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.pluginFilter == s.pluginFilter)
    }

    @Test("Meter monitors: known meters first, then other analyzers")
    func meterList() {
        let wlm = PluginInfo(reference: PluginReference(type: kAudioUnitType_Effect, subType: fcc("WLMS"), manufacturer: fcc("ksWV"),
                                                        name: "WLM Plus (s)", manufacturerName: "Waves", version: 1),
                             category: .analyzer, channelHint: "s", isMultichannelVariant: false, isAUv3: false, versionString: "1", tags: [])
        let spectrum = plugin("Spectrum", maker: "Acme", sub: "spec", category: .analyzer)
        let list = MeterPlugins.available(in: sample + [spectrum, wlm])
        #expect(list.map(\.name) == ["WLM Plus (s)", "Spectrum"])
        #expect(MeterPlugins.summary(for: wlm.reference) != nil)
        #expect(MeterPlugins.summary(for: spectrum.reference) == nil)
    }
}

@Suite("Plugin categories")
struct PluginCategoryTests {
    @Test("Localized Audio Unit tags (English or French) give the same category")
    func localizedTags() {
        #expect(PluginCatalog.categorize(name: "AUHipass", tags: ["Effects", "Filter", "Equalizer"]) == .eq)
        #expect(PluginCatalog.categorize(name: "AUHipass", tags: ["Effets", "Filtre", "Égaliseur"]) == .eq)
        #expect(PluginCatalog.categorize(name: "AUDynamicsProcessor", tags: ["Effets", "Processeur de dynamique"]) == .dynamics)
        #expect(PluginCatalog.categorize(name: "AUMatrixReverb", tags: ["Effets", "Réverbération"]) == .temporal)
    }
}
