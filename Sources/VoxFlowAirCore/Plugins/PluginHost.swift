import Foundation
import AVFoundation
import AppKit
import CoreAudioKit
import VFObjC

/// How a plugin is loaded.
public enum PluginLoadMode: String, Codable, CaseIterable, Sendable {
    /// In the VoxFlowAir process: maximum compatibility, but a crashing plugin takes VoxFlowAir down with it.
    case inProcess
    /// In a separate host process managed by macOS (AUHostingService): a plugin
    /// crash does not stop VoxFlowAir. Supported by macOS for AU v2 and v3,
    /// but not every plugin tolerates it.
    case outOfProcess

    public var displayName: String { self == .inProcess ? String(localized: "Inside VoxFlowAir") : String(localized: "Isolated Process") }
}

public enum PluginHost {
    /// Instantiates an AU plugin. Throws an explicit error on failure.
    public static func instantiate(_ ref: PluginReference, mode: PluginLoadMode, timeout: TimeInterval = 20) async throws -> AVAudioUnit {
        var desc = ref.componentDescription
        guard AudioComponentFindNext(nil, &desc) != nil else {
            throw RuntimeError(String(localized: "Plugin not installed: \(ref.name) (\(ref.manufacturerName))"))
        }
        let options: AudioComponentInstantiationOptions = mode == .outOfProcess ? .loadOutOfProcess : .loadInProcess
        let start = Date()
        let unit: AVAudioUnit = try await withCheckedThrowingContinuation { cont in
            AVAudioUnit.instantiate(with: ref.componentDescription, options: options) { u, err in
                if let u { cont.resume(returning: u) }
                else { cont.resume(throwing: err ?? RuntimeError(String(localized: "Could not instantiate \(ref.name)"))) }
            }
        }
        vlog(.info, "Plugin loaded “\(ref.name)” (\(mode.rawValue)) in \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000)) ms")
        return unit
    }

    /// Saves the plugin's full state (fullState) as a binary property list.
    public static func captureState(_ unit: AVAudioUnit) -> Data? {
        var result: Data?
        var err: NSError?
        _ = VFTryObjC({
            if let state = unit.auAudioUnit.fullState {
                result = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
            }
        }, &err)
        return result
    }

    /// Restores the state. Returns false if the plugin rejected it.
    @discardableResult
    public static func restoreState(_ unit: AVAudioUnit, data: Data) -> Bool {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return false }
        var err: NSError?
        let ok = VFTryObjC({ unit.auAudioUnit.fullState = dict }, &err)
        if !ok { vlog(.warning, "State restore rejected: \(err?.localizedDescription ?? "?")") }
        return ok
    }

    /// Latency reported by the plugin, in seconds.
    public static func latency(_ unit: AVAudioUnit) -> Double { unit.auAudioUnit.latency }

    /// Gets the plugin's native UI (v3: requestViewController; v2: Cocoa view).
    @MainActor
    public static func loadView(for unit: AVAudioUnit, preferredSize: NSSize = NSSize(width: 800, height: 500)) async -> NSView? {
        let vc: NSViewController? = await withCheckedContinuation { cont in
            unit.auAudioUnit.requestViewController { vc in cont.resume(returning: vc) }
        }
        if let vc {
            // Keep the controller alive as long as its view.
            let v = vc.view
            objc_setAssociatedObject(v, &controllerKey, vc, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if v.frame.size == .zero { v.setFrameSize(vc.preferredContentSize == .zero ? preferredSize : vc.preferredContentSize) }
            return v
        }
        // In-process AU v2 fallback: Cocoa UI provided by the manufacturer.
        let au = unit.audioUnit
        return VFCreateCocoaViewForAudioUnit(au, preferredSize)
    }
}

nonisolated(unsafe) private var controllerKey: UInt8 = 0
