import SwiftUI
import ServiceManagement
import VoxFlowAirCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AudioSettings().tabItem { Label("Audio", systemImage: "waveform") }
            VirtualSettings().tabItem { Label("Virtual Output", systemImage: "arrow.up.forward.app") }
            PluginSettings().tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
    }
}

struct AudioSettings: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let e = app.engine
        Form {
            Picker("Microphone / input interface", selection: Binding(get: { e.settings.inputUID ?? e.activeInput?.uid ?? "" }, set: { e.selectInput($0) })) {
                ForEach(e.deviceManager.inputDevices.filter { !VoxFlowAirDriverSupport.isMic(uid: $0.uid) }) { d in Text("\(d.name) (\(d.inputChannels) ch)").tag(d.uid) }
            }
            InputChannelPicker()
            Picker("Virtual output", selection: Binding(get: { e.settings.virtualUID ?? e.activeVirtual?.uid ?? "" }, set: { e.selectVirtual($0.isEmpty ? nil : $0) })) {
                Text("Automatic (BlackHole, otherwise VoxFlowAir Micro)").tag("")
                if e.voxflowairAirDriverStatus.isAvailable || e.settings.virtualUID == VoxFlowAirDriverSupport.feedUID {
                    Text("\(VoxFlowAirDriverSupport.micName) (VoxFlowAir driver)").tag(VoxFlowAirDriverSupport.feedUID)
                }
                ForEach(e.deviceManager.virtualDevices) { d in Text(d.name).tag(d.uid) }
            }
            if e.activeVirtual.map({ VoxFlowAirDriverSupport.isFeed(uid: $0.uid) }) == true {
                VirtualNameField()
                Text("Saved with the preset. BlackHole keeps the name set by its driver.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Monitoring (headphones)", selection: Binding(get: { e.settings.monitorUID ?? "" }, set: { e.selectMonitor($0.isEmpty ? nil : $0) })) {
                Text("System default output").tag("")
                ForEach(e.deviceManager.physicalOutputDevices) { d in Text(d.name).tag(d.uid) }
            }
            LabeledContent("Headphones in use", value: e.activeMonitor?.name ?? String(localized: "none"))
            Toggle("If the headphones disappear, switch to the system output (with a message)", isOn: Binding(get: { e.settings.monitorFallbackToSystem }, set: { e.settings.monitorFallbackToSystem = $0 }))
            Toggle("Pause monitoring during a call that plays on these headphones", isOn: Binding(get: { e.settings.pauseMonitorDuringCalls }, set: { e.settings.pauseMonitorDuringCalls = $0 }))
            Text(e.monitorPausedForCall.map { String(localized: "Paused right now: \($0) is using VoxFlowAir on these headphones.") }
                 ?? String(localized: "FaceTime and other calling apps cancel everything that plays on their speaker as echo: if VoxFlowAir monitors your voice there, the other person can no longer hear you."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Call return: hear what plays into BlackHole in the headphones", isOn: Binding(get: { e.settings.callReturnEnabled }, set: { e.setCallReturnEnabled($0) }))
            if e.settings.callReturnEnabled {
                LabeledContent("Call return level") {
                    HStack {
                        Slider(value: Binding(get: { e.settings.callReturnGainDB }, set: { e.settings.callReturnGainDB = $0.rounded() }), in: -30...12)
                        Text(String(format: "%+.0f dB", e.settings.callReturnGainDB)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Text(e.callReturnDeviceName.map { String(localized: "Active. In FaceTime (Video › Output), choose “\($0)”: you hear the call and your processed voice in the headphones, without FaceTime cancelling it.") }
                 ?? String(localized: "Inactive: requires BlackHole, monitoring headphones, and a virtual output other than BlackHole (VoxFlowAir Micro)."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Sample rate", selection: Binding(get: { e.settings.sampleRate ?? 0 }, set: { e.setSampleRate($0 == 0 ? nil : $0) })) {
                Text("Same as microphone (\(Int(e.activeInput?.nominalSampleRate ?? 0)) Hz)").tag(0.0)
                ForEach(e.activeInput?.availableSampleRates ?? [], id: \.self) { r in Text(verbatim: "\(Int(r)) Hz").tag(r) }
            }
            Picker("Latency profile", selection: Binding(get: { e.settings.latency }, set: { e.setLatencyProfile($0) })) {
                ForEach(LatencyProfile.allCases, id: \.self) { p in
                    let range = e.activeInput?.bufferFrameSizeRange
                    let ok = range.map { $0.contains(p.frames) } ?? true
                    Text(ok ? "\(p.displayName) — \(p.frames) samples" : "\(p.displayName) — \(p.frames) samples (not supported)").tag(p)
                }
            }
            Text("A shorter buffer reduces latency but increases the risk of audio dropouts with demanding plugins. If overloads appear, choose a more stable profile.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Estimated latency", value: String(localized: "\(String(format: "%.1f", e.latency.estimatedTotalMs)) ms (not measured)"))
            HStack {
                Button("Restart Audio Engine") { e.restart(reason: String(localized: "user request"), userRequested: true) }
                if e.microphoneAccess != .authorized {
                    Button("Allow Microphone Access…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct VirtualSettings: View {
    @Environment(AppState.self) private var app
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VoxFlowAirDriverPanel()
                Divider()
                BlackHoleAssistant(embedded: true)
            }
        }
    }
}

struct PluginSettings: View {
    @Environment(AppState.self) private var app
    @State private var search = ""
    var body: some View {
        @Bindable var e = app.engine
        let filter = e.settings.pluginFilter
        Form {
            Section("Loading") {
                Picker("Load plugins", selection: $e.settings.pluginLoadMode) {
                    ForEach(PluginLoadMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("“Isolated Process”: the plugin runs in a separate system service (AUHostingService). If it crashes, VoxFlowAir keeps running and bypasses the node. “Inside VoxFlowAir”: best compatibility, but a faulty plugin can quit VoxFlowAir. If a plugin fails to load isolated, VoxFlowAir retries inside its own process.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                Picker("Show", selection: Binding(get: { filter.mode }, set: { m in e.settings.pluginFilter.mode = m })) {
                    Text("All installed Audio Units").tag(PluginSelectionMode.all)
                    Text("Only the plugins I choose").tag(PluginSelectionMode.allowlist)
                }
                Toggle("Include Audio Unit extensions from apps (AUv3)", isOn: $e.settings.pluginFilter.includeAUv3)
                Toggle("Include music effects (aumf)", isOn: $e.settings.pluginFilter.includeMusicEffects)
                Toggle("Show multichannel variants (5.1, 7.1, Ambisonics…)", isOn: $e.settings.showMultichannelPlugins)
                LabeledContent("Plugins") { Text("\(e.plugins.count) shown of \(e.installedPlugins.count) installed") }
                HStack {
                    Button("Scan Again") { e.rescanPlugins() }
                    Button("Open Components Folder") { openComponentsFolder() }
                }
                Text("macOS registers Audio Units installed in /Library/Audio/Plug-Ins/Components or ~/Library/Audio/Plug-Ins/Components, and Audio Unit extensions inside apps. To add a plugin, install it with its installer or copy its .component bundle into one of these folders, then click Scan Again. VoxFlowAir does not bypass licensing: a plugin that is not activated behaves as in any other host.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if filter.mode == .allowlist {
                Section("Allowed plugins") {
                    TextField("Filter", text: $search, prompt: Text("Search by name or manufacturer"))
                    AllowlistEditor(search: search)
                }
            }
            if !filter.hiddenPlugins.isEmpty {
                Section("Hidden plugins") {
                    ForEach(filter.hiddenPlugins, id: \.self) { id in
                        HStack {
                            let info = e.installedPlugins.first { $0.id == id }
                            Text(info.map { "\($0.name) — \($0.manufacturer)" } ?? id).lineLimit(1)
                            Spacer()
                            Button("Show") { e.settings.pluginFilter.setHidden(id, false) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openComponentsFolder() {
        let url = AudioUnitLocations.userComponents
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

/// Allowlist by manufacturer, or plugin by plugin.
private struct AllowlistEditor: View {
    @Environment(AppState.self) private var app
    let search: String
    @State private var expanded: Set<String> = []

    var body: some View {
        let e = app.engine
        let filter = e.settings.pluginFilter
        let list = e.installedPlugins.filter { p in
            (e.settings.showMultichannelPlugins || !p.isMultichannelVariant)
                && (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || p.manufacturer.localizedCaseInsensitiveContains(search))
        }
        let byMaker = Dictionary(grouping: list, by: \.manufacturer)
        ForEach(byMaker.keys.sorted(), id: \.self) { maker in
            let items = byMaker[maker] ?? []
            let wholeMaker = filter.allowedManufacturers.contains(maker)
            DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || expanded.contains(maker) },
                                                set: { if $0 { expanded.insert(maker) } else { expanded.remove(maker) } })) {
                ForEach(items) { p in
                    Toggle(p.name, isOn: Binding(get: { wholeMaker || filter.allowedPlugins.contains(p.id) },
                                                 set: { e.settings.pluginFilter.setAllowed(plugin: p.id, $0) }))
                        .disabled(wholeMaker)
                }
            } label: {
                Toggle(isOn: Binding(get: { wholeMaker }, set: { e.settings.pluginFilter.setAllowed(manufacturer: maker, $0) })) {
                    HStack {
                        Text(maker).fontWeight(.semibold)
                        Spacer()
                        let n = wholeMaker ? items.count : items.filter { filter.allowedPlugins.contains($0.id) }.count
                        Text("\(n)/\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @State private var loginStatus: SMAppService.Status = .notRegistered
    var body: some View {
        @Bindable var e = app.engine
        Form {
            Picker("Appearance", selection: Binding(get: { e.settings.appearance }, set: { e.settings.appearance = $0; app.applyAppearance() })) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Open VoxFlowAir at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                                                          set: { app.setLaunchAtLogin($0); loginStatus = app.launchAtLoginStatus }))
            if loginStatus == .requiresApproval {
                HStack {
                    Text("macOS asks for your approval in System Settings › Login Items.").font(.caption).foregroundStyle(VF.warn)
                    Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Toggle("Show the main window at launch", isOn: $e.settings.showWindowAtLaunch)
            Toggle("Lock graph editing", isOn: $e.settings.lockEditing)
            Text("Closing the main window does not stop processing: VoxFlowAir stays active in the menu bar. To stop it, use “Quit” in the menu bar panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = app.launchAtLoginStatus }
    }
}

struct DiagnosticsSettings: View {
    @Environment(AppState.self) private var app
    @State private var report = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Generate Report") { report = app.engine.diagnosticsReport() }
                Button("Export…") {
                    let text = app.engine.diagnosticsReport()
                    let p = NSSavePanel()
                    p.nameFieldStringValue = "VoxFlowAir-diagnostic-\(Int(Date().timeIntervalSince1970)).txt"
                    if p.runModal() == .OK, let url = p.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
                }
                Button("Show Logs") { NSWorkspace.shared.activateFileViewerSelecting([VFLog.shared.fileURL]) }
                Button("Presets Folder") { NSWorkspace.shared.open(AppPaths.presets) }
                Spacer()
                Button("Reset Counters") { app.engine.resetCounters(); app.meters.resetClips() }
            }
            ScrollView {
                Text(report.isEmpty ? String(localized: "Click “Generate Report”.") : report)
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(VF.panel2))
        }
    }
}

/// Version, credits and links. The repository and donation links come from Info.plist
/// (`VoxFlowAirRepositoryURL`, `VoxFlowAirDonationURL`); an empty value hides the button.
struct AboutSettings: View {
    private func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private func link(_ key: String) -> URL? { info(key).flatMap(URL.init(string:)) }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("VoxFlowAir").font(.title.bold())
            Text("Version \(info("CFBundleShortVersionString") ?? "?") (\(info("CFBundleVersion") ?? "?"))")
                .foregroundStyle(.secondary)
            Text("Real-time voice processing for macOS: your microphone, through a chain of Audio Units, to a virtual microphone and your headphones.")
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Text(info("NSHumanReadableCopyright") ?? "").font(.caption).foregroundStyle(.secondary)
            Text("Free and open-source software, released under the MIT License.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if let url = link("VoxFlowAirRepositoryURL") {
                    Button("Source Code") { NSWorkspace.shared.open(url) }
                }
                if let url = link("VoxFlowAirDonationURL") {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Support VoxFlowAir", systemImage: "heart") }
                        .help("Make a donation with PayPal to support development (opens your browser)")
                }
            }
            if link("VoxFlowAirDonationURL") != nil {
                Text("VoxFlowAir is free. If it is useful to you, a donation helps keep it going.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Displayed name of “VoxFlowAir Micro”, applied on submit (not on every keystroke).
struct VirtualNameField: View {
    @Environment(AppState.self) private var app
    @State private var text = ""
    var body: some View {
        HStack {
            TextField("Microphone name in apps", text: $text, prompt: Text(VoxFlowAirDriverSupport.micName))
                .onSubmit(apply)
            Button("Apply", action: apply)
                .disabled((VoxFlowAirDriverSupport.sanitizedName(text) ?? "") == (app.engine.settings.virtualDeviceName ?? ""))
        }
        .onAppear { text = app.engine.settings.virtualDeviceName ?? "" }
    }
    private func apply() { app.engine.setVirtualDeviceName(text) }
}
