import Foundation
import AudioToolbox

/// Which installed Audio Units appear in the plugin library.
public enum PluginSelectionMode: String, Codable, CaseIterable, Sendable {
    /// Every effect Audio Unit registered with macOS, minus the hidden ones.
    case all
    /// Only the manufacturers and plugins the user picked.
    case allowlist
}

/// The user's choice of plugins, saved with the settings.
///
/// The filter only shapes the library and the meter monitor menus: a plugin already
/// used in a preset keeps loading even if it is hidden later.
public struct PluginFilter: Codable, Equatable, Sendable {
    public var mode: PluginSelectionMode = .all
    /// Manufacturer names allowed as a whole (allowlist mode).
    public var allowedManufacturers: [String] = []
    /// Plugins allowed one by one (`PluginReference.identifier`, allowlist mode).
    public var allowedPlugins: [String] = []
    /// Plugins never shown (both modes).
    public var hiddenPlugins: [String] = []
    /// Audio Unit v3 extensions shipped inside apps.
    public var includeAUv3 = true
    /// "Music effect" Audio Units (aumf), which also accept MIDI.
    public var includeMusicEffects = true
    /// Category chosen by the user, by plugin identifier (overrides the automatic one).
    public var categoryOverrides: [String: PluginCategory] = [:]

    public init() {}

    public func allows(_ info: PluginInfo) -> Bool {
        if hiddenPlugins.contains(info.id) { return false }
        if info.isAUv3 && !includeAUv3 { return false }
        if info.reference.type == kAudioUnitType_MusicEffect && !includeMusicEffects { return false }
        switch mode {
        case .all: return true
        case .allowlist: return allowedManufacturers.contains(info.manufacturer) || allowedPlugins.contains(info.id)
        }
    }

    /// Applies the category overrides, then keeps the allowed plugins.
    public func apply(to plugins: [PluginInfo]) -> [PluginInfo] {
        plugins.map { p in
            guard let c = categoryOverrides[p.id], c != p.category else { return p }
            var p = p
            p.category = c
            return p
        }
        .filter(allows)
    }

    public mutating func setHidden(_ id: String, _ hidden: Bool) {
        hiddenPlugins.removeAll { $0 == id }
        if hidden { hiddenPlugins.append(id) }
    }

    public mutating func setAllowed(manufacturer: String, _ allowed: Bool) {
        allowedManufacturers.removeAll { $0 == manufacturer }
        if allowed { allowedManufacturers.append(manufacturer) }
    }

    public mutating func setAllowed(plugin id: String, _ allowed: Bool) {
        allowedPlugins.removeAll { $0 == id }
        if allowed { allowedPlugins.append(id) }
    }

    // Tolerant decoding: a missing or invalid key keeps its default value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PluginFilter()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
        mode = v(.mode, d.mode)
        allowedManufacturers = v(.allowedManufacturers, d.allowedManufacturers)
        allowedPlugins = v(.allowedPlugins, d.allowedPlugins)
        hiddenPlugins = v(.hiddenPlugins, d.hiddenPlugins)
        includeAUv3 = v(.includeAUv3, d.includeAUv3)
        includeMusicEffects = v(.includeMusicEffects, d.includeMusicEffects)
        categoryOverrides = v(.categoryOverrides, d.categoryOverrides)
    }
}

/// Where macOS looks for Audio Units. VoxFlowAir cannot add other folders: Audio Units
/// loaded out of process are instantiated by macOS from its own registry.
public enum AudioUnitLocations {
    public static var userComponents: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/Components", isDirectory: true)
    }
    public static let systemComponents = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components", isDirectory: true)
}
