import Foundation
import CoreAudio

/// VoxFlowAir's own virtual audio driver (Driver/VoxFlowAirDriver, AudioServerPlugIn).
///
/// It publishes two devices that share a clock:
/// - "VoxFlowAir Micro": visible stereo input, picked as the microphone in OBS, FaceTime…;
/// - "VoxFlowAir Source (internal)": hidden stereo output, fed by VoxFlowAir.
///
/// The identifiers must stay identical to Driver/Shared/VoxFlowAirDriverShared.h
/// (checked by the tests).
public enum VoxFlowAirDriverSupport {
    public static let micUID = AppIdentity.driverBundleID + ".mic"
    public static let feedUID = AppIdentity.driverBundleID + ".feed"
    public static let micName = "VoxFlowAir Micro"
    public static let feedName = "VoxFlowAir Source (internal)"
    public static let bundleIdentifier = AppIdentity.driverBundleID
    public static let bundleName = "VoxFlowAirDriver.driver"
    /// Driver-specific property: stream state (CFDictionary).
    static let statusSelector: AudioObjectPropertySelector = 0x76667374 // 'vfst'
    /// Driver-specific property: displayed microphone name (CFString, settable).
    static let micNameSelector: AudioObjectPropertySelector = 0x76666E6D // 'vfnm'

    public static var installedURL: URL { VirtualDeviceSupport.halDirectory.appendingPathComponent(bundleName) }

    /// Driver embedded in VoxFlowAir.app (Contents/Resources/Driver), installable by the script.
    public static var embeddedURL: URL? {
        let u = Bundle.main.resourceURL?.appendingPathComponent("Driver/\(bundleName)")
        return u.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    public static func bundleVersion(at url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public static var installedVersion: String? {
        FileManager.default.fileExists(atPath: installedURL.path) ? bundleVersion(at: installedURL) ?? "?" : nil
    }

    /// Translates a UID into a device, including a hidden device
    /// (missing from kAudioHardwarePropertyDevices).
    public static func deviceID(uid: String) -> AudioObjectID? {
        var address = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    public enum Status: Equatable, Sendable {
        /// Both devices are published by Core Audio.
        case available(version: String?)
        /// The bundle is installed but coreaudiod has not loaded it (yet).
        case installedNotLoaded(version: String)
        case notInstalled

        public var isAvailable: Bool { if case .available = self { return true }; return false }
    }

    public static func status() -> Status {
        let v = installedVersion
        if deviceID(uid: micUID) != nil, deviceID(uid: feedUID) != nil { return .available(version: v) }
        if let v { return .installedNotLoaded(version: v) }
        return .notInstalled
    }

    /// Internal driver state (clients, frames written/read/valid, gaps, sample rate).
    public static func driverState() -> [String: Any]? {
        guard let id = deviceID(uid: micUID) else { return nil }
        var address = CA.address(statusSelector)
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var dict: Unmanaged<CFDictionary>?
        let st = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &dict)
        guard st == noErr, let d = dict?.takeRetainedValue() else { return nil }
        return d as? [String: Any]
    }

    /// Name currently shown by "VoxFlowAir Micro" (nil if the driver is not loaded).
    public static func currentMicName() -> String? {
        deviceID(uid: micUID).flatMap { CA.getString($0, kAudioObjectPropertyName) }
    }

    /// Valid name for the driver: whitespace trimmed, 1 to 63 characters, otherwise nil.
    public static func sanitizedName(_ name: String?) -> String? {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, n.count <= 63 else { return nil }
        return n
    }

    /// Renames "VoxFlowAir Micro" for every app. The UID does not change:
    /// OBS, FaceTime… keep their setting. Returns false if the driver refuses or is missing.
    @discardableResult
    public static func setMicName(_ name: String) -> Bool {
        guard let n = sanitizedName(name), let id = deviceID(uid: micUID) else { return false }
        // kAudioObjectPropertyName cannot be set through the HAL: use the driver's own property.
        var address = CA.address(micNameSelector)
        var cf = n as CFString
        let st = withUnsafePointer(to: &cf) { AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), $0) }
        return st == noErr
    }

    public static func isFeed(uid: String) -> Bool { uid == feedUID }
    public static func isMic(uid: String) -> Bool { uid == micUID }

    /// Input device on which an app reads back what VoxFlowAir writes to `virtualUID`:
    /// the same device for BlackHole, "VoxFlowAir Micro" for the VoxFlowAir driver.
    public static func loopbackInputUID(forVirtual virtualUID: String) -> String {
        isFeed(uid: virtualUID) ? micUID : virtualUID
    }

    /// True if picking `inputUID` as VoxFlowAir's microphone would create an audio loop
    /// (VoxFlowAir would read back its own virtual output).
    public static func wouldLoop(inputUID: String, virtualUID: String?) -> Bool {
        if isMic(uid: inputUID) || isFeed(uid: inputUID) { return true }
        guard let v = virtualUID else { return false }
        return loopbackInputUID(forVirtual: v) == inputUID
    }
}
