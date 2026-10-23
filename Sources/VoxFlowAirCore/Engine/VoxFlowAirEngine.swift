import Foundation
import AVFoundation
import CoreAudio
import Observation
import Accelerate

/// Global engine state shown in the UI.
public enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case recovering(String)
    case error(String)

    public var label: String {
        switch self {
        case .stopped: return String(localized: "Stopped")
        case .starting: return String(localized: "Starting…")
        case .running: return String(localized: "Running")
        case .recovering(let r): return String(localized: "Recovering: \(r)")
        case .error(let e): return String(localized: "Error: \(e)")
        }
    }
    public var isRunning: Bool { self == .running }
}

/// Latency breakdown. All values come from Core Audio properties
/// and plugins: it is an estimate, not a measurement.
public struct LatencyReport: Equatable, Sendable {
    public var sampleRate: Double = 0
    public var bufferFrames: Int = 0
    public var inputDeviceFrames: Int = 0
    public var outputDeviceFrames: Int = 0
    public var pluginSeconds: Double = 0
    /// Direct virtual output buffer (absorbs clock drift).
    public var virtualBufferFrames: Int = 0

    public var bufferMs: Double { sampleRate > 0 ? Double(bufferFrames) / sampleRate * 1000 : 0 }
    /// Microphone → headphones (monitoring): hardware latencies + 2 buffers + plugins. Estimate.
    public var monitorEstimatedMs: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(inputDeviceFrames + outputDeviceFrames + 2 * bufferFrames) / sampleRate * 1000 + pluginSeconds * 1000
    }
    /// Microphone → virtual output: hardware latencies + 2 buffers (input and output) + plugins.
    public var estimatedTotalMs: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(inputDeviceFrames + outputDeviceFrames + 2 * bufferFrames + virtualBufferFrames) / sampleRate * 1000 + pluginSeconds * 1000
    }
}

/// Virtual output verification by reading back BlackHole's input.
public enum VirtualLoopbackStatus: Equatable, Sendable {
    case unknown
    /// The written signal is read back on the virtual device's input (what OBS, FaceTime… read).
    case confirmed(delayMs: Double, levelDiffDB: Double)
    /// Signal is being sent but nothing is read back.
    case noReturn
    case unavailable

    public var label: String {
        switch self {
        case .unknown: return String(localized: "Virtual output: waiting for signal")
        case .confirmed(let d, let l): return String(localized: "Virtual output verified: signal read back as OBS would read it (difference \(String(format: "%.1f", l)) dB, measured delay \(String(format: "%.1f", d)) ms)")
        case .noReturn: return String(localized: "Virtual output: signal sent but not read back")
        case .unavailable: return String(localized: "Virtual output: verification unavailable")
        }
    }
}

public struct EngineNotice: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case info, warning, error }
    public let id = UUID()
    public let kind: Kind
    public let message: String
    public let date = Date()
}

/// Orchestrator: devices, real-time engine, graph, plugins, presets.
/// All methods run on the main thread; the audio thread is only touched
/// through `RealtimeProcessor` (lock-free).
@Observable
@MainActor
public final class VoxFlowAirEngine {
    // MARK: Subsystems
    @ObservationIgnored public let processor = RealtimeProcessor(maxFrames: 4096)
    @ObservationIgnored public let deviceManager = AudioDeviceManager()
    @ObservationIgnored public let catalog = PluginCatalog()
    @ObservationIgnored public let presetStore: PresetStore
    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored private let aggregate = AggregateDeviceBuilder()
    @ObservationIgnored private var io: HALIOUnit!
    @ObservationIgnored private lazy var probe = LoopbackProbe(meters: processor.meters)
    @ObservationIgnored public private(set) var runtime: GraphRuntime?
    @ObservationIgnored private var pluginUnits: [UUID: AVAudioUnit] = [:]
    @ObservationIgnored private var instantiating = Set<UUID>()
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastCycles = 0
    @ObservationIgnored private var stalledTicks = 0
    @ObservationIgnored private var restartWork: DispatchWorkItem?
    @ObservationIgnored private var settingsSaveWork: DispatchWorkItem?
    @ObservationIgnored private var sessionSaveWork: DispatchWorkItem?
    @ObservationIgnored private var invalidationObserver: NSObjectProtocol?
    @ObservationIgnored private var aggregateListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    // MARK: Observable state
    public private(set) var state: EngineState = .stopped
    public private(set) var devices: [AudioDevice] = []
    public private(set) var activeInput: AudioDevice?
    public private(set) var activeVirtual: AudioDevice?
    public private(set) var activeMonitor: AudioDevice?
    public private(set) var virtualStatus: VirtualDeviceSupport.Status = .notInstalled
    public private(set) var voxflowairAirDriverStatus: VoxFlowAirDriverSupport.Status = .notInstalled
    public private(set) var latency = LatencyReport()
    /// Physical stream bit depth, read when the engine starts.
    public private(set) var inputBitDepth: Int?
    public private(set) var virtualBitDepth: Int?
    /// Every effect Audio Unit found on the system.
    public private(set) var installedPlugins: [PluginInfo] = []
    /// Plugins offered in the library: `installedPlugins` filtered by `settings.pluginFilter`.
    public private(set) var plugins: [PluginInfo] = []
    public private(set) var presets: [Preset] = []
    public private(set) var notices: [EngineNotice] = []
    public private(set) var nodeStatus: [UUID: NodeRuntimeStatus] = [:]
    public private(set) var issues: [GraphIssue] = []
    public private(set) var restartCount = 0
    public private(set) var loopbackStatus: VirtualLoopbackStatus = .unknown
    @ObservationIgnored private var loopbackTicks = 0
    /// Apps for which monitoring is paused (call in progress), nil otherwise.
    public private(set) var monitorPausedForCall: String?
    @ObservationIgnored private var warnedBlackHoleCalls = Set<pid_t>()
    @ObservationIgnored private var watchdogTicks = 0
    @ObservationIgnored private var recentRestarts: [Date] = []
    @ObservationIgnored private var matchTimer: Timer?
    @ObservationIgnored private var inLoud: LoudnessMeter?
    @ObservationIgnored private var outLoud: LoudnessMeter?
    /// Loudness difference measured continuously between the processed output and the input (LU), while speaking.
    public private(set) var processingLoudnessGain: Double?
    @ObservationIgnored private var diagTone: DirectToneWriter?
    @ObservationIgnored public let virtualWriter = VirtualOutputWriter()
    @ObservationIgnored public let callReturn = CallReturnReader()
    /// Device whose audio is mixed into the headphones (call return), nil if inactive.
    public private(set) var callReturnDeviceName: String?
    @ObservationIgnored private var loopbackLogCount = 0
    public private(set) var safeMode = false
    public private(set) var previousSessionCrashed = false

    /// Preferences (saved automatically).
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.pluginFilter != oldValue.pluginFilter { plugins = settings.pluginFilter.apply(to: installedPlugins) }
            applyControls(); scheduleSettingsSave()
        }
    }

    /// Graph of the active chain (working copy).
    public private(set) var graph: ProcessingGraph = .defaultGraph()
    public private(set) var activePresetID: UUID?
    public private(set) var isDirty = false
    @ObservationIgnored private var undoStack: [ProcessingGraph] = []
    @ObservationIgnored private var redoStack: [ProcessingGraph] = []
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    /// Global bypass (not persisted: VoxFlowAir always restarts in processed mode).
    public var bypassProcessing = false {
        didSet { processor.control.bypass.value = bypassProcessing }
    }

    public var activePreset: Preset? { activePresetID.flatMap { presetStore.preset($0) } }

    // MARK: Lifecycle

    /// Factory presets shipped with the app (can be restored at any time).
    public private(set) var factoryPresets: [Preset] = []
    @ObservationIgnored private let factoryDirectory: URL?

    public init(presetDirectory: URL = AppPaths.presets, settingsURL: URL = AppPaths.settings, factoryPresetsDirectory: URL? = nil) {
        factoryDirectory = factoryPresetsDirectory
        presetStore = PresetStore(directory: presetDirectory)
        settingsStore = SettingsStore(url: settingsURL)
        settings = settingsStore.load()
        io = HALIOUnit(processor: processor)
        if let w = settingsStore.lastLoadWarning { post(.warning, w) }
        VFUtilityAudioUnit.registerOnce()
        applyControls()
    }

    /// App launch.
    public func launch(safeMode requestedSafeMode: Bool = false, startAudio: Bool = true) {
        previousSessionCrashed = CrashSentinel.previousLaunchCrashed()
        CrashSentinel.markRunning()
        safeMode = requestedSafeMode
        rescanPlugins()
        presets = presetStore.load()
        for e in presetStore.loadErrors { post(.warning, e) }
        factoryPresets = FactoryPresets.load(directory: factoryDirectory)
        installNewFactoryPresets()
        if presets.isEmpty {
            if let p = try? presetStore.create(name: String(localized: "Default"), graph: .defaultGraph()) { presets = presetStore.presets; settings.activePresetID = p.id }
        }
        let target = settings.activePresetID.flatMap { id in presets.first { $0.id == id } } ?? presets.first
        if let target { loadPresetModel(target) }
        // Recovers an unsaved session (unexpected quit).
        if let session = SessionAutosave.load(), session.presetID == activePresetID, session.graph != graph {
            graph = session.graph
            isDirty = true
            post(.info, String(localized: "Unsaved changes from the last session were restored."))
        }
        devices = deviceManager.devices
        deviceManager.onDevicesChanged = { [weak self] list in
            MainActor.assumeIsolated { self?.devicesChanged(list) }
        }
        observePluginInvalidation()
        refreshVirtualStatus()
        instantiateMissingPlugins()
        if settings.engineEnabled && startAudio { start() }
        startWatchdog()
        startLevelMatch()
    }

    /// Continuously measures (5 Hz, off the audio thread) the short-term loudness of the input and
    /// the processed output, to offer a loudness-matched bypass.
    private func startLevelMatch() {
        matchTimer?.invalidate()
        matchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isRunning else { return }
                let sr = self.latency.sampleRate > 0 ? self.latency.sampleRate : 48000
                if self.inLoud?.sampleRate != sr { self.inLoud = LoudnessMeter(sampleRate: sr); self.outLoud = LoudnessMeter(sampleRate: sr) }
                let m = self.processor.meters
                self.inLoud!.update(left: m.inputTap.left, right: m.inputTap.right)
                self.outLoud!.update(left: m.outputTap.left, right: m.outputTap.right)
                let i = self.inLoud!.shortTermLUFS, o = self.outLoud!.shortTermLUFS
                // Update only while speaking and outside bypass (otherwise output = input).
                if i.isFinite, o.isFinite, i > -45, !self.bypassProcessing {
                    let g = o - i
                    self.processingLoudnessGain = self.processingLoudnessGain.map { $0 * 0.9 + g * 0.1 } ?? g
                }
                let target = self.settings.bypassLevelMatch ? Float(min(max(self.processingLoudnessGain ?? 0, -24), 24)) : 0
                self.processor.control.bypassMatchDB.store(target)
            }
        }
    }

    /// Clean shutdown (app quitting).
    public func shutdown() {
        if isDirty { SessionAutosave.save(presetID: activePresetID, graph: captureGraphWithStates()) }
        else { SessionAutosave.clear() }
        settingsStore.save(settings)
        stop()
        CrashSentinel.markCleanExit()
    }

    // MARK: Engine

    public func setEngineEnabled(_ on: Bool) {
        settings.engineEnabled = on
        if on { start() } else { stop() }
    }

    /// Microphone access authorization (TCC). Without it, Core Audio blocks opening the input.
    public private(set) var microphoneAccess: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    public func start() {
        state = .starting
        microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphoneAccess {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
                        if granted { self.start() }
                        else { self.state = .error(String(localized: "Microphone access denied")) }
                    }
                }
            }
            return
        default:
            state = .error(String(localized: "Microphone access denied"))
            post(.error, String(localized: "VoxFlowAir does not have access to the microphone. Allow it in System Settings › Privacy & Security › Microphone, then restart the engine."))
            return
        }
        do {
            try startIO()
            state = .running
            stalledTicks = 0
        } catch {
            stopIO()
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state = .error(msg)
            post(.error, String(localized: "Could not start the engine: \(msg)"))
            vlog(.error, "Engine start: \(error)")
        }
    }

    public func stop() {
        stopIO()
        state = .stopped
    }

    /// Full restart (audio reset). `userRequested` restarts never count toward the restart-loop safeguard.
    public func restart(reason: String, userRequested: Bool = false) {
        vlog(.info, "Restarting engine: \(reason)")
        restartCount += 1
        // Safeguard: no more than 5 automatic restarts in 30 s.
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 30 } + [now]
        if recentRestarts.count > 5 && !userRequested {
            stopIO()
            state = .error(String(localized: "Restart loop"))
            post(.error, String(localized: "The engine had to restart more than 5 times in 30 s (\(reason)). It has been stopped to protect your audio: check your devices, then start it again."))
            return
        }
        stopIO()
        guard settings.engineEnabled else { state = .stopped; return }
        state = .recovering(reason)
        start()
    }

    private func resolveDevices() -> (input: AudioDevice?, virtual: AudioDevice?, monitor: AudioDevice?) {
        let list = deviceManager.refresh()
        devices = list
        var preferredInput = settings.inputUID
        if let uid = preferredInput, VoxFlowAirDriverSupport.wouldLoop(inputUID: uid, virtualUID: settings.virtualUID) {
            post(.warning, String(localized: "The selected microphone is VoxFlowAir's own virtual output (audio loop): using the default microphone instead."))
            preferredInput = nil
        }
        let input = preferredInput.flatMap { uid in list.first { $0.uid == uid && $0.hasInput && $0.isAlive } }
            ?? AudioDeviceManager.defaultInputUID().flatMap { uid in list.first { $0.uid == uid && $0.hasInput && !$0.isVirtual } }
            ?? list.first { $0.hasInput && !$0.isVirtual }
        // Virtual output: explicit choice, otherwise BlackHole (proven behavior), otherwise the VoxFlowAir driver.
        // The VoxFlowAir driver's feed device is hidden: it is not in the list, so it is resolved by its UID.
        let voxflowairAirFeed = VoxFlowAirDriverSupport.deviceID(uid: VoxFlowAirDriverSupport.feedUID).flatMap(AudioDevice.read)
        let virtual = settings.virtualUID.flatMap { uid in
                VoxFlowAirDriverSupport.isFeed(uid: uid) ? voxflowairAirFeed : list.first { $0.uid == uid && $0.hasOutput } }
            ?? list.first { VirtualDeviceSupport.isBlackHole(uid: $0.uid, name: $0.name) && $0.hasOutput }
            ?? voxflowairAirFeed
        var monitor: AudioDevice?
        if let m = settings.monitorUID {
            monitor = list.first { $0.uid == m && $0.hasOutput && $0.isAlive }
            if monitor == nil && settings.monitorFallbackToSystem {
                // Selected device missing: fall back to the system output, with a notice.
                monitor = AudioDeviceManager.defaultOutputUID().flatMap { uid in list.first { $0.uid == uid && !$0.isVirtual } }
                let fallbackName = monitor?.name ?? String(localized: "no output")
                post(.warning, String(localized: "Selected headphones unavailable: monitoring switched to “\(fallbackName)”. It will switch back automatically when the device is reconnected."))
            } else if monitor == nil {
                post(.warning, String(localized: "Selected headphones unavailable: monitoring paused (automatic fallback is turned off in Settings)."))
            }
        } else {
            // Default: the system output, if it is a physical device.
            monitor = AudioDeviceManager.defaultOutputUID().flatMap { uid in list.first { $0.uid == uid && !$0.isVirtual } }
        }
        if monitor?.uid == virtual?.uid { monitor = nil }
        return (input, virtual, monitor)
    }

    private func startIO() throws {
        stopIO()
        let (input, virtual, monitor) = resolveDevices()
        guard let input else { throw RuntimeError(String(localized: "No input device available.")) }
        activeInput = input; activeVirtual = virtual; activeMonitor = monitor
        inputBitDepth = AudioDevice.physicalBitDepth(input.id, scope: kAudioObjectPropertyScopeInput)
        virtualBitDepth = virtual.flatMap { AudioDevice.physicalBitDepth($0.id, scope: kAudioObjectPropertyScopeOutput) }
        if virtual == nil { post(.warning, String(localized: "No virtual output: the processed signal is not sent to any app. Install “VoxFlowAir Micro” or BlackHole (Settings › Virtual Output).")) }

        // The virtual output is not part of the aggregate: it has its own direct stream.
        let devID = try aggregate.create(.init(inputUID: input.uid, virtualUID: nil, monitorUID: monitor?.uid))
        let rate = settings.sampleRate.flatMap { r in input.availableSampleRates.contains(r) ? r : nil } ?? input.nominalSampleRate
        do { try aggregate.setSampleRate(rate) } catch { post(.warning, String(localized: "Sample rate \(Int(rate)) Hz rejected by the device: \(String(describing: error))")) }
        let sr = aggregate.sampleRate > 0 ? aggregate.sampleRate : rate
        let frames = min(max(settings.bufferFrames, input.bufferFrameSizeRange.lowerBound), input.bufferFrameSizeRange.upperBound)
        do { try aggregate.setBufferSize(frames) } catch { post(.warning, String(localized: "Buffer size \(frames) rejected: \(String(describing: error))")) }

        // Graph: reuse the engine if the sample rate is unchanged.
        if let rt = runtime, abs(rt.sampleRate - sr) > 0.5 {
            rt.releasePlugins()
            runtime = nil
        }
        if runtime == nil { runtime = try GraphRuntime(sampleRate: sr, processor: processor) }
        applyGraph()

        io.virtualWriter = virtual == nil ? nil : virtualWriter
        if let v = virtual {
            do { try virtualWriter.start(deviceID: v.id, sampleRate: sr, bufferFrames: aggregate.bufferSize) }
            catch { post(.error, String(localized: "Could not open the virtual output: \(String(describing: error))")); io.virtualWriter = nil }
        }
        startCallReturn(sampleRate: sr, input: input, virtual: virtual, monitor: monitor)
        try io.start(.init(deviceID: devID, sampleRate: sr, layout: aggregate.layout,
                           inputChannels: settings.inputChannels, maxFrames: processor.maxFrames))
        installAggregateListeners(devID)
        if let v = virtual {
            let loopUID = VoxFlowAirDriverSupport.loopbackInputUID(forVirtual: v.uid)
            let loopID = loopUID == v.uid ? v.id : (VoxFlowAirDriverSupport.deviceID(uid: loopUID) ?? v.id)
            do { try probe.start(deviceID: loopID, sampleRate: sr) }
            catch { vlog(.warning, "Virtual output verification probe unavailable: \(error)") }
            loopbackStatus = .unknown; loopbackTicks = 0; loopbackLogCount = 0
            if ProcessInfo.processInfo.environment["VOXFLOWAIR_DIAG_TONE"] == "1" {
                let t = DirectToneWriter()
                do { try t.start(deviceID: v.id, sampleRate: sr); diagTone = t; vlog(.info, "Diagnostics: 440 Hz -30 dBFS tone written directly to \(v.name)") }
                catch { vlog(.error, "Diagnostic tone: \(error)") }
            }
        }
        updateLatency()
        refreshVirtualStatus()
        let virtualName = virtual?.name ?? String(localized: "no virtual output")
        let monitorPart = monitor.map { String(localized: ", monitoring on \($0.name)") } ?? ""
        post(.info, String(localized: "Engine running: \(input.name) → \(virtualName)\(monitorPart) at \(Int(sr)) Hz, buffer \(aggregate.bufferSize)."))
    }

    private func stopIO() {
        if monitorPausedForCall != nil { monitorPausedForCall = nil; applyControls() }
        removeAggregateListeners()
        probe.stop()
        virtualWriter.stop()
        diagTone?.stop(); diagTone = nil
        io.stop()
        callReturn.stop(); io.callReturn = nil; callReturnDeviceName = nil
        runtime?.stop()
        aggregate.destroy()
    }

    private func applyControls() {
        let c = processor.control
        c.inputGainDB.store(Float(settings.inputGainDB))
        c.virtualGainDB.store(Float(settings.virtualGainDB))
        c.monitorGainDB.store(Float(settings.monitorGainDB))
        c.muteVirtual.value = settings.muteVirtual
        c.monitorEnabled.value = settings.monitorEnabled && monitorPausedForCall == nil
        callReturn.gainDB.store(Float(settings.callReturnGainDB))
        c.bypass.value = bypassProcessing
    }

    public func updateLatency() {
        let id = aggregate.deviceID
        guard id != 0 else { latency = LatencyReport(); return }
        var r = LatencyReport()
        r.sampleRate = aggregate.sampleRate
        r.bufferFrames = aggregate.bufferSize
        let inLat = Int(CA.get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, default: UInt32(0)))
        let inSafe = Int(CA.get(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, default: UInt32(0)))
        let outLat = Int(CA.get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, default: UInt32(0)))
        let outSafe = Int(CA.get(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, default: UInt32(0)))
        r.inputDeviceFrames = inLat + inSafe + AudioDevice.streamLatency(id, scope: kAudioObjectPropertyScopeInput)
        r.outputDeviceFrames = outLat + outSafe + AudioDevice.streamLatency(id, scope: kAudioObjectPropertyScopeOutput)
        r.pluginSeconds = mainPathPluginLatency()
        if activeVirtual != nil { r.virtualBufferFrames = virtualWriter.targetFrames }
        latency = r
    }

    /// Longest plugin latency between the input and the virtual output.
    private func mainPathPluginLatency() -> Double {
        guard let order = graph.topologicalOrder() else { return 0 }
        var acc: [UUID: Double] = [:]
        for id in order {
            let incoming = graph.incoming(id).map { acc[$0.from] ?? 0 }.max() ?? 0
            let own = pluginUnits[id].map { $0.auAudioUnit.latency } ?? 0
            acc[id] = incoming + (graph.node(id).map { graph.isEffectivelyBypassed($0) } == true ? 0 : own)
        }
        return graph.outputNode.flatMap { acc[$0.id] } ?? 0
    }

    // MARK: Health checks

    private func devicesChanged(_ list: [AudioDevice]) {
        devices = list
        refreshVirtualStatus()
        guard settings.engineEnabled else { return }
        var uids = Set(list.map(\.uid))
        if VoxFlowAirDriverSupport.deviceID(uid: VoxFlowAirDriverSupport.feedUID) != nil { uids.insert(VoxFlowAirDriverSupport.feedUID) }
        let used = [activeInput?.uid, activeVirtual?.uid, activeMonitor?.uid].compactMap { $0 }
        let lost = used.filter { !uids.contains($0) }
        // A preferred device came back, or a device in use disappeared → restart.
        let preferredBack = [settings.inputUID, settings.virtualUID, settings.monitorUID].compactMap { $0 }
            .contains { uid in uids.contains(uid) && !used.contains(uid) }
        let blackHoleAppeared = activeVirtual == nil && (list.contains { VirtualDeviceSupport.isBlackHole(uid: $0.uid, name: $0.name) }
            || uids.contains(VoxFlowAirDriverSupport.feedUID))
        if !lost.isEmpty {
            post(.warning, String(localized: "Device disconnected: \(lost.joined(separator: ", ")). Reconfiguring…"))
            scheduleRestart(String(localized: "device disconnected"))
        } else if preferredBack || blackHoleAppeared || state != .running {
            scheduleRestart(String(localized: "device available"))
        }
    }

    private func scheduleRestart(_ reason: String, delay: TimeInterval = 0.4) {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.restart(reason: reason) } }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func installAggregateListeners(_ dev: AudioObjectID) {
        removeAggregateListeners()
        let selectors: [(AudioObjectPropertySelector, String)] = [
            (kAudioDevicePropertyNominalSampleRate, String(localized: "sample rate changed")),
            (kAudioDevicePropertyDeviceIsAlive, String(localized: "device unavailable")),
            (kAudioAggregateDevicePropertyActiveSubDeviceList, String(localized: "device composition changed")),
        ]
        let startedAt = Date()
        let expectedSubs = aggregate.subDeviceUIDs.count
        for (sel, reason) in selectors {
            var a = CA.address(sel)
            let expectedRate = aggregate.sampleRate
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.aggregate.deviceID == dev else { return }
                    // Ignore setup notifications right after starting.
                    if Date().timeIntervalSince(startedAt) < 2 { return }
                    switch sel {
                    case kAudioDevicePropertyNominalSampleRate:
                        if abs(self.aggregate.sampleRate - expectedRate) < 0.5 { return }
                    case kAudioDevicePropertyDeviceIsAlive:
                        if CA.get(dev, kAudioDevicePropertyDeviceIsAlive, default: UInt32(1)) != 0 { return }
                    case kAudioAggregateDevicePropertyActiveSubDeviceList:
                        let active = CA.getArray(dev, kAudioAggregateDevicePropertyActiveSubDeviceList, of: AudioObjectID.self).count
                        if active >= expectedSubs { return }
                    default: break
                    }
                    self.post(.warning, String(localized: "Audio: \(reason). Resetting the engine."))
                    self.scheduleRestart(reason)
                }
            }
            if AudioObjectAddPropertyListenerBlock(dev, &a, .main, block) == noErr { aggregateListeners.append((a, block)) }
        }
    }

    private func removeAggregateListeners() {
        let dev = aggregate.deviceID
        for (addr, block) in aggregateListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(dev, &a, .main, block)
        }
        aggregateListeners = []
    }

    /// Detects a stalled engine (no audio cycle for 3 s) and restarts it.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .running else { return }
                self.watchdogTicks += 1
                if self.watchdogTicks % 2 == 0 { self.checkOtherAudioApps() }
                self.verifyLoopback()
                let c = self.processor.meters.cycles.value
                if c == self.lastCycles { self.stalledTicks += 1 } else { self.stalledTicks = 0 }
                self.lastCycles = c
                if self.stalledTicks >= 3 {
                    self.stalledTicks = 0
                    self.post(.error, String(localized: "Audio has been interrupted for 3 s: restarting automatically."))
                    self.restart(reason: String(localized: "audio interrupted"))
                }
            }
        }
    }

    /// Compares what is written to the virtual output with what BlackHole returns on its input.
    private func verifyLoopback() {
        let m = processor.meters
        let v = m.verifyVirtualPeak.take(), l = m.verifyLoopbackPeak.take()
        guard activeVirtual != nil else { loopbackStatus = .unavailable; return }
        if loopbackLogCount < 12 {
            loopbackLogCount += 1
            vlog(.debug, String(format: "Virtual output check: written %.1f dBFS, read back %.1f dBFS, input %.1f dBFS; probe: %d callbacks; buffer %.0f frames, drift %.0f ppm, under/overruns %d/%d", linearToDB(v), linearToDB(l), linearToDB(m.input.peak[0].load()), probe.callbacks.value, virtualWriter.fillFrames.load(), virtualWriter.ratioPPM.load(), virtualWriter.underruns.value, virtualWriter.overruns.value))
        }
        guard v > 0.003 else { return } // silence or mute: nothing to verify
        loopbackTicks += 1
        let previous = loopbackStatus
        if l < v * 0.01 {
            if loopbackTicks >= 3 { loopbackStatus = .noReturn }
        } else if loopbackTicks % 5 == 1 || { if case .confirmed = previous { return false }; return true }() {
            let delay = measureLoopbackDelay()
            loopbackStatus = .confirmed(delayMs: delay ?? -1, levelDiffDB: Double(20 * log10f(max(l, 1e-9) / v)))
        }
        if loopbackStatus != previous {
            switch (previous, loopbackStatus) {
            case (.confirmed, .confirmed): break
            case (_, .confirmed): post(.info, loopbackStatus.label)
            case (_, .noReturn): post(.error, noReturnMessage())
            default: break
            }
        }
    }

    private func noReturnMessage() -> String {
        let base = String(localized: "The virtual output does not return the signal sent: apps (OBS, FaceTime…) may receive nothing.")
        // An app that captures other apps' audio (FineTune, SoundSource…) cuts VoxFlowAir's output at the
        // source and replays it on its own device: silence for apps reading the virtual microphone,
        // and monitoring heard twice (headphones + replayed virtual output).
        let taps = CallAudioPolicy.interceptors(AudioProcesses.running())
        guard !taps.isEmpty else { return base + " " + String(localized: "Check the virtual device, then restart the engine.") }
        return base + " " + String(localized: "Likely cause: \(CallAudioPolicy.names(taps)) captures app audio. It cuts what VoxFlowAir sends and replays it elsewhere, which also causes an echo in monitoring. Exclude VoxFlowAir in that app (in FineTune: pencil, then the eye next to VoxFlowAir) and restart the engine.")
    }

    /// Call return: what FaceTime (or another app) plays into BlackHole is mixed into the
    /// headphones. Inactive if BlackHole already carries the processed voice (virtual output) or is the input.
    private func startCallReturn(sampleRate: Double, input: AudioDevice, virtual: AudioDevice?, monitor: AudioDevice?) {
        callReturnDeviceName = nil
        guard settings.callReturnEnabled, monitor != nil,
              let bh = devices.first(where: { VirtualDeviceSupport.isBlackHole(uid: $0.uid, name: $0.name) && $0.hasInput }),
              bh.uid != virtual?.uid, bh.uid != input.uid else { return }
        do {
            try callReturn.start(deviceID: bh.id, name: bh.name, sampleRate: sampleRate, bufferFrames: aggregate.bufferSize)
            io.callReturn = callReturn
            callReturnDeviceName = bh.name
        } catch { vlog(.warning, "Call return unavailable: \(error)") }
    }

    public func setCallReturnEnabled(_ on: Bool) {
        settings.callReturnEnabled = on
        restartIfEnabled(String(localized: "call return"))
    }

    /// Watches other audio apps: a call that would treat monitoring as echo,
    /// or a call app connected to BlackHole.
    private func checkOtherAudioApps() {
        guard let v = activeVirtual else { return }
        let procs = AudioProcesses.running()
        let loopUID = VoxFlowAirDriverSupport.loopbackInputUID(forVirtual: v.uid)
        let micName = VoxFlowAirDriverSupport.isFeed(uid: v.uid) ? (VoxFlowAirDriverSupport.currentMicName() ?? VoxFlowAirDriverSupport.micName) : v.name

        let listeners = settings.pauseMonitorDuringCalls
            ? CallAudioPolicy.listenersOnMonitor(procs, loopbackUID: loopUID, monitorUID: activeMonitor?.uid) : []
        let pausedFor = listeners.isEmpty ? nil : CallAudioPolicy.names(listeners)
        if pausedFor != monitorPausedForCall {
            let wasPaused = monitorPausedForCall != nil
            monitorPausedForCall = pausedFor
            applyControls()
            if let p = pausedFor, settings.monitorEnabled {
                let monitorName = activeMonitor?.name ?? String(localized: "the headphones")
                var msg = String(localized: "Monitoring paused: \(p) is listening to “\(micName)” and playing on “\(monitorName)”. Its echo canceller would erase your voice. Monitoring will resume when the call ends.")
                if let r = callReturnDeviceName {
                    msg += " " + String(localized: "To hear yourself during the call, choose “\(r)” as the speaker in the app: VoxFlowAir will play the other party in your headphones.")
                }
                post(.info, msg)
            } else if pausedFor == nil, wasPaused, settings.monitorEnabled {
                post(.info, String(localized: "Call ended: monitoring restored."))
            }
        }

        let onBlackHole = CallAudioPolicy.callAppsOnBlackHole(procs, loopbackUID: loopUID, loopbackName: v.name)
        let pids = Set(onBlackHole.map(\.pid))
        if !pids.subtracting(warnedBlackHoleCalls).isEmpty {
            post(.warning, String(localized: "\(CallAudioPolicy.names(onBlackHole)) is listening to BlackHole: its echo canceller erases the voice going through BlackHole, so the other party may not hear you. Use the VoxFlowAir microphone: Settings › Virtual Output “VoxFlowAir Micro (VoxFlowAir driver)”, then choose that microphone in the call."))
        }
        warnedBlackHoleCalls = pids
    }

    /// Delay (ms) between writing to the virtual output and reading it back, by cross-correlation.
    private func measureLoopbackDelay() -> Double? {
        let n = 8192, maxLag = 4096
        var a = [Float](repeating: 0, count: n), b = a
        a.withUnsafeMutableBufferPointer { _ = processor.meters.virtualTap.left.readLatest(into: $0.baseAddress!, count: n) }
        b.withUnsafeMutableBufferPointer { _ = processor.meters.loopbackTap.left.readLatest(into: $0.baseAddress!, count: n) }
        var best: Float = 0, bestLag = -1
        let len = n - maxLag
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                for lag in 0..<maxLag {
                    var d: Float = 0
                    // b (read back) lags a (written): b[t + lag] ≈ a[t].
                    vDSP_dotpr(ap.baseAddress! + (n - len - lag), 1, bp.baseAddress! + (n - len), 1, &d, vDSP_Length(len))
                    if d > best { best = d; bestLag = lag }
                }
            }
        }
        guard bestLag >= 0, latency.sampleRate > 0 else { return nil }
        return Double(bestLag) / latency.sampleRate * 1000
    }

    private func observePluginInvalidation() {
        // An out-of-process plugin that crashes is “invalidated” by macOS:
        // VoxFlowAir keeps running and the node becomes transparent.
        invalidationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: kAudioComponentInstanceInvalidationNotification as String),
            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let au = note.object as? AUAudioUnit else { return }
                guard let (id, _) = self.pluginUnits.first(where: { $0.value.auAudioUnit === au }) else { return }
                let name = self.graph.node(id)?.title ?? "plugin"
                self.pluginUnits[id] = nil
                self.nodeStatus[id] = .crashed
                self.post(.error, String(localized: "The plugin “\(name)” stopped. It is bypassed; its saved settings are kept. Use “Reload” on the node."))
                self.applyGraph(statusOverride: [id: .crashed])
            }
        }
    }

    // MARK: Graph

    /// Applies the model to the engine (rebuilds the connections).
    public func applyGraph(statusOverride: [UUID: NodeRuntimeStatus] = [:]) {
        var status: [UUID: NodeRuntimeStatus] = [:]
        for n in graph.nodes where n.kind == .audioUnit {
            if let o = statusOverride[n.id] { status[n.id] = o }
            else if pluginUnits[n.id] != nil { status[n.id] = .ok }
            else if instantiating.contains(n.id) { status[n.id] = .loading }
            else if let s = nodeStatus[n.id], case .failed = s { status[n.id] = s }
            else if nodeStatus[n.id] == .crashed { status[n.id] = .crashed }
            else { status[n.id] = .missing }
        }
        if let rt = runtime {
            let units = pluginUnits.filter { status[$0.key] == .ok }
            let result = rt.apply(graph, plugins: units, pluginStatus: status)
            nodeStatus = result
        } else {
            nodeStatus = status
        }
        let missing = Set(nodeStatus.filter { $0.value == .missing }.map(\.key))
        let failed = Set(nodeStatus.filter { if case .failed = $0.value { return true }; return $0.value == .crashed }.map(\.key))
        issues = GraphValidator.validate(graph, missingPlugins: missing, failedPlugins: failed)
        updateLatency()
    }

    /// Starts instantiating plugins that are not loaded yet.
    private func instantiateMissingPlugins() {
        for n in graph.nodes where n.kind == .audioUnit && pluginUnits[n.id] == nil && !instantiating.contains(n.id) {
            guard let ref = n.plugin else { continue }
            if safeMode { nodeStatus[n.id] = .failed(String(localized: "safe mode")); continue }
            if nodeStatus[n.id] == .crashed { continue }
            if !catalog.isInstalled(ref) { nodeStatus[n.id] = .missing; continue }
            instantiating.insert(n.id)
            nodeStatus[n.id] = .loading
            let mode = n.loadMode ?? settings.pluginLoadMode
            let state = n.pluginState
            let id = n.id
            Task { @MainActor in
                var unit: AVAudioUnit?
                var lastError: Error?
                for m in (mode == .outOfProcess ? [PluginLoadMode.outOfProcess, .inProcess] : [mode]) {
                    do { unit = try await PluginHost.instantiate(ref, mode: m); break }
                    catch { lastError = error; vlog(.warning, "Loading \(ref.name) (\(m.rawValue)): \(error)") }
                }
                self.instantiating.remove(id)
                // The node may have been deleted while loading.
                guard self.graph.node(id) != nil else { return }
                if let unit {
                    if let state, !PluginHost.restoreState(unit, data: state) {
                        self.post(.warning, String(localized: "The saved settings of “\(ref.name)” could not be restored. They are still kept in the preset."))
                    }
                    self.pluginUnits[id] = unit
                    self.nodeStatus[id] = .ok
                } else {
                    let msg = lastError.map { ($0 as? LocalizedError)?.errorDescription ?? "\($0)" } ?? String(localized: "unknown")
                    self.nodeStatus[id] = .failed(msg)
                    self.post(.error, String(localized: "Could not load “\(ref.name)”: \(msg). The node is bypassed."))
                }
                self.applyGraph()
            }
        }
        applyGraph()
    }

    public func pluginUnit(for node: UUID) -> AVAudioUnit? { pluginUnits[node] }

    /// Reports a change made inside a plugin (preset, pasted state…).
    public func markDirty() { isDirty = true; scheduleSessionSave() }
    public func meter(for node: UUID) -> LevelMeter? { runtime?.meter(for: node) }
    public func analyzerTap(for node: UUID) -> StereoAnalysisTap? { runtime?.analyzerTap(for: node) }
    public func nodeTap(for node: UUID) -> StereoAnalysisTap? { runtime?.tap(for: node) }

    /// Previous / next preset (alphabetical order).
    public func cyclePreset(_ delta: Int) {
        guard !presets.isEmpty else { return }
        let i = presets.firstIndex { $0.id == activePresetID } ?? 0
        let n = (i + delta + presets.count) % presets.count
        if isDirty { saveActivePreset() }
        loadPreset(presets[n].id)
    }

    /// Automatically arranges the main chain in rows (“serpentine” layout).
    public func arrangeGraph(rowWidth: Double = 1500) {
        mutate(rewire: false) { $0.arrangeMainChain(rowWidth: rowWidth) }
    }

    /// Changes the buffer size (exact value, limited by the device).
    public func setBufferFrames(_ frames: Int) {
        settings.customBufferFrames = frames
        restartIfEnabled(String(localized: "buffer size changed"))
    }

    /// Reloads a plugin (after a crash or failure).
    public func reloadPlugin(_ id: UUID) {
        pluginUnits[id] = nil
        nodeStatus[id] = nil
        instantiateMissingPlugins()
    }

    // MARK: Editing (with undo)

    private func mutate(rewire: Bool = true, undoable: Bool = true, _ body: (inout ProcessingGraph) throws -> Void) rethrows {
        let before = graph
        var g = graph
        try body(&g)
        guard g != before else { return }
        if undoable {
            undoStack.append(before)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        graph = g
        isDirty = true
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        scheduleSessionSave()
        if rewire { instantiateMissingPlugins() } else { issues = GraphValidator.validate(graph, missingPlugins: Set(nodeStatus.filter { $0.value == .missing }.map(\.key))) }
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(graph)
        graph = prev
        isDirty = true
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        cleanupRemovedPlugins()
        instantiateMissingPlugins()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(graph)
        graph = next
        isDirty = true
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        cleanupRemovedPlugins()
        instantiateMissingPlugins()
    }

    private func cleanupRemovedPlugins() {
        let ids = Set(graph.nodes.map(\.id))
        for k in pluginUnits.keys where !ids.contains(k) { pluginUnits[k] = nil }
    }

    /// Single entry point for adding a node.
    @discardableResult
    public func addNode(kind: NodeKind, plugin: PluginReference? = nil, at position: GraphPoint? = nil,
                        insertOn connection: UUID? = nil, appendToChain: Bool = false) -> UUID? {
        if kind.isUnique, graph.nodes.contains(where: { $0.kind == kind }) {
            post(.warning, String(localized: "There can be only one “\(kind.displayName)” node."))
            return nil
        }
        var node = GraphNode(kind: kind, position: position ?? GraphPoint(x: 300, y: 380), plugin: plugin,
                             parameters: kind == .gain ? ["gain": 0] : [:])
        if kind == .audioUnit, let ref = plugin { node.title = ref.name }
        do {
            try mutate { g in
                if let c = connection { g = try g.inserting(node, on: c) }
                else if appendToChain && node.kind.hasInputPort && node.kind.hasOutputPort { g = try g.appendingToMainChain(node) }
                else { g.addNode(node) }
            }
        } catch {
            post(.warning, String(localized: "Could not add “\(node.title)”: \(String(describing: error)) The chain was not changed."))
            return nil
        }
        if kind == .audioUnit, let ref = plugin { notePluginUsed(ref) }
        return node.id
    }

    public func removeNode(_ id: UUID) {
        guard let n = graph.node(id) else { return }
        if n.kind == .input || n.kind == .output { post(.warning, String(localized: "The input and the virtual output cannot be deleted.")); return }
        do { try mutate { g in g = try g.removingNode(id) } }
        catch { post(.warning, String(localized: "Could not delete “\(n.title)”: \(String(describing: error))")); return }
        pluginUnits[id] = nil
        nodeStatus[id] = nil
    }

    /// Moves a node in the chain (onto the connection `connection`) in a single graph
    /// application. The plugin is not reloaded: its instance is kept.
    /// If refused, nothing changes (neither the graph nor the sound); the error is returned and reported.
    @discardableResult
    public func moveInChain(_ id: UUID, onto connection: UUID, position: GraphPoint? = nil) -> ChainEditError? {
        do {
            try mutate { g in g = try g.movingInChain(id, onto: connection, position: position) }
            return nil
        } catch let e as ChainEditError {
            if e != .noChange { post(.warning, String(localized: "Move refused: \(String(describing: e))")) }
            return e
        } catch {
            return .unknownNode
        }
    }

    /// Moves a node right before `before` on the main chain (nil: right before the output).
    @discardableResult
    public func moveInMainChain(_ id: UUID, before: UUID?) -> ChainEditError? {
        guard let target = before ?? graph.outputNode?.id,
              let c = graph.mainChainConnection(into: target) else {
            post(.warning, String(localized: "Move refused: the virtual output is not fed by the input."))
            return .unknownConnection
        }
        return moveInChain(id, onto: c.id)
    }

    public func duplicateNode(_ id: UUID) {
        guard var n = graph.node(id), !n.kind.isUnique else { return }
        if n.kind == .audioUnit, let u = pluginUnits[id] { n.pluginState = PluginHost.captureState(u) ?? n.pluginState }
        n.id = UUID()
        n.position = GraphPoint(x: n.position.x + 40, y: n.position.y + 120)
        n.title = String(localized: "\(n.title) copy")
        let copy = n
        mutate { $0.addNode(copy) }
    }

    public func moveNode(_ id: UUID, to p: GraphPoint, registerUndo: Bool) {
        mutate(rewire: false, undoable: registerUndo) { g in
            if let i = g.index(of: id) { g.nodes[i].position = p }
        }
    }

    public func moveNodes(_ moves: [UUID: GraphPoint], registerUndo: Bool) {
        mutate(rewire: false, undoable: registerUndo) { g in
            for (id, p) in moves { if let i = g.index(of: id) { g.nodes[i].position = p } }
        }
    }

    public func connect(from: UUID, to: UUID) {
        do { try mutate { _ = try $0.connect(from: from, to: to) } }
        catch { post(.warning, "\(error)") }
    }

    public func disconnect(_ connection: UUID) { mutate { $0.disconnect(connection) } }

    public func setNodeBypass(_ id: UUID, _ bypassed: Bool) {
        mutate(rewire: false) { g in if let i = g.index(of: id) { g.nodes[i].bypassed = bypassed } }
        runtime?.setBypass(graph)
        updateLatency()
    }

    public func renameNode(_ id: UUID, _ title: String) {
        mutate(rewire: false) { g in if let i = g.index(of: id) { g.nodes[i].title = title } }
    }

    public func setGain(_ id: UUID, db: Double, registerUndo: Bool) {
        mutate(rewire: false, undoable: registerUndo) { g in if let i = g.index(of: id) { g.nodes[i].parameters["gain"] = db } }
        runtime?.setGain(node: id, db: db)
    }

    public func setNodeLoadMode(_ id: UUID, _ mode: PluginLoadMode?) {
        if let u = pluginUnits[id] {
            mutate(rewire: false) { g in if let i = g.index(of: id) { g.nodes[i].pluginState = PluginHost.captureState(u) } }
        }
        mutate(rewire: false) { g in if let i = g.index(of: id) { g.nodes[i].loadMode = mode } }
        reloadPlugin(id)
    }

    public func createGroup(name: String, nodes ids: Set<UUID>) {
        let group = NodeGroup(name: name, colorIndex: graph.groups.count % 6)
        mutate(rewire: false) { g in
            g.groups.append(group)
            for i in g.nodes.indices where ids.contains(g.nodes[i].id) && !g.nodes[i].kind.isUnique { g.nodes[i].groupID = group.id }
        }
    }

    public func removeGroup(_ id: UUID) {
        mutate(rewire: false) { g in
            g.groups.removeAll { $0.id == id }
            for i in g.nodes.indices where g.nodes[i].groupID == id { g.nodes[i].groupID = nil }
        }
        runtime?.setBypass(graph)
    }

    public func setGroupBypass(_ id: UUID, _ bypassed: Bool) {
        mutate(rewire: false) { g in if let i = g.groups.firstIndex(where: { $0.id == id }) { g.groups[i].bypassed = bypassed } }
        runtime?.setBypass(graph)
        updateLatency()
    }

    public func renameGroup(_ id: UUID, _ name: String) {
        mutate(rewire: false) { g in if let i = g.groups.firstIndex(where: { $0.id == id }) { g.groups[i].name = name } }
    }

    /// The view (zoom, position) is saved with the preset without marking it as modified.
    public func setViewport(_ v: GraphViewport) {
        graph.viewport = v
    }

    public func ungroupNode(_ id: UUID) {
        mutate(rewire: false) { g in if let i = g.index(of: id) { g.nodes[i].groupID = nil } }
        runtime?.setBypass(graph)
    }

    // MARK: Favorite / recent plugins

    public func toggleFavorite(_ ref: PluginReference) {
        if let i = settings.favoritePlugins.firstIndex(of: ref.identifier) { settings.favoritePlugins.remove(at: i) }
        else { settings.favoritePlugins.append(ref.identifier) }
    }

    private func notePluginUsed(_ ref: PluginReference) {
        var r = settings.recentPlugins.filter { $0 != ref.identifier }
        r.insert(ref.identifier, at: 0)
        settings.recentPlugins = Array(r.prefix(15))
    }

    public func rescanPlugins() {
        installedPlugins = catalog.scan()
        plugins = settings.pluginFilter.apply(to: installedPlugins)
    }

    // MARK: Presets

    /// Current graph with the current state of each loaded plugin.
    public func captureGraphWithStates() -> ProcessingGraph {
        var g = graph
        for i in g.nodes.indices where g.nodes[i].kind == .audioUnit {
            if let u = pluginUnits[g.nodes[i].id], let data = PluginHost.captureState(u) { g.nodes[i].pluginState = data }
            // Otherwise: the previously saved state is kept as is (plugin missing or failed).
        }
        return g
    }

    private func currentRouting() -> PresetRouting {
        PresetRouting(inputGainDB: settings.inputGainDB, virtualGainDB: settings.virtualGainDB,
                      monitorGainDB: settings.monitorGainDB, inputChannels: settings.inputChannels,
                      bufferFrames: activePreset?.routing?.bufferFrames,
                      virtualUID: settings.virtualUID, virtualDeviceName: settings.virtualDeviceName)
    }

    private func loadPresetModel(_ p: Preset) {
        graph = p.graph
        activePresetID = p.id
        settings.activePresetID = p.id
        isDirty = false
        undoStack.removeAll(); redoStack.removeAll()
        canUndo = false; canRedo = false
        if let r = p.routing {
            if let v = r.inputGainDB { settings.inputGainDB = v }
            if let v = r.virtualGainDB { settings.virtualGainDB = v }
            if let v = r.monitorGainDB { settings.monitorGainDB = v }
            if let ch = r.inputChannels, ch != settings.inputChannels { settings.inputChannels = ch; if state.isRunning { scheduleRestart(String(localized: "preset input channels")) } }
            if let b = r.bufferFrames, b != settings.bufferFrames { settings.customBufferFrames = b; if state.isRunning { scheduleRestart(String(localized: "preset buffer size")) } }
            if let uid = r.virtualUID, uid != settings.virtualUID {
                settings.virtualUID = uid
                if state.isRunning { scheduleRestart(String(localized: "preset virtual output")) }
            }
            if let n = r.virtualDeviceName, n != settings.virtualDeviceName {
                settings.virtualDeviceName = n
                applyVirtualDeviceName()
            }
        }
    }

    public func loadPreset(_ id: UUID) {
        guard let p = presetStore.preset(id) else { return }
        // Releases the previous chain's instances.
        pluginUnits.removeAll()
        nodeStatus.removeAll()
        loadPresetModel(p)
        SessionAutosave.clear()
        instantiateMissingPlugins()
        post(.info, String(localized: "Preset “\(p.name)” loaded."))
    }

    public func saveActivePreset() {
        guard let id = activePresetID, var p = presetStore.preset(id) else { saveAsNewPreset(name: String(localized: "New Preset")); return }
        p.graph = captureGraphWithStates()
        p.routing = currentRouting()
        do {
            try presetStore.write(p)
            graph = p.graph
            isDirty = false
            presets = presetStore.presets
            SessionAutosave.clear()
        } catch { post(.error, String(localized: "Could not save the preset: \(error.localizedDescription)")) }
    }

    public func saveAsNewPreset(name: String) {
        do {
            let p = try presetStore.create(name: name, graph: captureGraphWithStates(), routing: currentRouting())
            presets = presetStore.presets
            activePresetID = p.id
            settings.activePresetID = p.id
            graph = p.graph
            isDirty = false
            SessionAutosave.clear()
        } catch { post(.error, String(localized: "Could not create the preset: \(error.localizedDescription)")) }
    }

    public func newPreset(name: String, routing: PresetRouting? = nil) {
        do {
            let p = try presetStore.create(name: name, graph: .defaultGraph(), routing: routing)
            presets = presetStore.presets
            loadPreset(p.id)
        } catch { post(.error, String(localized: "Could not create the preset: \(error.localizedDescription)")) }
    }

    public func duplicatePreset(_ id: UUID) {
        do { _ = try presetStore.duplicate(id); presets = presetStore.presets }
        catch { post(.error, String(localized: "Could not duplicate the preset: \(error.localizedDescription)")) }
    }

    public func renamePreset(_ id: UUID, to name: String) {
        do { try presetStore.rename(id, to: name); presets = presetStore.presets }
        catch { post(.error, String(localized: "Could not rename the preset: \(error.localizedDescription)")) }
    }

    public func setPresetFavorite(_ id: UUID, _ fav: Bool) {
        try? presetStore.setFavorite(id, fav); presets = presetStore.presets
    }

    public func deletePreset(_ id: UUID) {
        do {
            try presetStore.delete(id)
            presets = presetStore.presets
            if activePresetID == id {
                if let first = presets.first { loadPreset(first.id) }
                else { newPreset(name: String(localized: "Default")) }
            }
            post(.info, String(localized: "Preset moved to the Trash."))
        } catch { post(.error, String(localized: "Could not delete the preset: \(error.localizedDescription)")) }
    }

    public func exportPreset(_ id: UUID, to url: URL) {
        do {
            if id == activePresetID && isDirty { saveActivePreset() }
            try presetStore.export(id, to: url)
        } catch { post(.error, String(localized: "Could not export the preset: \(error.localizedDescription)")) }
    }

    public func importPreset(from url: URL) {
        do {
            let p = try presetStore.importPreset(from: url)
            presets = presetStore.presets
            let missing = p.pluginReferences.filter { !catalog.isInstalled($0) }
            post(missing.isEmpty ? .info : .warning,
                 String(localized: "Preset “\(p.name)” imported.") + (missing.isEmpty ? "" : " " + String(localized: "Missing plugins: \(missing.map(\.name).joined(separator: ", ")) (settings kept).")))
        } catch { post(.error, String(localized: "Could not import the preset: \(error.localizedDescription)")) }
    }

    /// Discards unsaved changes.
    // MARK: Factory presets

    /// Installs each new factory preset once (without overwriting an existing preset).
    private func installNewFactoryPresets() {
        var installed: [String] = []
        for f in factoryPresets where !settings.factoryPresetsOffered.contains(f.id) {
            if presetStore.preset(f.id) == nil {
                do { try presetStore.write(f); installed.append(f.name) }
                catch { post(.error, String(localized: "Could not install the factory preset “\(f.name)”: \(error.localizedDescription)")); continue }
            }
            settings.factoryPresetsOffered.append(f.id)
        }
        if !installed.isEmpty {
            presets = presetStore.presets
            post(.info, String(localized: "Factory presets added: \(installed.joined(separator: ", "))."))
        }
    }

    public func factoryVersion(of id: UUID) -> Preset? { factoryPresets.first { $0.id == id } }

    /// True if the saved preset differs from its factory version.
    public func isModifiedFromFactory(_ id: UUID) -> Bool {
        guard let f = factoryVersion(of: id), let p = presetStore.preset(id) else { return false }
        return FactoryPresets.differs(p, from: f)
    }

    /// Factory presets deleted by the user.
    public var missingFactoryPresets: [Preset] { factoryPresets.filter { f in !presets.contains { $0.id == f.id } } }

    /// Replaces the preset with its factory version (the replaced version stays in the .bak file).
    public func restoreFactoryVersion(_ id: UUID) {
        guard var f = factoryVersion(of: id) else { return }
        f.isFavorite = presetStore.preset(id)?.isFavorite ?? false
        do {
            try presetStore.write(f)
            presets = presetStore.presets
            if activePresetID == id {
                pluginUnits.removeAll(); nodeStatus.removeAll()
                loadPresetModel(presetStore.preset(id) ?? f)
                SessionAutosave.clear()
                instantiateMissingPlugins()
            }
            post(.info, String(localized: "“\(f.name)” restored to its factory version."))
        } catch { post(.error, String(localized: "Could not restore the preset: \(error.localizedDescription)")) }
    }

    /// Reinstalls deleted factory presets.
    public func restoreMissingFactoryPresets() {
        for f in missingFactoryPresets {
            do { try presetStore.write(f) } catch { post(.error, String(localized: "Could not restore “\(f.name)”: \(error.localizedDescription)")) }
        }
        presets = presetStore.presets
    }

    /// Saves the current chain over an existing preset (“Save As” to a name already in use).
    public func overwritePreset(_ id: UUID) {
        guard var p = presetStore.preset(id) else { return }
        p.graph = captureGraphWithStates()
        p.routing = currentRouting()
        do {
            try presetStore.write(p)
            presets = presetStore.presets
            activePresetID = id
            settings.activePresetID = id
            graph = p.graph
            isDirty = false
            SessionAutosave.clear()
            post(.info, String(localized: "“\(p.name)” replaced with the current chain."))
        } catch { post(.error, String(localized: "Could not save the preset: \(error.localizedDescription)")) }
    }

    public func revertPreset() {
        guard let id = activePresetID else { return }
        loadPreset(id)
    }

    // MARK: Devices

    public func selectInput(_ uid: String) { settings.inputUID = uid; settings.inputChannels = [0, 1]; restartIfEnabled(String(localized: "input changed")) }
    public func selectVirtual(_ uid: String?) { settings.virtualUID = uid; restartIfEnabled(String(localized: "virtual output changed")) }
    public func selectMonitor(_ uid: String?) { settings.monitorUID = uid; restartIfEnabled(String(localized: "monitoring changed")) }
    public func setSampleRate(_ r: Double?) { settings.sampleRate = r; restartIfEnabled(String(localized: "sample rate changed")) }
    public func setLatencyProfile(_ p: LatencyProfile) { settings.latency = p; settings.customBufferFrames = nil; restartIfEnabled(String(localized: "buffer size changed")) }
    public func setInputChannels(_ ch: [Int]) { settings.inputChannels = ch; restartIfEnabled(String(localized: "input channels changed")) }

    private func restartIfEnabled(_ reason: String) {
        if settings.engineEnabled { restart(reason: reason) }
    }

    public func refreshVirtualStatus() {
        virtualStatus = VirtualDeviceSupport.status(devices: deviceManager.devices)
        voxflowairAirDriverStatus = VoxFlowAirDriverSupport.status()
        applyVirtualDeviceName()
    }

    /// Display name of “VoxFlowAir Micro” in apps (BlackHole's name cannot be changed).
    public func setVirtualDeviceName(_ name: String?) {
        settings.virtualDeviceName = VoxFlowAirDriverSupport.sanitizedName(name)
        applyVirtualDeviceName()
    }

    private func applyVirtualDeviceName() {
        guard voxflowairAirDriverStatus.isAvailable else { return }
        let wanted = VoxFlowAirDriverSupport.sanitizedName(settings.virtualDeviceName) ?? VoxFlowAirDriverSupport.micName
        guard VoxFlowAirDriverSupport.currentMicName() != wanted else { return }
        if VoxFlowAirDriverSupport.setMicName(wanted) { post(.info, String(localized: "Virtual microphone renamed “\(wanted)”.")) }
        else { post(.warning, String(localized: "The VoxFlowAir driver rejected the name “\(wanted)”.")) }
    }

    /// A usable virtual output exists (BlackHole or the VoxFlowAir driver).
    public var hasVirtualOutputAvailable: Bool {
        if case .available = virtualStatus { return true }
        return voxflowairAirDriverStatus.isAvailable
    }

    // MARK: Notifications

    public func post(_ kind: EngineNotice.Kind, _ message: String) {
        notices.append(EngineNotice(kind: kind, message: message))
        if notices.count > 100 { notices.removeFirst(notices.count - 100) }
        vlog(kind == .error ? .error : kind == .warning ? .warning : .info, message)
    }

    public func clearNotices() { notices.removeAll() }

    public func resetCounters() {
        let m = processor.meters
        for c in [m.deviceOverloads, m.nearOverruns, m.renderErrors, m.inputErrors, m.invalidSamples, m.transitionCycles,
                  m.input.clipCount, m.processed.clipCount, m.virtualOut.clipCount, m.monitorOut.clipCount] { c.reset() }
        _ = m.maxLoad.take()
    }

    // MARK: Deferred persistence

    private func scheduleSettingsSave() {
        settingsSaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if let self { self.settingsStore.save(self.settings) } } }
        settingsSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func scheduleSessionSave() {
        sessionSaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let self, self.isDirty { SessionAutosave.save(presetID: self.activePresetID, graph: self.graph) } }
        }
        sessionSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    // MARK: Diagnostics

    /// Reloads presets from disk (added externally or imported by a tool).
    @discardableResult
    public func reloadPresetsFromDisk() -> [Preset] {
        presets = presetStore.load()
        return presets
    }

    /// Numeric snapshot of the engine state (local control, diagnostics).
    public func statsSnapshot() -> [String: Any] {
        let m = processor.meters
        var plugins: [[String: Any]] = []
        for n in graph.nodes where n.kind == .audioUnit {
            plugins.append(["name": n.title, "status": nodeStatus[n.id]?.label ?? "-", "bypassed": graph.isEffectivelyBypassed(n),
                            "latencyMs": (pluginUnits[n.id]?.auAudioUnit.latency ?? 0) * 1000,
                            "inProcess": pluginUnits[n.id]?.auAudioUnit.isLoadedInProcess ?? false])
        }
        return [
            "state": state.label, "preset": activePreset?.name ?? "-", "dirty": isDirty,
            "sampleRate": latency.sampleRate, "bufferFrames": latency.bufferFrames,
            "inputDeviceFrames": latency.inputDeviceFrames, "outputDeviceFrames": latency.outputDeviceFrames,
            "virtualBufferFrames": latency.virtualBufferFrames, "pluginLatencyMs": latency.pluginSeconds * 1000,
            "estimatedTotalMs": latency.estimatedTotalMs, "monitorEstimatedMs": latency.monitorEstimatedMs,
            "cycles": m.cycles.value, "deviceOverloads": m.deviceOverloads.value, "nearOverruns": m.nearOverruns.value,
            "renderErrors": m.renderErrors.value, "inputErrors": m.inputErrors.value, "invalidSamples": m.invalidSamples.value,
            "maxLoad": m.maxLoad.load(), "virtualUnderruns": virtualWriter.underruns.value, "virtualOverruns": virtualWriter.overruns.value,
            "virtualDriftPPM": virtualWriter.ratioPPM.load(), "virtualTargetFrames": virtualWriter.targetFrames,
            "virtualProducerBlock": virtualWriter.producerBlock.load(), "virtualConsumerBlock": virtualWriter.consumerBlock.load(), "restarts": restartCount, "loopback": loopbackStatus.label, "monitorPausedForCall": monitorPausedForCall ?? "",
            "clipsInput": m.input.clipCount.value, "clipsProcessed": m.processed.clipCount.value, "clipsVirtual": m.virtualOut.clipCount.value,
            "input": activeInput?.name ?? "-", "virtual": activeVirtual?.name ?? "-", "monitor": activeMonitor?.name ?? "-",
            "monitorEnabled": settings.monitorEnabled, "bypassMatchDB": Double(processor.control.bypassMatchDB.load()), "muteVirtual": settings.muteVirtual, "bypass": bypassProcessing,
            "plugins": plugins,
        ]
    }

    public func diagnosticsReport() -> String {
        Diagnostics.report(engine: self)
    }
}
