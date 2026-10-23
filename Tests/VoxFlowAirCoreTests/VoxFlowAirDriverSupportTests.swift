import Foundation
import Testing
@testable import VoxFlowAirCore

@Suite("VoxFlowAir driver (app side)")
struct VoxFlowAirDriverSupportTests {
    /// The Swift identifiers must match the ones compiled into the driver.
    @Test("Identifiers match Driver/Shared/VoxFlowAirDriverShared.h")
    func identifiersMatchDriverHeader() throws {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Driver/Shared/VoxFlowAirDriverShared.h")
        let text = try String(contentsOf: header, encoding: .utf8)
        func define(_ name: String) -> String? {
            for line in text.split(separator: "\n") where line.hasPrefix("#define \(name) ") {
                if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b { return String(line[line.index(after: a)..<b]) }
            }
            return nil
        }
        func suffix(_ name: String) -> String? {
            for line in text.split(separator: "\n") where line.hasPrefix("#define \(name) ") {
                guard line.contains("VF_BUNDLE_ID "), let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
                return String(line[line.index(after: a)..<b])
            }
            return nil
        }
        #expect(define("VF_BUNDLE_ID") == AppIdentity.defaultBundleID)
        #expect(suffix("kVFDriver_BundleID").map { AppIdentity.bundleID + $0 } == VoxFlowAirDriverSupport.bundleIdentifier)
        #expect(suffix("kVFDriver_MicUID").map { AppIdentity.bundleID + $0 } == VoxFlowAirDriverSupport.micUID)
        #expect(suffix("kVFDriver_FeedUID").map { AppIdentity.bundleID + $0 } == VoxFlowAirDriverSupport.feedUID)
        #expect(define("kVFDriver_MicName") == VoxFlowAirDriverSupport.micName)
        #expect(define("kVFDriver_FeedName") == VoxFlowAirDriverSupport.feedName)
    }

    @Test("Loopback: BlackHole onto itself, VoxFlowAir driver onto “VoxFlowAir Micro”")
    func loopbackDevice() {
        #expect(VoxFlowAirDriverSupport.loopbackInputUID(forVirtual: "BlackHole2ch_UID") == "BlackHole2ch_UID")
        #expect(VoxFlowAirDriverSupport.loopbackInputUID(forVirtual: VoxFlowAirDriverSupport.feedUID) == VoxFlowAirDriverSupport.micUID)
    }

    @Test("Guard: VoxFlowAir cannot use its own output as its microphone")
    func feedbackLoopGuard() {
        #expect(VoxFlowAirDriverSupport.wouldLoop(inputUID: VoxFlowAirDriverSupport.micUID, virtualUID: nil))
        #expect(VoxFlowAirDriverSupport.wouldLoop(inputUID: VoxFlowAirDriverSupport.micUID, virtualUID: "BlackHole2ch_UID"))
        #expect(VoxFlowAirDriverSupport.wouldLoop(inputUID: "BlackHole2ch_UID", virtualUID: "BlackHole2ch_UID"))
        #expect(!VoxFlowAirDriverSupport.wouldLoop(inputUID: "USBInterface_UID", virtualUID: VoxFlowAirDriverSupport.feedUID))
        #expect(!VoxFlowAirDriverSupport.wouldLoop(inputUID: "USBInterface_UID", virtualUID: nil))
    }

    @Test("Status consistent with the disk and Core Audio")
    func statusIsConsistent() {
        let s = VoxFlowAirDriverSupport.status()
        let onDisk = FileManager.default.fileExists(atPath: VoxFlowAirDriverSupport.installedURL.path)
        switch s {
        case .notInstalled: #expect(!onDisk)
        case .installedNotLoaded: #expect(onDisk)
        case .available: #expect(VoxFlowAirDriverSupport.deviceID(uid: VoxFlowAirDriverSupport.micUID) != nil)
        }
        #expect(VoxFlowAirDriverSupport.deviceID(uid: "uid-nonexistent-voxflowair") == nil)
    }
}

@Suite("Virtual output saved with the preset")
struct PresetVirtualOutputTests {
    @Test("Microphone name: whitespace trimmed, 1 to 63 characters")
    func sanitizedNames() {
        #expect(VoxFlowAirDriverSupport.sanitizedName("  Podcast Voice  ") == "Podcast Voice")
        #expect(VoxFlowAirDriverSupport.sanitizedName("   ") == nil)
        #expect(VoxFlowAirDriverSupport.sanitizedName(nil) == nil)
        #expect(VoxFlowAirDriverSupport.sanitizedName(String(repeating: "a", count: 64)) == nil)
        #expect(VoxFlowAirDriverSupport.sanitizedName(String(repeating: "é", count: 63)) != nil)
    }

    @Test("The preset keeps the virtual output and name; an older preset without these fields still loads")
    func routingRoundTrip() throws {
        var p = Preset(name: "Podcast", routing: PresetRouting(inputGainDB: -3, virtualUID: VoxFlowAirDriverSupport.feedUID, virtualDeviceName: "VoxFlowAir — Podcast"))
        p.notes = "test"
        let data = try PresetMigrator.encode(p)
        let back = try PresetMigrator.decode(data)
        #expect(back.routing?.virtualUID == VoxFlowAirDriverSupport.feedUID)
        #expect(back.routing?.virtualDeviceName == "VoxFlowAir — Podcast")
        #expect(back.routing?.inputGainDB == -3)

        // File written by an older version: no virtual output fields.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var routing = json["routing"] as! [String: Any]
        routing.removeValue(forKey: "virtualUID"); routing.removeValue(forKey: "virtualDeviceName")
        json["routing"] = routing
        let old = try PresetMigrator.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(old.routing?.virtualUID == nil && old.routing?.virtualDeviceName == nil)
        #expect(old.routing?.inputGainDB == -3)
    }

    @Test("Settings: microphone name persisted, absent = default name")
    func settingsName() throws {
        var s = AppSettings()
        s.virtualDeviceName = "VoxFlowAir — Studio"
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        #expect(back.virtualDeviceName == "VoxFlowAir — Studio")
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"inputGainDB": 2}"#.utf8))
        #expect(legacy.virtualDeviceName == nil && legacy.inputGainDB == 2)
    }
}
