import SwiftUI
import AVFoundation
import VoxFlowAirCore

struct Inspector: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let id = app.primarySelection, let node = app.engine.graph.node(id) {
                        NodeInspector(node: node)
                    } else if app.selectedNodes.count > 1 {
                        MultiSelectionInspector()
                    } else {
                        ChainOverview()
                    }
                }
                .padding(12)
            }
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).textCase(.uppercase).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(VF.text3)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(VF.panel2))
    }
}

struct KV: View {
    let k: LocalizedStringKey, v: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(VF.small).foregroundStyle(VF.text2)
            Spacer()
            Text(v).font(mono ? VF.mono : VF.small).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

struct NodeInspector: View {
    @Environment(AppState.self) private var app
    let node: GraphNode
    @State private var title = ""
    @State private var details: (hasCustomView: Bool, passesValidation: Bool)?

    var body: some View {
        let e = app.engine
        let cat = app.category(for: node)
        let status = e.nodeStatus[node.id] ?? .ok
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: VF.symbol(for: node, category: cat)).font(.system(size: 18))
                    .foregroundStyle(VF.color(for: node, category: cat))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(VF.color(for: node, category: cat).opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $title).textFieldStyle(.plain).font(VF.title)
                        .onSubmit { e.renameNode(node.id, title) }
                    Text(node.kind == .audioUnit ? "External plugin · \(cat?.displayName ?? "")" : "VoxFlowAir native node · \(node.kind.displayName)")
                        .font(.system(size: 10)).foregroundStyle(VF.text3)
                }
            }
            .onAppear { title = node.title }
            .onChange(of: node.id) { title = node.title; details = nil }

            InspectorSection(title: "Status") {
                HStack {
                    StatusDot(color: status.isHealthy ? (e.graph.isEffectivelyBypassed(node) ? VF.warn : VF.ok) : VF.danger)
                    Text(e.graph.isEffectivelyBypassed(node) && status.isHealthy ? String(localized: "Bypassed") : status.label).font(VF.small)
                    Spacer()
                    if !e.graph.activeNodeIDs().contains(node.id) && node.kind != .input {
                        Text("not on the active path").font(.system(size: 10)).foregroundStyle(VF.warn)
                    }
                }
                if node.kind != .input && node.kind != .output && node.kind != .monitorOutput && node.kind != .analyzer {
                    Toggle("Bypass this node", isOn: Binding(get: { node.bypassed }, set: { e.setNodeBypass(node.id, $0) }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                if let lvl = app.meters.nodes[node.id] {
                    HStack {
                        Text("Level").font(VF.small).foregroundStyle(VF.text2)
                        HorizontalMeter(level: lvl).frame(height: 10)
                        Text(formatLevel(lvl.maxPeak)).font(VF.mono).frame(width: 40, alignment: .trailing)
                    }
                }
            }

            switch node.kind {
            case .gain:
                InspectorSection(title: "Gain") {
                    let g = node.parameters["gain"] ?? 0
                    HStack {
                        Slider(value: Binding(get: { g }, set: { e.setGain(node.id, db: ($0 * 2).rounded() / 2, registerUndo: false) }), in: -60...24) { editing in
                            if editing { e.setGain(node.id, db: g, registerUndo: true) }
                        }
                        Text(formatDB(g)).font(VF.mono).frame(width: 68, alignment: .trailing)
                    }
                    HStack {
                        ForEach([-12.0, -6, 0, 6, 12], id: \.self) { v in
                            Button(v == 0 ? "0" : String(format: "%+.0f", v)) { e.setGain(node.id, db: v, registerUndo: true) }.controlSize(.small)
                        }
                    }
                }
            case .input:
                InspectorSection(title: "Input") {
                    KV(k: "Device", v: e.activeInput?.name ?? "—")
                    InputChannelPicker()
                    HStack {
                        Text("Input gain").font(VF.small).foregroundStyle(VF.text2)
                        Slider(value: Binding(get: { e.settings.inputGainDB }, set: { e.settings.inputGainDB = ($0 * 2).rounded() / 2 }), in: -24...24)
                        Text(formatDB(e.settings.inputGainDB)).font(VF.mono).frame(width: 64, alignment: .trailing)
                    }
                }
            case .output:
                InspectorSection(title: "Virtual output") {
                    KV(k: "Device", v: e.activeVirtual?.name ?? String(localized: "none"))
                    HStack {
                        Text("Level").font(VF.small).foregroundStyle(VF.text2)
                        Slider(value: Binding(get: { e.settings.virtualGainDB }, set: { e.settings.virtualGainDB = ($0 * 2).rounded() / 2 }), in: -40...12)
                        Text(formatDB(e.settings.virtualGainDB)).font(VF.mono).frame(width: 64, alignment: .trailing)
                    }
                    Text("In OBS, FaceTime, etc., choose “\(e.activeVirtual?.name ?? "BlackHole 2ch")” as the microphone.")
                        .font(.system(size: 10)).foregroundStyle(VF.text3)
                }
            case .monitorOutput:
                InspectorSection(title: "Monitoring output") {
                    Text("The headphones play the signal arriving at this node instead of the virtual output. This node is not sent to apps.")
                        .font(.system(size: 11)).foregroundStyle(VF.text2)
                    KV(k: "Device", v: e.activeMonitor?.name ?? "—")
                }
            case .analyzer:
                InspectorSection(title: "Analyzer") {
                    Text("Measurement point: choose it as the source in the analysis panel (Spectrum, Oscilloscope, Loudness).")
                        .font(.system(size: 11)).foregroundStyle(VF.text2)
                    Button("Analyze This Point") { app.analysisSource = .node(node.id); if app.bottomTab == .levels { app.bottomTab = .spectrum } }
                }
            case .audioUnit:
                pluginSection(node, status: status)
            }

            if let gid = node.groupID, let group = e.graph.groups.first(where: { $0.id == gid }) {
                InspectorSection(title: "Section") {
                    KV(k: "Group", v: group.name)
                    Toggle("Bypass section", isOn: Binding(get: { group.bypassed }, set: { e.setGroupBypass(gid, $0) }))
                        .toggleStyle(.switch).controlSize(.small)
                }
            }

            if !node.kind.isUnique {
                HStack {
                    Button { e.duplicateNode(node.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Spacer()
                    Button(role: .destructive) { app.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                }.controlSize(.small)
            }

            let nodeIssues = e.issues.filter { $0.nodeID == node.id }
            if !nodeIssues.isEmpty {
                InspectorSection(title: "Warnings") {
                    ForEach(nodeIssues) { i in Text(i.message).font(.system(size: 11)).foregroundStyle(i.severity == .error ? VF.danger : VF.warn) }
                }
            }
        }
    }

    @ViewBuilder
    func pluginSection(_ node: GraphNode, status: NodeRuntimeStatus) -> some View {
        let e = app.engine
        let unit = e.pluginUnit(for: node.id)
        if let unit { PluginControls(node: node, unit: unit) }
        InspectorSection(title: "Plugin") {
            if let ref = node.plugin {
                KV(k: "Manufacturer", v: ref.manufacturerName)
                KV(k: "AU identifier", v: ref.identifier, mono: true)
                if let info = e.catalog.info(for: ref) {
                    KV(k: "Version", v: info.versionString)
                    KV(k: "Format", v: info.isAUv3 ? "AUv3" : "AUv2")
                }
            }
            if let unit {
                let caps = unit.auAudioUnit.channelCapabilities?.map(\.intValue) ?? []
                KV(k: "Channels", v: caps.isEmpty ? String(localized: "not declared") : stride(from: 0, to: caps.count - 1, by: 2).map { "\(caps[$0])→\(caps[$0 + 1])" }.joined(separator: ", "), mono: true)
                KV(k: "Reported latency", v: String(format: "%.2f ms", unit.auAudioUnit.latency * 1000), mono: true)
                KV(k: "Process", v: unit.auAudioUnit.isLoadedInProcess ? String(localized: "inside VoxFlowAir") : String(localized: "isolated (AUHostingService)"))
            }
            if let d = details {
                KV(k: "Native interface", v: d.hasCustomView ? String(localized: "yes") : String(localized: "no"))
                KV(k: "auval validation", v: d.passesValidation ? String(localized: "passed") : String(localized: "not validated"))
            } else if let ref = node.plugin {
                Button("Check Interface and Validation") { details = e.catalog.details(for: ref) }.controlSize(.small)
            }
            Picker("Loading", selection: Binding(get: { node.loadMode ?? e.settings.pluginLoadMode }, set: { e.setNodeLoadMode(node.id, $0) })) {
                ForEach(PluginLoadMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .controlSize(.small)
            .help("“Isolated Process”: a plugin crash does not stop VoxFlowAir (the node is bypassed). “Inside VoxFlowAir”: best compatibility.")
            HStack {
                Button { app.openPluginUI(node.id) } label: { Label("Open Interface", systemImage: "macwindow") }
                    .disabled(unit == nil)
                if !status.isHealthy {
                    Button { e.reloadPlugin(node.id) } label: { Label("Reload", systemImage: "arrow.clockwise") }
                }
            }.controlSize(.small)
            if status == .missing {
                Text("This plugin is not installed on this Mac. The node passes the signal through; its settings are kept in the preset and will be restored when the plugin is available again.")
                    .font(.system(size: 10)).foregroundStyle(VF.warn)
            }
        }
    }
}

struct InputChannelPicker: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let e = app.engine
        let n = e.activeInput?.inputChannels ?? 2
        let options: [(String, [Int])] = {
            var o: [(String, [Int])] = []
            if n >= 2 { o.append((String(localized: "Stereo 1-2"), [0, 1])) }
            for c in 0..<min(n, 16) { o.append((String(localized: "Mono \(c + 1) (dual mono)"), [c])) }
            if n >= 4 { for c in stride(from: 2, to: min(n, 16) - 1, by: 2) { o.append((String(localized: "Stereo \(c + 1)-\(c + 2)"), [c, c + 1])) } }
            return o
        }()
        Picker("Channels", selection: Binding(get: { e.settings.inputChannels.map(String.init).joined(separator: ",") },
                                            set: { v in e.setInputChannels(v.split(separator: ",").compactMap { Int($0) }) })) {
            ForEach(options, id: \.0) { o in Text(o.0).tag(o.1.map(String.init).joined(separator: ",")) }
        }.controlSize(.small)
    }
}

struct MultiSelectionInspector: View {
    @Environment(AppState.self) private var app
    @State private var groupName = String(localized: "Section")
    var body: some View {
        InspectorSection(title: "\(app.selectedNodes.count) nodes selected") {
            TextField("Section name", text: $groupName).textFieldStyle(.roundedBorder)
            Button { app.engine.createGroup(name: groupName, nodes: app.selectedNodes) } label: { Label("Group into Section", systemImage: "rectangle.3.group") }
            Button { for id in app.selectedNodes { app.engine.setNodeBypass(id, true) } } label: { Label("Bypass Selection", systemImage: "arrow.triangle.turn.up.right.diamond") }
            Button { for id in app.selectedNodes { app.engine.setNodeBypass(id, false) } } label: { Label("Re-enable Selection", systemImage: "checkmark.circle") }
            Button(role: .destructive) { app.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct ChainOverview: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let e = app.engine
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection(title: "Processing order") {
                ProcessingOrderList()
            }
            InspectorSection(title: "Active chain") {
                KV(k: "Preset", v: e.activePreset?.name ?? "—")
                KV(k: "Nodes", v: String(localized: "\(e.graph.nodes.count) (\(e.graph.nodes.filter { $0.kind == .audioUnit }.count) plugins)"))
                KV(k: "Connections", v: "\(e.graph.connections.count)")
                if !e.graph.groups.isEmpty {
                    ForEach(e.graph.groups) { g in
                        HStack {
                            Circle().fill(VF.groupColors[g.colorIndex % VF.groupColors.count]).frame(width: 7, height: 7)
                            Text(g.name).font(VF.small)
                            Spacer()
                            Toggle("", isOn: Binding(get: { !g.bypassed }, set: { e.setGroupBypass(g.id, !$0) })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .help("Section active / bypassed")
                            Button { e.removeGroup(g.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Ungroup section")
                        }
                    }
                }
            }
            InspectorSection(title: "Latency (estimate)") {
                let l = e.latency
                KV(k: "Sample rate", v: l.sampleRate > 0 ? "\(Int(l.sampleRate)) Hz" : "—", mono: true)
                KV(k: "Buffer", v: String(localized: "\(l.bufferFrames) samples · \(String(format: "%.2f ms", l.bufferMs))"), mono: true)
                KV(k: "Hardware input / output", v: String(localized: "\(l.inputDeviceFrames) / \(l.outputDeviceFrames) samples"), mono: true)
                KV(k: "Plugins", v: String(format: "%.2f ms", l.pluginSeconds * 1000), mono: true)
                KV(k: "Estimated total", v: String(format: "%.1f ms", l.estimatedTotalMs), mono: true)
                Text("Calculated from the values reported by Core Audio and the plugins; not measured.")
                    .font(.system(size: 10)).foregroundStyle(VF.text3)
            }
            if !e.issues.isEmpty {
                InspectorSection(title: "Graph check") {
                    ForEach(e.issues) { i in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: i.severity == .error ? "xmark.octagon.fill" : (i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                                .foregroundStyle(i.severity == .error ? VF.danger : (i.severity == .warning ? VF.warn : VF.text3))
                            Text(i.message).font(.system(size: 11))
                        }
                        .onTapGesture { if let n = i.nodeID { app.selectedNodes = [n] } }
                    }
                }
            }
            InspectorSection(title: "Quick help") {
                Text("• Dragging a node moves it on the canvas without changing the sound.\n• ⌥ + drag a node, or its ≡ handle, to move it within the chain: a marker shows where it will be inserted. ⌘Z undoes.\n• Drag a plugin from the library onto a connection to insert it there; double-click: end of chain.\n• Drag from the output port (right) to another node’s input (left) to create a branch.\n• Double-click a plugin: native interface.\n• ⌫: delete · ⌘D: duplicate · ⌘G: group · B: bypass · ⌥⌘↑ / ⌥⌘↓: move up / down.\n• Drag on the background: select · space + drag or scroll wheel: pan · ⌘ + scroll wheel or pinch: zoom.")
                    .font(.system(size: 11)).foregroundStyle(VF.text2)
            }
        }
    }
}


/// Processing order of the main chain (Input → Virtual output), derived from the connections.
/// Rows can be reordered by drag and drop (macOS 27) or with the arrows; every
/// change goes through the same transactional operation as the canvas.
struct ProcessingOrderList: View {
    @Environment(AppState.self) private var app

    struct Item: Identifiable, Hashable { let id: UUID }

    var body: some View {
        let g = app.engine.graph
        let chain = g.reorderableMainChain()
        let items = chain.map(Item.init)
        let locked = app.engine.settings.lockEditing
        VStack(alignment: .leading, spacing: 2) {
            fixedRow("Input", "mic.fill")
            if chain.isEmpty {
                Text(g.mainChain().isEmpty ? "The virtual output is not fed by the input." : "No effects on the main chain.")
                    .font(.system(size: 11)).foregroundStyle(VF.text3).padding(.vertical, 4)
            } else {
                chainRows(items, chain: chain, locked: locked)
            }
            fixedRow("Virtual output", "dot.radiowaves.left.and.right")
            let off = g.nodes.filter { !$0.kind.isUnique && !chain.contains($0.id) }.count
            if off > 0 {
                Text("\(off) node(s) outside the main chain (branches or free nodes): arrange them on the canvas.")
                    .font(.system(size: 10)).foregroundStyle(VF.text3).padding(.top, 4)
            }
        }
    }

    /// Rows of the main chain, reorderable by drag on macOS 27 (built with the macOS 27 SDK).
    @ViewBuilder
    func chainRows(_ items: [Item], chain: [UUID], locked: Bool) -> some View {
        #if compiler(>=6.4)
        if #available(macOS 27, *), !locked {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in row(item.id, index: chain.firstIndex(of: item.id) ?? 0, count: chain.count, locked: locked) }
                    .reorderable()
            }
            .reorderContainer(for: Item.self) { diff in
                guard let src = diff.sources.first else { return }
                switch diff.destination.position {
                case .before(let before): if before != src { app.engine.moveInMainChain(src, before: before) }
                case .end: app.engine.moveInMainChain(src, before: nil)
                }
            }
        } else {
            ForEach(items) { item in row(item.id, index: chain.firstIndex(of: item.id) ?? 0, count: chain.count, locked: locked) }
        }
        #else
        ForEach(items) { item in row(item.id, index: chain.firstIndex(of: item.id) ?? 0, count: chain.count, locked: locked) }
        #endif
    }

    func fixedRow(_ title: LocalizedStringKey, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(VF.text3).padding(.vertical, 3)
    }

    func row(_ id: UUID, index: Int, count: Int, locked: Bool) -> some View {
        let e = app.engine
        let node = e.graph.node(id)
        let cat = node.flatMap { app.category(for: $0) }
        return HStack(spacing: 6) {
            Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(VF.text2).frame(width: 18, alignment: .trailing)
            if let node {
                Image(systemName: VF.symbol(for: node, category: cat)).foregroundStyle(VF.color(for: node, category: cat)).frame(width: 14)
                Text(node.title).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(e.graph.isEffectivelyBypassed(node) ? VF.text3 : VF.text)
            }
            Spacer(minLength: 2)
            Button { app.selectedNodes = [id]; app.moveSelection(by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(locked || index == 0).help("Move up (⌥⌘↑)")
                .accessibilityLabel("Move \(node?.title ?? "") up")
            Button { app.selectedNodes = [id]; app.moveSelection(by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(locked || index == count - 1).help("Move down (⌥⌘↓)")
                .accessibilityLabel("Move \(node?.title ?? "") down")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(app.selectedNodes.contains(id) ? VF.accent.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { app.selectedNodes = [id] }
    }
}

/// Quick controls for a plugin: presets, A/B comparison, copy/paste, main parameters.
struct PluginControls: View {
    @Environment(AppState.self) private var app
    let node: GraphNode
    let unit: AVAudioUnit

    var body: some View {
        let e = app.engine
        let au = unit.auAudioUnit
        let presets = (au.factoryPresets ?? []) + (au.supportsUserPresets ? au.userPresets : [])
        let compare = app.compareStates[node.id]
        InspectorSection(title: "Controls") {
            HStack {
                Text("Plugin preset").font(VF.small).foregroundStyle(VF.text2)
                Spacer()
            }
            Picker("", selection: Binding(get: { au.currentPreset?.number ?? Int.min },
                                          set: { n in
                                              if let p = presets.first(where: { $0.number == n }) { au.currentPreset = p; e.markDirty() }
                                          })) {
                Text(presets.isEmpty ? "No presets exposed" : "Choose…").tag(Int.min)
                ForEach(presets, id: \.number) { p in Text(p.name).tag(p.number) }
            }
            .labelsHidden().disabled(presets.isEmpty)
            HStack(spacing: 6) {
                Button(compare == nil ? "Compare" : (compare!.showingB ? "B ⇄ A" : "A ⇄ B")) { toggleCompare() }
                    .help(compare == nil ? "Stores the current state (A). Change the plugin, then click again to switch between A and B." : "Switch between the two states")
                Button("Copy") {
                    if let d = PluginHost.captureState(unit), let ref = node.plugin { app.pluginClipboard = (ref.identifier, node.title, d) }
                }
                Button("Paste") {
                    if let c = app.pluginClipboard { PluginHost.restoreState(unit, data: c.state); e.markDirty() }
                }
                .disabled(app.pluginClipboard?.identifier != node.plugin?.identifier)
                .help(app.pluginClipboard.map { String(localized: "Paste the settings of “\($0.name)”") } ?? String(localized: "Nothing to paste"))
            }
            .controlSize(.small)
            if compare != nil {
                Button("End Comparison (Keep Current State)") { app.compareStates[node.id] = nil }
                    .controlSize(.small).buttonStyle(.link)
            }
            ParameterList(unit: au).frame(maxHeight: 220)
            HStack {
                Button { app.openPluginUI(node.id) } label: { Label("Show Full Interface", systemImage: "macwindow") }
                Spacer()
            }.controlSize(.small)
        }
    }

    func toggleCompare() {
        guard let current = PluginHost.captureState(unit) else { return }
        if let c = app.compareStates[node.id] {
            PluginHost.restoreState(unit, data: c.stored)
            app.compareStates[node.id] = (current, !c.showingB)
            app.engine.markDirty()
        } else {
            app.compareStates[node.id] = (current, false)
            app.engine.post(.info, String(localized: "State A of “\(node.title)” stored: change the plugin, then click “A ⇄ B” to compare."))
        }
    }
}

/// First writable parameters exposed by the plugin.
struct ParameterList: View {
    let unit: AUAudioUnit
    @State private var tick = 0
    var body: some View {
        let params = (unit.parameterTree?.allParameters ?? []).filter { $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue }
        if params.isEmpty {
            Text("This plugin exposes no automatable parameters: use its interface.")
                .font(.system(size: 10)).foregroundStyle(VF.text3)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(params.prefix(12), id: \.address) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(p.displayName).font(.system(size: 10)).lineLimit(1)
                                Spacer()
                                Text(p.currentValueString).font(.system(size: 10, design: .monospaced)).foregroundStyle(VF.text2).lineLimit(1)
                            }
                            Slider(value: Binding(get: { _ = tick; return Double(p.value) },
                                                  set: { p.setValue(AUValue($0), originator: nil); tick += 1 }),
                                   in: Double(p.minValue)...Double(p.maxValue))
                                .controlSize(.mini)
                        }
                    }
                    if params.count > 12 {
                        Text("+ \(params.count - 12) more parameters in the full interface").font(.system(size: 9)).foregroundStyle(VF.text3)
                    }
                }
            }
        }
    }
}
