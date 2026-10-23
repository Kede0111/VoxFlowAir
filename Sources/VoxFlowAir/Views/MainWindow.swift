import SwiftUI
import VoxFlowAirCore

/// Main window: native macOS 26+ structure (sidebar, inspector, toolbar).
/// Liquid Glass is reserved for what controls or navigates (toolbar, sidebar,
/// floating canvas capsules); the canvas, nodes, meters and dense text
/// stay on opaque backgrounds to remain legible.
struct MainWindow: View {
    @Environment(AppState.self) private var app
    @State private var bottomHeight: CGFloat = 230
    @State private var showNewPreset = false
    @State private var newPresetName = ""
    @State private var saveAsMode = false

    var body: some View {
        @Bindable var a = app
        NavigationSplitView(columnVisibility: $a.sidebarVisibility) {
            PluginLibrary()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if !app.engine.hasVirtualOutputAvailable { VirtualDeviceBanner() }
                NodeEditor()
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                ResizeHandle(height: $bottomHeight)
                // Zero minimum width: the bottom panel and status bar adapt instead of
                // imposing their width on the window (otherwise a layout conflict with the inspector).
                BottomPanel()
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: bottomHeight)
                    .clipped()
                    .background(VF.panel)
                Divider().overlay(VF.border)
                StatusBar()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            .background(VF.bg)
            .inspector(isPresented: $a.showInspector) {
                Inspector()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .foregroundStyle(VF.text)
        .navigationTitle("VoxFlowAir")
        .toolbar(removing: .title)
        .toolbar {
            MainToolbar(showNewPreset: $showNewPreset, newPresetName: $newPresetName, saveAsMode: $saveAsMode)
        }
        .sheet(isPresented: $showNewPreset) {
            PresetOutputSheet(title: saveAsMode ? "Save As" : "New Preset", saveAs: saveAsMode, name: $newPresetName)
                .environment(app)
        }
        .sheet(isPresented: $a.showBlackHoleAssistant) {
            BlackHoleAssistant().environment(app).frame(width: 560, height: 520)
        }
    }
}

struct ResizeHandle: View {
    @Binding var height: CGFloat
    @State private var start: CGFloat?
    var body: some View {
        Rectangle().fill(VF.border).frame(height: 1)
            .overlay(Rectangle().fill(Color.clear).frame(height: 7).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if start == nil { start = height }
                    height = min(max((start ?? height) - v.translation.height, 140), 520)
                }.onEnded { _ in start = nil }))
    }
}

// MARK: - Native toolbar

/// Groups: presets | undo / save | engine status | MONITOR · MUTE OUT · BYPASS | settings.
/// The three audio commands are independent items, executed immediately.
struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var app
    @Binding var showNewPreset: Bool
    @Binding var newPresetName: String
    @Binding var saveAsMode: Bool
    @State private var showMonitorPopover = false

    var body: some ToolbarContent {
        let e = app.engine
        ToolbarItem(placement: .navigation) {
            PresetMenu(showNewPreset: $showNewPreset, newPresetName: $newPresetName, saveAsMode: $saveAsMode)
        }
        ToolbarItemGroup(placement: .navigation) {
            Button { e.cyclePreset(-1) } label: { Label("Previous Preset", systemImage: "chevron.left") }
                .help("Previous preset")
            Button { e.cyclePreset(1) } label: { Label("Next Preset", systemImage: "chevron.right") }
                .help("Next preset")
            Button { saveAsMode = false; newPresetName = String(localized: "New Preset"); showNewPreset = true } label: { Label("New Preset", systemImage: "plus") }
                .help("New preset")
        }
        ToolbarSpacer(.fixed, placement: .navigation)
        ToolbarItemGroup(placement: .navigation) {
            Button { e.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!e.canUndo).help("Undo (⌘Z)")
            Button { e.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!e.canRedo).help("Redo (⇧⌘Z)")
            Button { e.saveActivePreset() } label: {
                Label("Save", systemImage: e.isDirty ? "square.and.arrow.down.fill" : "checkmark")
            }
            .foregroundStyle(e.isDirty ? VF.warn : VF.text3)
            .disabled(!e.isDirty).help(e.isDirty ? "Save preset (⌘S)" : "Preset saved")
        }

        ToolbarSpacer(.flexible)

        ToolbarItem {
            EngineStatusPill()
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            CommandToggle(title: "MONITOR", systemImage: "headphones", offImage: "headphones.slash",
                          isOn: e.settings.monitorEnabled, onColor: VF.ok, compact: true,
                          help: String(localized: "Listen to the processed signal on \(e.activeMonitor?.name ?? String(localized: "the headphones")). Does not affect the virtual output.")) {
                e.settings.monitorEnabled.toggle()
            }
            .popover(isPresented: $showMonitorPopover) { MonitorPopover().environment(app).padding(14).frame(width: 280) }
            .contextMenu { Button("Level and Device…") { showMonitorPopover = true } }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem {
            CommandToggle(title: "MUTE OUT", systemImage: "speaker.slash.fill", offImage: "speaker.wave.2.fill",
                          isOn: e.settings.muteVirtual, onColor: VF.danger, compact: true,
                          help: String(localized: "Mutes the signal sent to apps (virtual output). Monitoring continues.")) {
                e.settings.muteVirtual.toggle()
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem {
            CommandToggle(title: "BYPASS", systemImage: "arrow.triangle.turn.up.right.diamond.fill", offImage: "arrow.triangle.turn.up.right.diamond",
                          isOn: e.bypassProcessing, onColor: VF.warn, compact: true,
                          help: String(localized: "Bypasses the whole chain: the virtual output and monitoring receive the unprocessed microphone, with a crossfade. Plugins keep running for an instant return. ") + (e.settings.bypassLevelMatch ? String(localized: "Level matched: the raw signal is corrected by \(String(format: "%+.1f", e.processingLoudnessGain ?? 0)) dB (measured loudness difference) for a fair comparison.") : String(localized: "Raw level (not matched)."))) {
                e.bypassProcessing.toggle()
            }
            .contextMenu {
                Toggle("Loudness-matched bypass", isOn: Binding(get: { e.settings.bypassLevelMatch }, set: { e.settings.bypassLevelMatch = $0 }))
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            MeterPanelToggle(app: app)
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("Settings (⌘,)")
            Button { withAnimation(.snappy(duration: 0.2)) { app.showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help(app.showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
        }
    }
}

struct EngineStatusPill: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let e = app.engine
        let color: Color = {
            switch e.state {
            case .running: return app.meters.dropoutWarning ? VF.warn : VF.ok
            case .starting, .recovering: return VF.warn
            case .stopped: return VF.text3
            case .error: return VF.danger
            }
        }()
        HStack(spacing: 14) {
            Button { e.setEngineEnabled(!e.settings.engineEnabled) } label: {
                HStack(spacing: 6) {
                    StatusDot(color: color, size: 7)
                    Text(e.state.isRunning ? String(localized: "Running") : e.state.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.14)))
                .overlay(Capsule().strokeBorder(color.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help(e.settings.engineEnabled ? "Engine running — click to stop it" : "Engine stopped — click to start it")
            if e.state.isRunning {
                Text(String(format: "%.1f ms", e.latency.monitorEstimatedMs)).monospacedDigit()
                    .help(String(localized: "Estimated headphone latency · \(String(format: "%g", (e.latency.sampleRate / 100).rounded() / 10)) kHz"))
                Menu {
                    let range = e.activeInput?.bufferFrameSizeRange ?? 32...4096
                    ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { f in
                        if range.contains(f) {
                            Button { e.setBufferFrames(f) } label: {
                                if f == e.latency.bufferFrames { Label("\(f) samples", systemImage: "checkmark") } else { Text("\(f) samples") }
                            }
                        }
                    }
                } label: {
                    Text("\(e.latency.bufferFrames) samples").monospacedDigit()
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Buffer size. Smaller = less latency, higher risk of dropouts.")
            }
        }
        .font(.system(size: 11))
        .padding(.leading, 4).padding(.trailing, 8)
        .fixedSize()
        .help(latencyHelp(e.latency))
    }

    func latencyHelp(_ l: LatencyReport) -> String {
        func ms(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", v) }
        return String(localized: "Estimates (Core Audio properties + latencies reported by plugins), not measurements.\nHeadphones: ≈ \(ms(l.monitorEstimatedMs, 1)) ms · virtual output: ≈ \(ms(l.estimatedTotalMs, 1)) ms (including a \(l.virtualBufferFrames)-sample buffer)\nBuffer: \(l.bufferFrames) samples (\(ms(l.bufferMs, 2)) ms) ×2\nHardware input: \(l.inputDeviceFrames) samples · output: \(l.outputDeviceFrames) samples\nPlugins: \(ms(l.pluginSeconds * 1000, 2)) ms\nThe engine → BlackHole offset is measured separately (Settings › Diagnostics).\nThe app receiving the sound (OBS, FaceTime…) adds its own latency.")
    }
}

struct MonitorPopover: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var e = app.engine
        VStack(alignment: .leading, spacing: 10) {
            Text("Monitoring").font(VF.title)
            Toggle("Listen to the processed signal", isOn: $e.settings.monitorEnabled)
            HStack {
                Text("Level").font(VF.small)
                Slider(value: $e.settings.monitorGainDB, in: -60...12)
                Text(formatDB(e.settings.monitorGainDB)).font(VF.mono).frame(width: 64, alignment: .trailing)
            }
            Picker("Device", selection: Binding(get: { e.settings.monitorUID ?? "" },
                                                      set: { e.selectMonitor($0.isEmpty ? nil : $0) })) {
                Text("System default output").tag("")
                ForEach(e.deviceManager.physicalOutputDevices) { d in Text(d.name).tag(d.uid) }
            }
            Text("The monitoring level is independent of the virtual output.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PresetMenu: View {
    @Environment(AppState.self) private var app
    @Binding var showNewPreset: Bool
    @Binding var newPresetName: String
    @Binding var saveAsMode: Bool
    @State private var renaming = false
    @State private var renameText = ""

    var body: some View {
        let e = app.engine
        HStack(spacing: 6) {
            Menu {
                let favs = e.presets.filter(\.isFavorite)
                if !favs.isEmpty {
                    Section("Favorites") { ForEach(favs) { p in presetButton(p) } }
                }
                Section("Presets") { ForEach(e.presets) { p in presetButton(p) } }
                Divider()
                if let p = e.activePreset {
                    Button("Save “\(p.name)” (⌘S)") { e.saveActivePreset() }.disabled(!e.isDirty)
                }
                Button("New Preset…") { saveAsMode = false; newPresetName = String(localized: "New Preset"); showNewPreset = true }
                Button("Save As…") { saveAsMode = true; newPresetName = (e.activePreset?.name ?? "Preset") + " 2"; showNewPreset = true }
                if let p = e.activePreset {
                    Button("Duplicate “\(p.name)”") { e.duplicatePreset(p.id) }
                    Button("Rename…") { renameText = p.name; renaming = true }
                    Button(p.isFavorite ? "Remove from Favorites" : "Add to Favorites") { e.setPresetFavorite(p.id, !p.isFavorite) }
                    Divider()
                    Button("Export…") { exportPreset(p) }
                    Button("Import…") { importPreset() }
                    Divider()
                    Button("Revert to Saved") { e.revertPreset() }.disabled(!e.isDirty)
                    if e.factoryVersion(of: p.id) != nil {
                        Button("Restore Original Version…") { confirmFactoryRestore(p) }
                    }
                    Button("Delete “\(p.name)”…", role: .destructive) { confirmDelete(p) }
                }
                let missing = e.missingFactoryPresets
                if !missing.isEmpty {
                    Divider()
                    Button("Restore Deleted Factory Presets (\(missing.count))") { e.restoreMissingFactoryPresets() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(e.activePreset?.name ?? String(localized: "No Preset")).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if e.isDirty { Text("•").foregroundStyle(VF.warn).help("Unsaved changes") }
                }
            }
            .frame(width: 200, alignment: .leading)
            .padding(.horizontal, 6)
            .help(e.activePreset?.name ?? "Presets")
        }
        .sheet(isPresented: $renaming) {
            NamePrompt(title: "Rename Preset", name: $renameText) { n in
                if let id = e.activePresetID { e.renamePreset(id, to: n) }
            }
        }
    }

    @ViewBuilder func presetButton(_ p: Preset) -> some View {
        Button {
            if app.engine.isDirty && !confirmDiscard() { return }
            app.pluginWindows.closeAll()
            app.selectedNodes = []
            app.engine.loadPreset(p.id)
        } label: {
            if p.id == app.engine.activePresetID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
        }
    }

    func confirmDiscard() -> Bool {
        let a = NSAlert()
        a.messageText = String(localized: "Unsaved changes")
        a.informativeText = String(localized: "The current preset has unsaved changes. Save them before switching presets?")
        a.addButton(withTitle: String(localized: "Save"))
        a.addButton(withTitle: String(localized: "Don’t Save"))
        a.addButton(withTitle: String(localized: "Cancel"))
        switch a.runModal() {
        case .alertFirstButtonReturn: app.engine.saveActivePreset(); return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func confirmFactoryRestore(_ p: Preset) {
        let e = app.engine
        let a = NSAlert()
        a.messageText = String(localized: "Restore “\(p.name)” to its original version?")
        a.informativeText = e.isDirty || e.isModifiedFromFactory(p.id)
            ? String(localized: "Your changes to this preset will be replaced by the version shipped with VoxFlowAir. The replaced version stays in the backup file (.bak).")
            : String(localized: "This preset is already identical to its original version.")
        a.addButton(withTitle: String(localized: "Restore"))
        a.addButton(withTitle: String(localized: "Cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            app.pluginWindows.closeAll()
            e.restoreFactoryVersion(p.id)
        }
    }

    func confirmDelete(_ p: Preset) {
        let a = NSAlert()
        a.messageText = String(localized: "Delete “\(p.name)”?")
        a.informativeText = String(localized: "The preset file will be moved to the Trash (recoverable).")
        a.addButton(withTitle: String(localized: "Delete"))
        a.addButton(withTitle: String(localized: "Cancel"))
        if a.runModal() == .alertFirstButtonReturn { app.engine.deletePreset(p.id) }
    }

    func exportPreset(_ p: Preset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name).\(PresetStore.fileExtension)"
        panel.allowedContentTypes = [.init(filenameExtension: PresetStore.fileExtension) ?? .json]
        if panel.runModal() == .OK, let url = panel.url { app.engine.exportPreset(p.id, to: url) }
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: PresetStore.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { app.engine.importPreset(from: url) } }
    }
}

struct NamePrompt: View {
    let title: LocalizedStringKey
    @Binding var name: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(20)
    }
    func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onCommit(n); dismiss()
    }
}

// MARK: - Virtual output banner

struct VirtualDeviceBanner: View {
    @Environment(AppState.self) private var app
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VF.warn)
            switch app.engine.virtualStatus {
            case .installedNotLoaded(let v):
                Text("BlackHole \(v) is installed but macOS does not publish it yet. Restart the audio service or the Mac.")
            default:
                Text("No virtual output: OBS, FaceTime and other apps cannot receive VoxFlowAir yet.")
            }
            Spacer()
            Button("Install Virtual Output…") { app.showBlackHoleAssistant = true }.controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(VF.warn.opacity(0.12))
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppState.self) private var app
    @State private var showLog = false
    var body: some View {
        let e = app.engine
        let m = app.meters
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                StatusDot(color: e.bypassProcessing ? VF.warn : (e.state.isRunning ? VF.ok : VF.text3), size: 7)
                Text(e.bypassProcessing ? String(localized: "Bypass") : (e.state.isRunning ? String(localized: "Processing") : e.state.label))
                    .foregroundStyle(VF.text)
            }
            .fixedSize()
            Text(String(format: "CPU %.0f %%", min(m.load, 9.99) * 100)).monospacedDigit().fixedSize()
                .foregroundStyle(m.load > 0.8 ? VF.danger : (m.load > 0.5 ? VF.warn : VF.text2))
                .help("Share of the available time per audio cycle used by VoxFlowAir (recent maximum).")
            Text("Latency \(String(format: "%.1f", e.latency.estimatedTotalMs)) ms").monospacedDigit().fixedSize()
                .help("Estimated total latency to apps (not measured)")
            if m.overloads > 0 { counter("Dropouts", m.overloads, help: "Overloads reported by Core Audio (likely audio dropouts).") }
            if m.renderErrors > 0 { counter("Render errors", m.renderErrors, help: "Cycles where the graph could not be rendered (replaced with silence).") }
            if m.invalidSamples > 0 { counter("Invalid samples", m.invalidSamples, help: "NaN/infinite values produced by a plugin, neutralized.") }
            let errs = e.issues.filter { $0.severity >= .warning }.count
            if errs > 0 {
                Label("\(errs)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(VF.warn)
                    .help(e.issues.filter { $0.severity >= .warning }.map(\.message).joined(separator: "\n"))
            }
            Button { showLog.toggle() } label: {
                HStack(spacing: 4) {
                    if let last = e.notices.last {
                        Image(systemName: icon(last.kind)).foregroundStyle(color(last.kind))
                        Text(last.message).lineLimit(1).truncationMode(.tail).frame(minWidth: 40, maxWidth: 320, alignment: .leading)
                    } else { Image(systemName: "list.bullet.rectangle"); Text("Log") }
                }
            }
            .buttonStyle(.plain)
            .layoutPriority(-1)
            .help(e.notices.last?.message ?? String(localized: "Event log"))
            .popover(isPresented: $showLog) { NoticeLog().environment(app).frame(width: 520, height: 360) }
            Spacer()
            Image(systemName: "headphones").foregroundStyle(e.settings.monitorEnabled ? VF.ok : VF.text3)
                .onTapGesture { e.settings.monitorEnabled.toggle() }
                .help("Turn monitoring on / off")
            Picker("Monitoring", selection: Binding(get: { e.settings.monitorUID ?? "" }, set: { e.selectMonitor($0.isEmpty ? nil : $0) })) {
                Text("System output (\(e.activeMonitor?.name ?? "—"))").tag("")
                ForEach(e.deviceManager.physicalOutputDevices) { d in Text(d.name).tag(d.uid) }
            }
            .labelsHidden().controlSize(.small).frame(minWidth: 110, maxWidth: 190)
            .help("Monitoring device (headphones)")
            Slider(value: Binding(get: { e.settings.monitorGainDB }, set: { e.settings.monitorGainDB = ($0 * 2).rounded() / 2 }), in: -60...12)
                .controlSize(.mini).frame(width: 80)
                .help("Monitoring level: \(formatDB(e.settings.monitorGainDB))")
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .foregroundStyle(VF.text2)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(VF.panel)
    }

    func label(_ icon: String, _ title: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(verbatim: "\(title):").foregroundStyle(VF.text3)
            Text(value).foregroundStyle(warn ? VF.warn : VF.text2).lineLimit(1)
        }
    }

    func counter(_ title: LocalizedStringKey, _ v: Int, help: LocalizedStringKey) -> some View {
        Text("\(Text(title)) \(v)").foregroundStyle(v > 0 ? VF.warn : VF.text3).help(help)
    }

    func icon(_ k: EngineNotice.Kind) -> String {
        switch k { case .info: return "info.circle"; case .warning: return "exclamationmark.triangle"; case .error: return "xmark.octagon" }
    }
    func color(_ k: EngineNotice.Kind) -> Color {
        switch k { case .info: return VF.text2; case .warning: return VF.warn; case .error: return VF.danger }
    }
}

struct NoticeLog: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event Log").font(.headline)
                Spacer()
                Button("Clear") { app.engine.clearNotices() }
            }.padding(10)
            List(app.engine.notices.reversed()) { n in
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    Text(n.message).font(.system(size: 12))
                        .foregroundStyle(n.kind == .error ? VF.danger : (n.kind == .warning ? VF.warn : VF.text))
                }
            }
        }
    }
}
