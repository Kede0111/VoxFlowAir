import Foundation
import CoreAudio
import AudioToolbox

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let context: String
    public init(_ status: OSStatus, _ context: String) { self.status = status; self.context = context }
    public var description: String { "\(context) (OSStatus \(status) \(fourCC(status)))" }
}

public func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(bytes: bytes, encoding: .ascii)! + "'" }
    return ""
}

@inline(__always) func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status, context()) }
}

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = address(selector, scope)
        return AudioObjectHasProperty(obj, &a)
    }

    static func get<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       default def: T) -> T {
        var a = address(selector, scope)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        return st == noErr ? value : def
    }

    static func set<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) throws {
        var a = address(selector, scope)
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &v) { AudioObjectSetPropertyData(obj, &a, 0, nil, size, $0) }
        try check(st, "AudioObjectSetPropertyData \(fourCCSelector(selector))")
    }

    static func getArray<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, buf) == noErr else { return [] }
        let typed = buf.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func channelCount(_ obj: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func fourCCSelector(_ s: UInt32) -> String { fourCC(OSStatus(bitPattern: s)) }
}
