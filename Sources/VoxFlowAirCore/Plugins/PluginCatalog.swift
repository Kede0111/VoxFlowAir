import Foundation
import AVFoundation

public enum PluginCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case dynamics, eq, filter, saturation, temporal, voice, pitch, utility, analyzer, other
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .dynamics: return String(localized: "Dynamics")
        case .eq: return String(localized: "Equalization")
        case .filter: return String(localized: "Filters")
        case .saturation: return String(localized: "Saturation")
        case .temporal: return String(localized: "Reverb and Time-Based Effects")
        case .voice: return String(localized: "Voice and Noise Reduction")
        case .pitch: return String(localized: "Pitch and Modulation")
        case .utility: return String(localized: "Utilities")
        case .analyzer: return String(localized: "Analyzers")
        case .other: return String(localized: "Other")
        }
    }
    public var symbol: String {
        switch self {
        case .dynamics: return "waveform.path.ecg"
        case .eq: return "slider.vertical.3"
        case .filter: return "line.3.horizontal.decrease"
        case .saturation: return "flame"
        case .temporal: return "dot.radiowaves.left.and.right"
        case .voice: return "mic"
        case .pitch: return "tuningfork"
        case .utility: return "wrench.and.screwdriver"
        case .analyzer: return "chart.bar.xaxis"
        case .other: return "puzzlepiece.extension"
        }
    }
}

/// AU plugin found on the system.
public struct PluginInfo: Identifiable, Hashable, Sendable {
    public var id: String { reference.identifier }
    public let reference: PluginReference
    public internal(set) var category: PluginCategory
    public let channelHint: String?
    public let isMultichannelVariant: Bool
    public let isAUv3: Bool
    public let versionString: String
    public let tags: [String]

    public var name: String { reference.name }
    public var manufacturer: String { reference.manufacturerName }
}

public final class PluginCatalog: @unchecked Sendable {
    public private(set) var plugins: [PluginInfo] = []

    public init() {}

    /// Lists the installed AU effects (aufx and aumf types).
    @discardableResult
    public func scan() -> [PluginInfo] {
        let mgr = AVAudioUnitComponentManager.shared()
        var found: [PluginInfo] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let d = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in mgr.components(matching: d) {
                let acd = c.audioComponentDescription
                if acd.componentManufacturer == fcc("VxFl") { continue } // internal native nodes
                let ref = PluginReference(type: acd.componentType, subType: acd.componentSubType, manufacturer: acd.componentManufacturer,
                                          name: c.name, manufacturerName: c.manufacturerName, version: UInt32(c.version))
                let tags = c.allTagNames
                found.append(PluginInfo(reference: ref,
                                        category: Self.categorize(name: c.name, tags: tags),
                                        channelHint: Self.channelHint(c.name),
                                        isMultichannelVariant: Self.isMultichannel(c.name),
                                        isAUv3: acd.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0,
                                        versionString: c.versionString,
                                        tags: tags))
            }
        }
        plugins = found.sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
        vlog(.info, "AU catalog: \(plugins.count) effects (\(plugins.filter { !$0.isMultichannelVariant }.count) mono/stereo)")
        return plugins
    }

    public func info(for ref: PluginReference) -> PluginInfo? {
        plugins.first { $0.reference.type == ref.type && $0.reference.subType == ref.subType && $0.reference.manufacturer == ref.manufacturer }
    }

    /// Costly information (queries to the system registry), to request on demand.
    /// `passesAUVal` reflects the auval validation cached by macOS.
    public func details(for ref: PluginReference) -> (hasCustomView: Bool, passesValidation: Bool)? {
        let mgr = AVAudioUnitComponentManager.shared()
        guard let c = mgr.components(matching: ref.componentDescription).first else { return nil }
        return (c.hasCustomView, c.passesAUVal)
    }

    public func isInstalled(_ ref: PluginReference) -> Bool {
        var d = ref.componentDescription
        return AudioComponentFindNext(nil, &d) != nil
    }

    static func channelHint(_ name: String) -> String? {
        guard let open = name.lastIndex(of: "("), name.hasSuffix(")") else { return nil }
        let inner = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
        return inner.count <= 8 ? inner : nil
    }

    static func isMultichannel(_ name: String) -> Bool {
        let n = name.lowercased()
        let markers = ["(5.", "(6.", "(7.", "(9.", "immersive", "ambix", "fuma", "->4)", "(lcr", "(quad", "(lrc", "(4.0", "(4->", "(5->", "(6->", "(8->", "atmos"]
        return markers.contains { n.contains($0) }
    }

    /// Classification by AU tags, then by keywords in the name (Waves plugins
    /// publish no tags).
    public static func categorize(name: String, tags: [String]) -> PluginCategory {
        // macOS localizes tag names: match English and French stems, ignoring accents.
        let t = tags.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        func tag(_ stems: [String]) -> Bool { t.contains { tag in stems.contains { tag.contains($0) } } }
        if tag(["dynami", "compress", "limit"]) { return .dynamics }
        if t.contains("eq") || tag(["equaliz", "egalis"]) { return .eq }
        if tag(["filter", "filtre"]) { return .filter }
        if tag(["distor", "saturat"]) { return .saturation }
        if tag(["reverb", "delay", "delai", "echo"]) { return .temporal }
        if tag(["pitch", "hauteur", "modulation"]) { return .pitch }
        if tag(["analy", "meter", "metre"]) { return .analyzer }
        if tag(["noise", "bruit", "restor", "restaur"]) { return .voice }

        let n = name.lowercased()
        func has(_ keys: [String]) -> Bool { keys.contains { n.contains($0) } }
        if has(["clarity vx", "ns1", "wns", "x-noise", "z-noise", "x-hum", "x-click", "x-crackle", "deesser", "de-esser", "sibilance", "vocal rider", "voice", "vocal", "dereverb", "x-fdbk", "vx "]) { return .voice }
        if has(["eq", "q10", "puigtec", "api-550", "api-560", "pultec", "f6", "scheps 73", "v-eq", "linear phase", "curves"]) { return .eq }
        if has(["comp", "c1", "c4", "c6", "cla-2a", "cla-3a", "cla-76", "api-2500", "limiter", "l1", "l2", "l3", "mv2", "maxx", "gate", "rider", "dpr-402", "rcomp", "vcomp", "dbx", "fairchild", "kramer pie", "ssl g-master", "ssl channel", "trans-x", "smack", "magma"]) { return .dynamics }
        if has(["reverb", "verb", "chambers", "plate", "rs124", "echo", "delay", "supertap", "doubler", "h-delay", "space", "abbey road reel", "magma springs", "cosmos"]) { return .temporal }
        if has(["filter", "metafilter", "hpf", "lpf", "mondomod"]) { return .filter }
        if has(["saturat", "tube", "distort", "berzerk", "exciter", "aphex", "j37", "kramer master tape", "tape", "vinyl", "drive", "cobalt", "lofi", "lo-fi", "bb tubes", "vitamin"]) { return .saturation }
        if has(["tune", "pitch", "morph", "enigma", "chorus", "flang", "phaser", "doppler", "ultrapitch", "sound shifter", "orchestral", "harmony", "mondo"]) { return .pitch }
        if has(["paz", "meter", "analy", "wlm", "dorrough", "vu", "scope", "spectr"]) { return .analyzer }
        if has(["s1", "inphase", "sub align", "center", "utility", "gain", "trim", "brauer", "stereo", "mono", "imager", "pan", "insert"]) { return .utility }
        return .other
    }
}
