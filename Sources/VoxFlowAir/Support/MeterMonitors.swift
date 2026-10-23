import SwiftUI
import AppKit
import AVFoundation
import VoxFlowAirCore

/// Input and output meter monitors (analyzer plugins): one instance per point, created on
/// selection and kept as long as the selection doesn't change (opening or closing the panel
/// recreates nothing). The plugins receive a copy of the signal, off the audio path.
@Observable
@MainActor
final class MeterMonitors {
    struct Slot {
        var plugin: PluginReference
        var unit: AVAudioUnit
        var view: NSView?
    }

    @ObservationIgnored private weak var engine: VoxFlowAirEngine?
    @ObservationIgnored let feeder = MeterMonitorFeeder()
    @ObservationIgnored private var timer: Timer?

    private(set) var slots: [MonitorPoint: Slot] = [:]
    private(set) var loading: Set<MonitorPoint> = []
    private(set) var errors: [MonitorPoint: String] = [:]
    /// Peak received by each plugin (dBFS), read at its output: proof that it measures the real signal.
    private(set) var receivedDB: [MonitorPoint: Float] = [:]
    /// The panel is shown (indicators refresh only in that case).
    var panelVisible = false

    init(engine: VoxFlowAirEngine) { self.engine = engine }

    private static let keyPrefix = "VoxFlowAirMeterMonitor."

    var available: [PluginInfo] { MeterPlugins.available(in: engine?.plugins ?? []) }

    private static func selectionKey(_ p: MonitorPoint) -> String { keyPrefix + p.rawValue }
    private static func stateKey(_ p: MonitorPoint, _ ref: PluginReference) -> String { keyPrefix + "\(p.rawValue).state.\(ref.identifier)" }

    func selectedID(_ p: MonitorPoint) -> String? { UserDefaults.standard.string(forKey: Self.selectionKey(p)) }

    /// Reloads the monitors chosen in the previous session.
    func restore() {
        guard let engine, !engine.safeMode else { return }
        for p in MonitorPoint.allCases {
            if let id = selectedID(p), let info = available.first(where: { $0.id == id }) { load(info.reference, at: p) }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func select(_ ref: PluginReference?, at p: MonitorPoint) {
        if slots[p]?.plugin == ref, ref != nil { return }
        UserDefaults.standard.set(ref?.identifier, forKey: Self.selectionKey(p))
        unload(p)
        if let ref { load(ref, at: p) }
    }

    private func load(_ ref: PluginReference, at p: MonitorPoint) {
        guard let engine else { return }
        loading.insert(p)
        errors[p] = nil
        let mode = engine.settings.pluginLoadMode
        Task { @MainActor in
            defer { loading.remove(p) }
            do {
                let unit = try await PluginHost.instantiate(ref, mode: mode)
                // Selection changed while loading: drop this instance.
                guard selectedID(p) == ref.identifier, slots[p] == nil else { return }
                if let data = UserDefaults.standard.data(forKey: Self.stateKey(p, ref)) { PluginHost.restoreState(unit, data: data) }
                if engine.latency.sampleRate > 0 { feeder.setSampleRate(engine.latency.sampleRate) }
                try feeder.attach(unit, tap: p.tap(in: engine.processor.meters), at: p)
                slots[p] = Slot(plugin: ref, unit: unit)
                vlog(.info, "Monitor \(p.displayName): \"\(ref.name)\" attached")
            } catch {
                errors[p] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                vlog(.error, "Monitor \(p.displayName): \(error)")
            }
        }
    }

    private func unload(_ p: MonitorPoint) {
        guard let s = slots[p] else { return }
        saveState(p)
        feeder.detach(p)
        s.view?.removeFromSuperview()
        slots[p] = nil
        receivedDB[p] = nil
        viewWidths[p] = nil
    }

    private func saveState(_ p: MonitorPoint) {
        guard let s = slots[p], let data = PluginHost.captureState(s.unit) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey(p, s.plugin))
    }

    /// Meter settings (loudness target, scale…) kept from one session to the next.
    func saveAll() { for p in MonitorPoint.allCases { saveState(p) } }

    /// The plugin's native view, created once and then reused.
    func nativeView(_ p: MonitorPoint) async -> NSView? {
        guard let s = slots[p] else { return nil }
        if let v = s.view { return v }
        let v = await PluginHost.loadView(for: s.unit)
        guard slots[p]?.unit === s.unit else { return nil }
        slots[p]?.view = v
        return v
    }

    /// Width of the displayed native view (0 if none).
    func contentWidth(_ p: MonitorPoint) -> CGFloat { viewWidths[p] ?? 0 }
    private(set) var viewWidths: [MonitorPoint: CGFloat] = [:]
    func noteViewSize(_ size: CGSize, at p: MonitorPoint) { if viewWidths[p] != size.width { viewWidths[p] = size.width } }

    private func tick() {
        guard let engine else { return }
        if engine.latency.sampleRate > 0 { feeder.setSampleRate(engine.latency.sampleRate) }
        guard panelVisible else { return }
        for p in MonitorPoint.allCases where slots[p] != nil {
            let pk = feeder.takeReceivedPeak(p) ?? 0
            let db = linearToDB(pk)
            // Slow fall for a readable display.
            let prev = receivedDB[p] ?? -120
            receivedDB[p] = db >= prev ? db : max(db, prev - 3)
        }
    }
}

extension AppState {
    /// Local diagnostic control: `{"cmd":"monitors","input":"VU Meter","output":"WLM Plus","panel":"show","engine":"start"}`.
    /// Names are prefixes ("" = no monitor); every key is optional.
    func handleMonitorsCommand(_ cmd: [String: Any]) -> [String: Any] {
        let m = meterMonitors
        // One-off engine start for a test, without changing the saved preference.
        switch cmd["engine"] as? String {
        case "start": engine.start()
        case "stop": engine.stop()
        default: break
        }
        for p in MonitorPoint.allCases {
            guard let name = cmd[p.rawValue] as? String else { continue }
            m.select(name.isEmpty ? nil : m.available.first { $0.name.hasPrefix(name) }?.reference, at: p)
        }
        switch cmd["panel"] as? String {
        case "show": openWindowAction?(id: MeterMonitorPanel.windowID)
        case "hide": dismissWindowAction?(id: MeterMonitorPanel.windowID)
        default: break
        }
        var points: [String: Any] = [:]
        for p in MonitorPoint.allCases {
            var d: [String: Any] = ["loading": m.loading.contains(p)]
            if let s = m.slots[p] {
                d["plugin"] = s.plugin.name
                d["viewSize"] = s.view.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "not created"
                d["viewInWindow"] = s.view?.window != nil
                d["receivedPeakDB"] = Double(m.receivedDB[p] ?? -120)
                if let st = m.feeder.stats(p) { d["renderErrors"] = st.renderErrors; d["gaps"] = st.gaps }
            }
            if let e = m.errors[p] { d["error"] = e }
            points[p.rawValue] = d
        }
        let panel = NSApp.windows.first { $0.identifier?.rawValue.contains(MeterMonitorPanel.windowID) == true && $0.isVisible }
        // Captures the panel's content (visual check without screen recording permission).
        if let path = cmd["snapshot"] as? String, let v = panel?.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        return ["monitors": points, "available": m.available.map(\.name), "panelShown": meterPanelShown,
                "panelFrame": panel.map { NSStringFromRect($0.frame) } ?? "closed",
                "voxflowairAirInputPeakDB": Double(linearToDB(meters.input.maxPeak)),
                "voxflowairAirOutputPeakDB": Double(linearToDB(meters.processed.maxPeak))]
    }
}
