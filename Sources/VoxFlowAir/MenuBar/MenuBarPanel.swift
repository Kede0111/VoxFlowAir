import SwiftUI
import VoxFlowAirCore

/// Compact menu bar panel: usable with the main window closed.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let e = app.engine
        let m = app.meters
        VStack(alignment: .leading, spacing: 12) {
            // Header.
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 16)).foregroundStyle(VF.accent)
                Text(verbatim: "VoxFlowAir").font(.system(size: 17, weight: .semibold))
                StatusDot(color: e.state.isRunning ? (m.dropoutWarning ? VF.warn : VF.ok) : (e.state == .stopped ? VF.text3 : VF.danger), size: 6)
                    .help(e.state.label)
                Spacer()
                Toggle("", isOn: Binding(get: { e.settings.engineEnabled }, set: { e.setEngineEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().help("Turn VoxFlowAir on or off")
            }

            // Preset + settings.
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { e.activePresetID ?? UUID() }, set: { id in
                    app.pluginWindows.closeAll(); app.selectedNodes = []
                    if e.isDirty { e.saveActivePreset() }
                    e.loadPreset(id)
                })) {
                    ForEach(e.presets) { p in Text(p.name + (p.isFavorite ? " ★" : "")).tag(p.id) }
                }
                .labelsHidden()
                Button { NSApp.activate(); openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.glass).help("Settings")
            }

            Divider()

            // Input / output meters.
            HStack(spacing: 10) {
                Image(systemName: e.state.isRunning ? "mic.fill" : "mic.slash")
                    .font(.system(size: 20)).foregroundStyle(VF.text)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 9).fill(VF.panel3))
                VStack(spacing: 8) {
                    meterRow("Input", m.input, clip: m.clipInput)
                    meterRow("Output", m.virtualOut, clip: m.clipOutput, dim: e.settings.muteVirtual)
                }
            }

            // Monitoring.
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(VF.text2)
                Text("Monitoring").font(.system(size: 12))
                Spacer()
                Menu {
                    Button("System Default Output") { e.selectMonitor(nil) }
                    Divider()
                    ForEach(e.deviceManager.physicalOutputDevices) { d in Button(d.name) { e.selectMonitor(d.uid) } }
                } label: {
                    Label(e.activeMonitor?.name ?? String(localized: "None"), systemImage: "headphones").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Slider(value: Binding(get: { e.settings.monitorGainDB }, set: { e.settings.monitorGainDB = ($0 * 2).rounded() / 2 }), in: -60...12)
                    .controlSize(.small)
                Text(formatDB(e.settings.monitorGainDB)).font(VF.mono).frame(width: 62, alignment: .trailing)
            }

            // Three independent commands.
            // Native glass buttons, each independent and immediate.
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    CommandToggle(title: "MONITOR", systemImage: "headphones", offImage: "headphones.slash", isOn: e.settings.monitorEnabled, onColor: VF.ok,
                                  compact: true, help: String(localized: "Headphone monitoring")) { e.settings.monitorEnabled.toggle() }
                    CommandToggle(title: "MUTE", systemImage: "speaker.slash.fill", offImage: "speaker.wave.2.fill", isOn: e.settings.muteVirtual, onColor: VF.danger,
                                  compact: true, help: String(localized: "Mutes the virtual output (apps)")) { e.settings.muteVirtual.toggle() }
                    CommandToggle(title: "BYPASS", systemImage: "arrow.triangle.turn.up.right.diamond.fill", offImage: "arrow.triangle.turn.up.right.diamond", isOn: e.bypassProcessing, onColor: VF.warn,
                                  compact: true, help: String(localized: "Unprocessed signal")) { e.bypassProcessing.toggle() }
                }
                .frame(maxWidth: .infinity)
            }

            // Technical status.
            VStack(alignment: .leading, spacing: 4) {
                infoRow("arrow.up.forward.app", e.activeVirtual.map { String(localized: "Virtual output: \($0.name)") } ?? String(localized: "Virtual output unavailable"), ok: e.activeVirtual != nil)
                if case .confirmed = e.loopbackStatus { infoRow("checkmark.seal", String(localized: "Signal read back from the virtual output"), ok: true) }
                if e.loopbackStatus == .noReturn { infoRow("exclamationmark.triangle.fill", String(localized: "Virtual output: no return"), ok: false) }
                if e.state.isRunning {
                    infoRow("timer", String(format: String(localized: "Estimated latency ≈ %.1f ms · %d samples · %.0f kHz"), e.latency.estimatedTotalMs, e.latency.bufferFrames, e.latency.sampleRate / 1000), ok: true)
                }
                if m.dropoutWarning || m.overloads > 0 { infoRow("exclamationmark.triangle.fill", String(localized: "Audio dropouts detected: \(m.overloads)"), ok: false) }
                let failing = e.nodeStatus.values.filter { !$0.isHealthy && $0 != .loading }.count
                if failing > 0 { infoRow("puzzlepiece.extension", String(localized: "\(failing) plugin(s) failed or missing"), ok: false) }
                if case .error(let msg) = e.state { infoRow("xmark.octagon.fill", msg, ok: false) }
            }

            Button { openWindow(id: "main"); NSApp.setActivationPolicy(.regular); NSApp.activate() } label: {
                HStack {
                    Text("Open VoxFlowAir").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(VF.text)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            HStack {
                Spacer()
                Button { NSApp.activate(); openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { e.restart(reason: String(localized: "user request"), userRequested: true) } label: { Image(systemName: "arrow.clockwise") }.help("Restart the audio engine")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit VoxFlowAir")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    func meterRow(_ title: LocalizedStringKey, _ l: MeterHub.Level, clip: Bool, dim: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.text2).frame(width: 44, alignment: .leading)
            HorizontalMeter(level: l).frame(height: 9).opacity(dim ? 0.35 : 1)
            Text(l.maxPeak > 0.000_001 ? String(format: "%.1f dB", linearToDB(l.maxPeak)) : "-∞").font(.system(size: 10, design: .monospaced)).frame(width: 52, alignment: .trailing)
            Circle().fill(clip ? VF.danger : VF.panel3).frame(width: 7, height: 7)
                .onTapGesture { app.meters.resetClips() }
                .help(clip ? "Clipping detected (click to clear)" : "No clipping")
        }
    }

    func infoRow(_ icon: String, _ text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(ok ? VF.text2 : VF.warn).frame(width: 14)
            Text(text).font(.system(size: 11)).foregroundStyle(ok ? VF.text2 : VF.warn).lineLimit(2)
        }
    }
}
