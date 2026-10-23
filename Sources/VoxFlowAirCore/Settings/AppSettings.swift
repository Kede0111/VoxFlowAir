import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case dark, light, system
    public var displayName: String {
        switch self { case .dark: return String(localized: "Dark"); case .light: return String(localized: "Light"); case .system: return String(localized: "Match macOS") }
    }
}

/// Latency profile: buffer size requested from the device.
public enum LatencyProfile: String, Codable, CaseIterable, Sendable {
    case ultraLow, low, balanced, stable, safe
    public var frames: Int {
        switch self { case .ultraLow: return 64; case .low: return 128; case .balanced: return 256; case .stable: return 512; case .safe: return 1024 }
    }
    public var displayName: String {
        switch self {
        case .ultraLow: return String(localized: "Ultra-Low Latency")
        case .low: return String(localized: "Low Latency")
        case .balanced: return String(localized: "Balanced")
        case .stable: return String(localized: "Stable")
        case .safe: return String(localized: "Maximum Safety")
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = AppSettings.currentVersion

    // Devices (by UID, stable across restarts).
    public var inputUID: String?
    public var inputChannels: [Int] = [0, 1]
    public var virtualUID: String?
    /// Displayed name of "VoxFlowAir Micro" (nil = the driver's default name).
    public var virtualDeviceName: String?
    public var monitorUID: String?
    /// If the chosen headphones disappear, switch (with a message) to the system output.
    public var monitorFallbackToSystem = true
    /// Pause monitoring while an app (FaceTime…) listens to the virtual output and plays on the
    /// headphones: otherwise its echo canceller would remove the voice being sent.
    public var pauseMonitorDuringCalls = true
    /// Mix into the headphones what apps play into BlackHole (call return), when
    /// BlackHole is not the virtual output.
    public var callReturnEnabled = true
    public var callReturnGainDB: Double = 0
    public var sampleRate: Double?
    public var latency: LatencyProfile = .balanced
    /// Custom buffer size (overrides the profile when set).
    public var customBufferFrames: Int?

    // Controls.
    public var engineEnabled = true
    public var monitorEnabled = false
    public var muteVirtual = false
    /// Level-matched bypass (compensates the loudness gap between raw and processed signal).
    public var bypassLevelMatch = true
    public var inputGainDB: Double = 0
    public var virtualGainDB: Double = 0
    public var monitorGainDB: Double = -6

    // Presets and plugins.
    public var activePresetID: UUID?
    /// Factory presets already offered (installed once; never reinstalled automatically if deleted).
    public var factoryPresetsOffered: [UUID] = []
    public var pluginLoadMode: PluginLoadMode = .outOfProcess
    public var favoritePlugins: [String] = []
    public var recentPlugins: [String] = []
    public var showMultichannelPlugins = false
    public var pluginFilter = PluginFilter()

    // Interface.
    public var appearance: AppearanceMode = .dark
    public var showWindowAtLaunch = true
    public var lockEditing = false

    public init() {}

    public var bufferFrames: Int { customBufferFrames ?? latency.frames }

    // Tolerant decoding: a missing or invalid key takes its default value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
        version = v(.version, d.version)
        inputUID = v(.inputUID, d.inputUID)
        inputChannels = v(.inputChannels, d.inputChannels)
        virtualUID = v(.virtualUID, d.virtualUID)
        virtualDeviceName = v(.virtualDeviceName, d.virtualDeviceName)
        monitorUID = v(.monitorUID, d.monitorUID)
        monitorFallbackToSystem = v(.monitorFallbackToSystem, d.monitorFallbackToSystem)
        pauseMonitorDuringCalls = v(.pauseMonitorDuringCalls, d.pauseMonitorDuringCalls)
        callReturnEnabled = v(.callReturnEnabled, d.callReturnEnabled)
        callReturnGainDB = v(.callReturnGainDB, d.callReturnGainDB)
        sampleRate = v(.sampleRate, d.sampleRate)
        latency = v(.latency, d.latency)
        customBufferFrames = v(.customBufferFrames, d.customBufferFrames)
        engineEnabled = v(.engineEnabled, d.engineEnabled)
        monitorEnabled = v(.monitorEnabled, d.monitorEnabled)
        muteVirtual = v(.muteVirtual, d.muteVirtual)
        bypassLevelMatch = v(.bypassLevelMatch, d.bypassLevelMatch)
        inputGainDB = v(.inputGainDB, d.inputGainDB)
        virtualGainDB = v(.virtualGainDB, d.virtualGainDB)
        monitorGainDB = v(.monitorGainDB, d.monitorGainDB)
        activePresetID = v(.activePresetID, d.activePresetID)
        factoryPresetsOffered = v(.factoryPresetsOffered, d.factoryPresetsOffered)
        pluginLoadMode = v(.pluginLoadMode, d.pluginLoadMode)
        favoritePlugins = v(.favoritePlugins, d.favoritePlugins)
        recentPlugins = v(.recentPlugins, d.recentPlugins)
        showMultichannelPlugins = v(.showMultichannelPlugins, d.showMultichannelPlugins)
        pluginFilter = v(.pluginFilter, d.pluginFilter)
        appearance = v(.appearance, d.appearance)
        showWindowAtLaunch = v(.showWindowAtLaunch, d.showWindowAtLaunch)
        lockEditing = v(.lockEditing, d.lockEditing)
    }
}

/// Robust reading / writing of the preferences (atomic JSON + .bak).
public final class SettingsStore: @unchecked Sendable {
    public let url: URL
    public private(set) var lastLoadWarning: String?

    public init(url: URL = AppPaths.settings) { self.url = url }

    public func load() -> AppSettings {
        lastLoadWarning = nil
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return AppSettings() }
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: data) { return s }
        let bak = url.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: bak), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            lastLoadWarning = String(localized: "Preferences were unreadable: the backup copy was used.")
            vlog(.warning, lastLoadWarning!)
            return s
        }
        // Keep the faulty file for diagnostics, then start again from the defaults.
        let broken = url.deletingLastPathComponent().appendingPathComponent("settings-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? fm.moveItem(at: url, to: broken)
        lastLoadWarning = String(localized: "Preferences were unreadable: default values are used (old file: \(broken.lastPathComponent)).")
        vlog(.error, lastLoadWarning!)
        return AppSettings()
    }

    public func save(_ s: AppSettings) {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(s)
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                let bak = url.appendingPathExtension("bak")
                try? fm.removeItem(at: bak)
                try? fm.copyItem(at: url, to: bak)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            vlog(.error, "Saving preferences: \(error)")
        }
    }
}
