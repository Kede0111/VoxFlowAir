import SwiftUI
import AppKit
import ServiceManagement
import VoxFlowAirCore

/// UI state (selection, panels) around the engine.
@Observable
@MainActor
final class AppState {
    let engine: VoxFlowAirEngine
    let meters: MeterHub
    let pluginWindows = PluginWindowManager()
    let meterMonitors: MeterMonitors
    /// Meter monitors panel shown.
    var meterPanelShown = false
    /// Window open/close actions (local diagnostic control).
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored var dismissWindowAction: DismissWindowAction?
    let localControl: LocalControl
    let recorder = ComparisonRecorder()
    var lastRecording: ComparisonRecorder.Result?
    var recordingUntil: Date?

    var selectedNodes: Set<UUID> = []
    var selectedConnection: UUID?
    var bottomTab: BottomTab = .spectrum
    var analysisSource: AnalysisSource = .output
    var showBlackHoleAssistant = false
    var showInspector = true
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Control snapshots only: simulates a “move in chain” (node, connection).
    var debugReorder: (node: UUID, connection: UUID)?
    /// Gesture test only (`EditorUITest`): drag replayed through the same functions as the mouse.
    var debugDrag: EditorDebugDrag?
    var renamingPreset: UUID?
    var editorCommand: EditorCommand?
    /// Per-node A/B comparison: stored state and side shown.
    var compareStates: [UUID: (stored: Data, showingB: Bool)] = [:]
    /// Plugin state clipboard (AU identifier + state).
    var pluginClipboard: (identifier: String, name: String, state: Data)?

    enum BottomTab: String, CaseIterable, Identifiable {
        case spectrum = "Analyzer", scope = "Oscilloscope", loudness = "Phase", levels = "Levels"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .spectrum: String(localized: "Analyzer")
            case .scope: String(localized: "Oscilloscope")
            case .loudness: String(localized: "Phase")
            case .levels: String(localized: "Levels")
            }
        }
    }

    enum AnalysisSource: Hashable {
        case input, output
        case node(UUID)
    }

    enum EditorCommand: Equatable { case zoomIn, zoomOut, fit, resetZoom }

    init() {
        engine = VoxFlowAirEngine()
        meters = MeterHub()
        meters.engine = engine
        meterMonitors = MeterMonitors(engine: engine)
        localControl = LocalControl(engine: engine)
        localControl.extraCommands["monitors"] = { [unowned self] cmd in self.handleMonitorsCommand(cmd) }
    }

    var primarySelection: UUID? { selectedNodes.count == 1 ? selectedNodes.first : nil }

    func category(for node: GraphNode) -> PluginCategory? {
        guard let ref = node.plugin else { return nil }
        return engine.catalog.info(for: ref)?.category ?? PluginCatalog.categorize(name: ref.name, tags: [])
    }

    func openPluginUI(_ id: UUID) {
        guard let node = engine.graph.node(id) else { return }
        if node.kind == .audioUnit {
            guard let unit = engine.pluginUnit(for: id) else {
                engine.post(.warning, String(localized: "“\(node.title)” is not loaded: interface unavailable."))
                return
            }
            pluginWindows.open(nodeID: id, title: node.title, unit: unit)
        } else {
            selectedNodes = [id]
        }
    }

    /// Can the selected node move up / down in the main chain?
    var canMoveSelection: Bool {
        guard !engine.settings.lockEditing, let id = primarySelection else { return false }
        return engine.graph.reorderableMainChain().contains(id)
    }

    /// Moves the selected node one step up (-1) or down (+1) in the main chain.
    func moveSelection(by delta: Int) {
        guard canMoveSelection, let id = primarySelection else { return }
        let chain = engine.graph.reorderableMainChain()
        guard let i = chain.firstIndex(of: id) else { return }
        if delta < 0 {
            guard i > 0 else { return }
            engine.moveInMainChain(id, before: chain[i - 1])
        } else {
            guard i < chain.count - 1 else { return }
            engine.moveInMainChain(id, before: i + 2 < chain.count ? chain[i + 2] : nil)
        }
    }

    func deleteSelection() {
        if let c = selectedConnection { engine.disconnect(c); selectedConnection = nil; return }
        for id in selectedNodes {
            pluginWindows.close(nodeID: id)
            engine.removeNode(id)
        }
        selectedNodes = []
    }

    /// Records a raw + processed clip for listening comparison.
    func recordComparison(seconds: Double = 20) {
        guard engine.state.isRunning else { engine.post(.warning, String(localized: "Start the engine to record.")); return }
        recordingUntil = Date().addingTimeInterval(seconds)
        recorder.record(meters: engine.processor.meters, sampleRate: engine.latency.sampleRate, seconds: seconds,
                        label: engine.activePreset?.name.replacingOccurrences(of: "/", with: "-") ?? "voxflowair") { r, err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.recordingUntil = nil
                    if let r {
                        self.lastRecording = r
                        self.engine.post(.info, String(localized: "Clip recorded: \(r.raw.lastPathComponent) (raw) and \(r.processed.lastPathComponent) (processed)."))
                        NSWorkspace.shared.activateFileViewerSelecting([r.raw, r.processed])
                    } else {
                        self.engine.post(.error, String(localized: "Recording failed: \(err.map { "\($0)" } ?? "?")"))
                    }
                }
            }
        }
    }

    func applyAppearance() {
        switch engine.settings.appearance {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    // MARK: Launch at login

    var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            engine.post(.error, String(localized: "Launch at login: \(error.localizedDescription)"))
        }
    }
}

/// Meter readout at 30 Hz, decoupled from the audio thread (atomic reads only).
@Observable
@MainActor
final class MeterHub {
    struct Level: Equatable {
        var peakL: Float = 0, peakR: Float = 0, rmsL: Float = 0, rmsR: Float = 0
        var holdL: Float = 0, holdR: Float = 0
        var maxPeak: Float { max(peakL, peakR) }
    }

    @ObservationIgnored weak var engine: VoxFlowAirEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var holdTime: [String: Date] = [:]

    var input = Level()
    var processed = Level()
    var virtualOut = Level()
    var monitorOut = Level()
    var nodes: [UUID: Level] = [:]
    var clipInput = false
    var clipOutput = false
    var load: Float = 0
    var overloads = 0
    var nearOverruns = 0
    var renderErrors = 0
    var inputErrors = 0
    var invalidSamples = 0
    var dropoutWarning = false

    @ObservationIgnored private var lastOverloads = 0
    @ObservationIgnored private var lastDropAt: Date?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func smooth(_ old: Level, _ r: LevelMeter.Reading, key: String) -> Level {
        // Gentle ballistic fall (≈ 20 dB/s) and 1.5 s peak hold.
        let fall: Float = 0.80
        var l = Level()
        l.peakL = max(r.peakL, old.peakL * fall)
        l.peakR = max(r.peakR, old.peakR * fall)
        l.rmsL = max(r.rmsL, old.rmsL * fall)
        l.rmsR = max(r.rmsR, old.rmsR * fall)
        let now = Date()
        if r.maxPeak >= max(old.holdL, old.holdR) || (holdTime[key].map { now.timeIntervalSince($0) > 1.5 } ?? true) {
            l.holdL = r.peakL; l.holdR = r.peakR; holdTime[key] = now
        } else { l.holdL = old.holdL; l.holdR = old.holdR }
        return l
    }

    private func tick() {
        guard let e = engine else { return }
        let m = e.processor.meters
        input = smooth(input, m.input.read(), key: "in")
        processed = smooth(processed, m.processed.read(), key: "pr")
        virtualOut = smooth(virtualOut, m.virtualOut.read(), key: "vo")
        monitorOut = smooth(monitorOut, m.monitorOut.read(), key: "mo")
        var n: [UUID: Level] = [:]
        for node in e.graph.nodes {
            if let meter = e.meter(for: node.id) { n[node.id] = smooth(nodes[node.id] ?? Level(), meter.read(), key: node.id.uuidString) }
        }
        if n != nodes { nodes = n }
        clipInput = m.input.clipCount.value > 0
        clipOutput = m.processed.clipCount.value > 0 || m.virtualOut.clipCount.value > 0
        let l = m.maxLoad.take()
        load = max(l, load * 0.9)
        overloads = m.deviceOverloads.value
        nearOverruns = m.nearOverruns.value
        renderErrors = m.renderErrors.value
        inputErrors = m.inputErrors.value
        invalidSamples = m.invalidSamples.value
        if overloads != lastOverloads { lastOverloads = overloads; lastDropAt = Date() }
        dropoutWarning = lastDropAt.map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    func resetClips() {
        engine?.processor.meters.input.clipCount.reset()
        engine?.processor.meters.processed.clipCount.reset()
        engine?.processor.meters.virtualOut.clipCount.reset()
        engine?.processor.meters.monitorOut.clipCount.reset()
    }
}
