import Foundation
import CoreAudio

/// Lists the Core Audio devices and reports their changes
/// (plugged in, unplugged, sample rate change, default device).
public final class AudioDeviceManager: @unchecked Sendable {
    public private(set) var devices: [AudioDevice] = []
    /// Called on the main queue after any change to the list.
    public var onDevicesChanged: (([AudioDevice]) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultsBlock: AudioObjectPropertyListenerBlock?

    public init() {
        refresh()
        installListeners()
    }

    deinit { removeListeners() }

    @discardableResult
    public func refresh() -> [AudioDevice] {
        let ids = CA.getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        devices = ids.compactMap(AudioDevice.read).filter { !$0.isVoxFlowAirPrivate }
        return devices
    }

    public var inputDevices: [AudioDevice] { devices.filter { $0.hasInput && !$0.isVirtual } }
    public var virtualDevices: [AudioDevice] { devices.filter { $0.isVirtual && $0.hasOutput } }
    public var physicalOutputDevices: [AudioDevice] { devices.filter { $0.hasOutput && !$0.isVirtual && !$0.isAggregate } }

    public func device(uid: String) -> AudioDevice? { devices.first { $0.uid == uid } }

    public static func defaultInputUID() -> String? {
        let id: AudioObjectID = CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: 0)
        return id == 0 ? nil : CA.getString(id, kAudioDevicePropertyDeviceUID)
    }

    public static func defaultOutputUID() -> String? {
        let id: AudioObjectID = CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        return id == 0 ? nil : CA.getString(id, kAudioDevicePropertyDeviceUID)
    }

    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        let ids = CA.getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        return ids.first { CA.getString($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let list = self.refresh()
            self.onDevicesChanged?(list)
        }
        listenerBlock = block
        var a = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        var d = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &d, .main, block)
        defaultsBlock = block
    }

    private func removeListeners() {
        if let b = listenerBlock {
            var a = CA.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, b)
        }
        if let b = defaultsBlock {
            var d = CA.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &d, .main, b)
        }
    }
}
