import Foundation
import CoreAudio

/// Snapshot of a Core Audio device.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
    public let bufferFrameSize: Int
    public let bufferFrameSizeRange: ClosedRange<Int>
    public let transportType: UInt32
    public let isAlive: Bool
    public let inputLatencyFrames: Int
    public let outputLatencyFrames: Int
    public let inputSafetyOffset: Int
    public let outputSafetyOffset: Int

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
    public var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
    /// Known virtual device (BlackHole, or any driver with a "virtual" transport).
    public var isVirtual: Bool {
        transportType == kAudioDeviceTransportTypeVirtual || VirtualDeviceSupport.isBlackHole(uid: uid, name: name)
    }
    public var isVoxFlowAirPrivate: Bool { uid.hasPrefix(AggregateDeviceBuilder.uidPrefix) }

    public var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return String(localized: "Built-in")
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: return String(localized: "Virtual")
        case kAudioDeviceTransportTypeAggregate: return String(localized: "Aggregate")
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return String(localized: "Other")
        }
    }

    static func read(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = CA.getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = CA.getString(id, kAudioObjectPropertyName) ?? uid
        let man = CA.getString(id, kAudioObjectPropertyManufacturer) ?? ""
        let ranges = CA.getArray(id, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)
        let standard: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        var rates = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.insert(r.mMinimum) }
            else { for s in standard where s >= r.mMinimum && s <= r.mMaximum { rates.insert(s) } }
        }
        let bufRange: AudioValueRange = CA.get(id, kAudioDevicePropertyBufferFrameSizeRange, default: AudioValueRange(mMinimum: 32, mMaximum: 4096))
        let lo = max(1, Int(bufRange.mMinimum)), hi = max(lo, Int(bufRange.mMaximum))
        return AudioDevice(
            id: id, uid: uid, name: name, manufacturer: man,
            inputChannels: CA.channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: CA.get(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)),
            availableSampleRates: rates.sorted(),
            bufferFrameSize: Int(CA.get(id, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))),
            bufferFrameSizeRange: lo...hi,
            transportType: CA.get(id, kAudioDevicePropertyTransportType, default: UInt32(0)),
            isAlive: CA.get(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(1)) != 0,
            inputLatencyFrames: Int(CA.get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, default: UInt32(0))),
            outputLatencyFrames: Int(CA.get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, default: UInt32(0))),
            inputSafetyOffset: Int(CA.get(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, default: UInt32(0))),
            outputSafetyOffset: Int(CA.get(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, default: UInt32(0)))
        )
    }

    /// Physical format resolution (bits per sample) of the first stream.
    public static func physicalBitDepth(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
        let streams = CA.getArray(id, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self)
        guard let s = streams.first else { return nil }
        let f: AudioStreamBasicDescription = CA.get(s, kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription())
        return f.mBitsPerChannel > 0 ? Int(f.mBitsPerChannel) : nil
    }

    /// Stream latency in frames, for the given scope.
    static func streamLatency(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let streams = CA.getArray(id, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self)
        guard let s = streams.first else { return 0 }
        return Int(CA.get(s, kAudioStreamPropertyLatency, default: UInt32(0)))
    }
}
