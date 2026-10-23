import Foundation

/// Detection of the virtual output driver (BlackHole, a GPL-3.0 open-source project
/// by Existential Audio: https://github.com/ExistentialAudio/BlackHole).
public enum VirtualDeviceSupport {
    public static let halDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL")
    public static let officialURL = URL(string: "https://existential.audio/blackhole/")!
    public static let sourceURL = URL(string: "https://github.com/ExistentialAudio/BlackHole")!
    public static let brewCommand = "brew install --cask blackhole-2ch"
    public static let brewUninstallCommand = "brew uninstall --cask blackhole-2ch"

    public static func isBlackHole(uid: String, name: String) -> Bool {
        uid.hasPrefix("BlackHole") || name.hasPrefix("BlackHole")
    }

    public struct DriverInfo: Sendable, Equatable {
        public let bundleURL: URL
        public let name: String
        public let version: String
        public let bundleIdentifier: String
    }

    /// BlackHole drivers present on disk (whether or not coreaudiod has loaded them).
    public static func installedDrivers() -> [DriverInfo] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: halDirectory, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.lastPathComponent.hasPrefix("BlackHole") && $0.pathExtension == "driver" }.compactMap { url in
            let b = Bundle(url: url)
            return DriverInfo(bundleURL: url,
                              name: url.deletingPathExtension().lastPathComponent,
                              version: b?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                              bundleIdentifier: b?.bundleIdentifier ?? "?")
        }
    }

    public enum Status: Equatable, Sendable {
        /// Driver installed and device published by Core Audio.
        case available(deviceName: String, driverVersion: String?)
        /// .driver file present but no visible device (coreaudiod needs a restart).
        case installedNotLoaded(driverVersion: String)
        case notInstalled
    }

    public static func status(devices: [AudioDevice]) -> Status {
        let drivers = installedDrivers()
        if let dev = devices.first(where: { isBlackHole(uid: $0.uid, name: $0.name) && $0.hasOutput }) {
            return .available(deviceName: dev.name, driverVersion: drivers.first?.version)
        }
        if let d = drivers.first { return .installedNotLoaded(driverVersion: d.version) }
        return .notInstalled
    }
}
