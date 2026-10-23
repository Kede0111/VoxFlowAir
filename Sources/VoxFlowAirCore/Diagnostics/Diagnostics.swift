import Foundation
import AVFoundation

/// Detects an abnormal end of the previous session (crash, force quit).
public enum CrashSentinel {
    static var url: URL { AppPaths.applicationSupport.appendingPathComponent("running.lock") }
    public static func previousLaunchCrashed() -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public static func markRunning() { try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: url) }
    public static func markCleanExit() { try? FileManager.default.removeItem(at: url) }
}

/// Working copy of the unsaved graph (recovery after an unexpected quit).
public enum SessionAutosave {
    struct Session: Codable { var presetID: UUID?; var graph: ProcessingGraph; var date: Date }

    public static func save(presetID: UUID?, graph: ProcessingGraph) {
        let s = Session(presetID: presetID, graph: graph, date: Date())
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: AppPaths.session, options: .atomic) }
    }

    public static func load() -> (presetID: UUID?, graph: ProcessingGraph)? {
        guard let data = try? Data(contentsOf: AppPaths.session), let s = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        return (s.presetID, s.graph)
    }

    public static func clear() { try? FileManager.default.removeItem(at: AppPaths.session) }
}

@MainActor
public enum Diagnostics {
    public static func report(engine e: VoxFlowAirEngine) -> String {
        var out: [String] = []
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main
        out.append("=== VoxFlowAir Diagnostics ===")
        out.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("VoxFlowAir: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
        out.append("macOS: \(info.operatingSystemVersionString)")
        var sys = utsname(); uname(&sys)
        out.append("Architecture: \(withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })")
        out.append("")
        out.append("— Engine —")
        out.append("State: \(e.state.label)  |  restarts: \(e.restartCount)  |  safe mode: \(e.safeMode)")
        out.append("Input: \(e.activeInput?.name ?? "-")  [\(e.activeInput?.uid ?? "-")]")
        out.append("Virtual output: \(e.activeVirtual?.name ?? "-")  |  BlackHole status: \(e.virtualStatus)")
        out.append("Monitoring: \(e.activeMonitor?.name ?? "-")")
        out.append(e.loopbackStatus.label)
        let l = e.latency
        out.append(String(format: "Sample rate %.0f Hz, buffer %d (%.2f ms), estimated latency %.1f ms (hardware in %d / out %d frames, plugins %.1f ms)",
                          l.sampleRate, l.bufferFrames, l.bufferMs, l.estimatedTotalMs, l.inputDeviceFrames, l.outputDeviceFrames, l.pluginSeconds * 1000))
        let m = e.processor.meters
        out.append("Cycles: \(m.cycles.value)  Core Audio overloads: \(m.deviceOverloads.value)  cycles > 90 %: \(m.nearOverruns.value)  render errors: \(m.renderErrors.value)  input errors: \(m.inputErrors.value)  invalid samples: \(m.invalidSamples.value)  transition cycles: \(m.transitionCycles.value)")
        out.append("Clipping: input \(m.input.clipCount.value), processed \(m.processed.clipCount.value), virtual \(m.virtualOut.clipCount.value), monitoring \(m.monitorOut.clipCount.value)")
        out.append("")
        out.append("— Chain —  preset: \(e.activePreset?.name ?? "-")  modified: \(e.isDirty)")
        for n in e.graph.nodes {
            out.append("  • \(n.kind.rawValue) “\(n.title)” \(n.plugin?.identifier ?? "") bypass=\(e.graph.isEffectivelyBypassed(n)) status=\(e.nodeStatus[n.id]?.label ?? "-")")
        }
        for i in e.issues { out.append("  ! [\(i.severity)] \(i.message)") }
        out.append("")
        out.append("— Devices —")
        for d in e.devices {
            out.append("  • \(d.name) [\(d.uid)] \(d.transportName) in=\(d.inputChannels) out=\(d.outputChannels) \(Int(d.nominalSampleRate)) Hz buffer=\(d.bufferFrameSize)")
        }
        out.append("")
        out.append("— Plugins — \(e.plugins.count) AU effects found")
        out.append("")
        out.append("— Recent notices —")
        for n in e.notices.suffix(30) { out.append("  [\(n.kind)] \(n.message)") }
        out.append("")
        out.append("— Log (tail) —")
        out.append(contentsOf: VFLog.shared.recentLines().suffix(150))
        return out.joined(separator: "\n")
    }
}
