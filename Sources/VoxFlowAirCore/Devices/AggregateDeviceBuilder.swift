import Foundation
import CoreAudio

/// Channel layout inside the private aggregate device.
public struct AggregateChannelLayout: Equatable, Sendable {
    public var inputOffset: Int = 0
    public var inputCount: Int = 0
    public var virtualOffset: Int = -1
    public var virtualCount: Int = 0
    /// Input channels of the virtual device (BlackHole returns what is written to it): used to check the output.
    public var virtualInputOffset: Int = -1
    public var virtualInputCount: Int = 0
    public var monitorOffset: Int = -1
    public var monitorCount: Int = 0
    public var totalInputs: Int = 0
    public var totalOutputs: Int = 0
}

/// Creates a *private* aggregate device (visible only to VoxFlowAir, destroyed
/// automatically when the process ends) that combines the microphone, the virtual
/// output and the monitoring headphones under one clock, with drift correction.
/// This mechanism is public (AudioHardwareCreateAggregateDevice) and needs
/// no administrator rights.
public final class AggregateDeviceBuilder {
    public static let uidPrefix = AppIdentity.bundleID + ".aggregate"

    public struct Request: Equatable, Sendable {
        public var inputUID: String
        public var virtualUID: String?
        public var monitorUID: String?
        public init(inputUID: String, virtualUID: String?, monitorUID: String?) {
            self.inputUID = inputUID; self.virtualUID = virtualUID; self.monitorUID = monitorUID
        }
    }

    public private(set) var deviceID: AudioObjectID = 0
    public private(set) var layout = AggregateChannelLayout()
    public private(set) var subDeviceUIDs: [String] = []

    public init() {}

    deinit { destroy() }

    public func create(_ req: Request) throws -> AudioObjectID {
        destroy()
        var uids: [String] = [req.inputUID]
        if let v = req.virtualUID, !uids.contains(v) { uids.append(v) }
        if let m = req.monitorUID, !uids.contains(m) { uids.append(m) }

        // Check that every subdevice still exists.
        var ids: [String: AudioObjectID] = [:]
        for uid in uids {
            guard let id = AudioDeviceManager.deviceID(forUID: uid) else {
                throw CoreAudioError(kAudioHardwareBadDeviceError, String(localized: "Device not found: \(uid)"))
            }
            ids[uid] = id
        }

        let clockUID = req.inputUID
        let subs: [[String: Any]] = uids.map { uid in
            [kAudioSubDeviceUIDKey: uid,
             // The input is the master clock; the others are resampled.
             kAudioSubDeviceDriftCompensationKey: uid == clockUID ? 0 : 1]
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoxFlowAir Engine",
            kAudioAggregateDeviceUIDKey: "\(Self.uidPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: subs,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceClockDeviceKey: clockUID,
        ]
        var newID: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID), String(localized: "Creating the aggregate device"))
        deviceID = newID
        subDeviceUIDs = uids
        // Let the audio server publish the new device.
        waitUntil(timeout: 2.0) { CA.channelCount(newID, scope: kAudioObjectPropertyScopeOutput) > 0 || CA.channelCount(newID, scope: kAudioObjectPropertyScopeInput) > 0 }

        // Compute the channel offsets: subdevices are concatenated in order.
        var l = AggregateChannelLayout()
        var inOff = 0, outOff = 0
        for uid in uids {
            let id = ids[uid]!
            let ins = CA.channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outs = CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            if uid == req.inputUID { l.inputOffset = inOff; l.inputCount = ins }
            if uid == req.virtualUID { l.virtualOffset = outOff; l.virtualCount = outs; l.virtualInputOffset = inOff; l.virtualInputCount = ins }
            if uid == req.monitorUID { l.monitorOffset = outOff; l.monitorCount = outs }
            inOff += ins; outOff += outs
        }
        l.totalInputs = CA.channelCount(newID, scope: kAudioObjectPropertyScopeInput)
        l.totalOutputs = CA.channelCount(newID, scope: kAudioObjectPropertyScopeOutput)
        if l.totalInputs != inOff || l.totalOutputs != outOff {
            vlog(.warning, "Aggregate: expected channels in=\(inOff) out=\(outOff), got in=\(l.totalInputs) out=\(l.totalOutputs)")
        }
        layout = l
        vlog(.info, "Private aggregate created (id \(newID)): \(uids), clock \(clockUID), layout=\(l)")
        return newID
    }

    public func setSampleRate(_ rate: Double) throws {
        guard deviceID != 0 else { return }
        let current: Float64 = CA.get(deviceID, kAudioDevicePropertyNominalSampleRate, default: 0)
        if abs(current - rate) < 0.5 { return }
        try CA.set(deviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(rate))
        let id = deviceID
        waitUntil(timeout: 2.0) { abs(CA.get(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)) - rate) < 0.5 }
    }

    public func setBufferSize(_ frames: Int) throws {
        guard deviceID != 0 else { return }
        try CA.set(deviceID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(frames))
    }

    public var sampleRate: Double { CA.get(deviceID, kAudioDevicePropertyNominalSampleRate, default: Float64(0)) }
    public var bufferSize: Int { Int(CA.get(deviceID, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))) }

    public func destroy() {
        guard deviceID != 0 else { return }
        let st = AudioHardwareDestroyAggregateDevice(deviceID)
        vlog(st == noErr ? .info : .warning, "Destroying aggregate \(deviceID): \(st)")
        deviceID = 0
        subDeviceUIDs = []
    }
}

func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
