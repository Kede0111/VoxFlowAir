import Foundation
import AppKit
import CoreAudio

/// Another app doing audio, as seen by Core Audio ("process" objects, macOS 14.2+).
public struct AudioClientProcess: Equatable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var name: String
    /// Devices in use, by UID; aggregates are replaced by their subdevices.
    public var inputUIDs: [String]
    public var outputUIDs: [String]
    public var runningInput: Bool
    public var runningOutput: Bool

    public init(pid: pid_t, bundleID: String, name: String, inputUIDs: [String], outputUIDs: [String], runningInput: Bool, runningOutput: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
        self.inputUIDs = inputUIDs; self.outputUIDs = outputUIDs
        self.runningInput = runningInput; self.runningOutput = runningOutput
    }

    /// Records without any input device: it captures other apps' audio
    /// (process tap, as FineTune, SoundSource… do).
    public var capturesAppAudio: Bool { runningInput && inputUIDs.isEmpty }
}

public enum AudioProcesses {
    /// Running audio processes, excluding VoxFlowAir.
    public static func running() -> [AudioClientProcess] {
        let me = ProcessInfo.processInfo.processIdentifier
        return CA.getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self).compactMap { p in
            let pid: pid_t = CA.get(p, kAudioProcessPropertyPID, default: 0)
            guard pid != me, CA.get(p, kAudioProcessPropertyIsRunning, default: UInt32(0)) != 0 else { return nil }
            let bundleID = CA.getString(p, kAudioProcessPropertyBundleID) ?? ""
            return AudioClientProcess(
                pid: pid, bundleID: bundleID, name: displayName(pid: pid, bundleID: bundleID),
                inputUIDs: deviceUIDs(p, kAudioObjectPropertyScopeInput),
                outputUIDs: deviceUIDs(p, kAudioObjectPropertyScopeOutput),
                runningInput: CA.get(p, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                runningOutput: CA.get(p, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
        }
    }

    private static func deviceUIDs(_ process: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [String] {
        CA.getArray(process, kAudioProcessPropertyDevices, scope, of: AudioObjectID.self).flatMap { d -> [AudioObjectID] in
            let subs = CA.getArray(d, kAudioAggregateDevicePropertyActiveSubDeviceList, of: AudioObjectID.self)
            return subs.isEmpty ? [d] : subs
        }.compactMap { CA.getString($0, kAudioDevicePropertyDeviceUID) }
    }

    private static func displayName(pid: pid_t, bundleID: String) -> String {
        if let n = CallAudioPolicy.callApps[bundleID] { return n }
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName { return n }
        return bundleID.isEmpty ? String(localized: "process \(pid)") : bundleID
    }
}

/// Rules that protect the virtual output and monitoring from other audio apps.
///
/// Measured on macOS 27 with a Voice Processing unit (the one FaceTime uses):
/// - its echo canceller takes as reference everything played on its output, by every app:
///   if VoxFlowAir monitors the processed voice on that same device, the voice read back from
///   the virtual microphone is removed as echo (silence or choppy audio on the other end);
/// - with BlackHole as the microphone, the voice is removed in every case (BlackHole replays its
///   own output, which the canceller also takes as reference). "VoxFlowAir Micro" does not have this flaw.
public enum CallAudioPolicy {
    /// Known call apps (FaceTime's audio runs in avconferenced).
    public static let callApps: [String: String] = [
        "com.apple.avconferenced": "FaceTime", "com.apple.FaceTime": "FaceTime",
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
        "com.hnc.Discord": "Discord", "net.whatsapp.WhatsApp": "WhatsApp", "com.tinyspeck.slackmacgap": "Slack",
        "Cisco-Systems.Spark": "Webex",
    ]

    /// Apps that listen to the virtual microphone (`loopbackUID`) and play on the monitoring headphones:
    /// while they run, VoxFlowAir's monitoring would be taken for echo and removed.
    public static func listenersOnMonitor(_ processes: [AudioClientProcess], loopbackUID: String?, monitorUID: String?) -> [AudioClientProcess] {
        guard let loopbackUID, let monitorUID else { return [] }
        return processes.filter { $0.runningInput && $0.runningOutput && $0.inputUIDs.contains(loopbackUID) && $0.outputUIDs.contains(monitorUID) }
    }

    /// Call apps listening to BlackHole: their echo canceller removes the voice.
    public static func callAppsOnBlackHole(_ processes: [AudioClientProcess], loopbackUID: String?, loopbackName: String) -> [AudioClientProcess] {
        guard let loopbackUID, VirtualDeviceSupport.isBlackHole(uid: loopbackUID, name: loopbackName) else { return [] }
        return processes.filter { $0.runningInput && $0.inputUIDs.contains(loopbackUID) && callApps[$0.bundleID] != nil }
    }

    /// Apps that capture other apps' audio (process taps).
    public static func interceptors(_ processes: [AudioClientProcess]) -> [AudioClientProcess] {
        processes.filter(\.capturesAppAudio)
    }

    public static func names(_ processes: [AudioClientProcess]) -> String {
        var seen = Set<String>()
        return processes.map(\.name).filter { seen.insert($0).inserted }.map { "“\($0)”" }.joined(separator: ", ")
    }
}
