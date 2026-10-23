import SwiftUI
import VoxFlowAirCore

struct PluginLibrary: View {
    @Environment(AppState.self) private var app
    @State private var search = ""
    @State private var tab: Tab = .plugins
    @State private var expanded: Set<String> = []

    enum Tab: String, CaseIterable {
        case effects, plugins, favorites
        var title: LocalizedStringKey {
            switch self {
            case .effects: "Effects"
            case .plugins: "Plugins"
            case .favorites: "Favorites"
            }
        }
    }

    var visible: [PluginInfo] {
        let e = app.engine
        var list = e.plugins
        if !e.settings.showMultichannelPlugins { list = list.filter { !$0.isMultichannelVariant } }
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.manufacturer.localizedCaseInsensitiveContains(search) }
        }
        return list
    }

    var body: some View {
        Group {
            switch tab {
            case .effects: effectsList
            case .plugins: pluginTree
            case .favorites: favoritesList
            }
        }
        // Native sidebar: the list scrolls under the glass, with system search.
        .searchable(text: $search, placement: .sidebar, prompt: "Search plugins")
        .safeAreaBar(edge: .top) {
            Picker("Library", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 6) {
                Text("\(app.engine.plugins.count) AU effects · double-click: end of chain · drag: onto the graph or a connection")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button { app.engine.rescanPlugins() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Scan again for installed plugins")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    var effectsList: some View {
        List {
            Section("VoxFlowAir native effects") {
                NativeRow(title: "Gain", detail: "Level ±60 dB, no latency", symbol: "dial.medium", kind: .gain)
                NativeRow(title: "Analyzer", detail: "Measurement point: spectrum, oscilloscope, LUFS", symbol: "waveform.badge.magnifyingglass", kind: .analyzer)
                NativeRow(title: "Headphone output", detail: "The headphones play this point of the chain", symbol: "headphones", kind: .monitorOutput)
            }
            Section("By category (AU plugins)") {
                ForEach(PluginCategory.allCases) { cat in
                    let inCat = visible.filter { $0.category == cat }
                    if !inCat.isEmpty {
                        DisclosureGroup(isExpanded: binding("cat/\(cat.rawValue)")) {
                            ForEach(inCat) { PluginRow(info: $0) }
                        } label: { categoryLabel(cat, count: inCat.count) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    var pluginTree: some View {
        let byMaker = Dictionary(grouping: visible, by: \.manufacturer)
        return List {
            ForEach(byMaker.keys.sorted(), id: \.self) { maker in
                let items = byMaker[maker] ?? []
                DisclosureGroup(isExpanded: binding(maker)) {
                    ForEach(PluginCategory.allCases) { cat in
                        let inCat = items.filter { $0.category == cat }
                        if !inCat.isEmpty {
                            DisclosureGroup(isExpanded: binding("\(maker)/\(cat.displayName)")) {
                                ForEach(inCat) { PluginRow(info: $0) }
                            } label: { categoryLabel(cat, count: inCat.count) }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: maker == "Apple" ? "apple.logo" : "building.2").foregroundStyle(VF.text2).frame(width: 16)
                        Text(maker).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(items.count)").font(VF.mono).foregroundStyle(VF.text3)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay { if visible.isEmpty { Text("No plugins found.").font(VF.small).foregroundStyle(VF.text3) } }
    }

    var favoritesList: some View {
        let e = app.engine
        let favs = visible.filter { e.settings.favoritePlugins.contains($0.id) }
        let recents = e.settings.recentPlugins.compactMap { id in visible.first { $0.id == id } }
        return List {
            Section("Favorites") {
                if favs.isEmpty { Text("Click a plugin’s star to add it.").font(VF.small).foregroundStyle(VF.text3) }
                ForEach(favs) { PluginRow(info: $0) }
            }
            Section("Recently used") {
                if recents.isEmpty { Text("No recently used plugins.").font(VF.small).foregroundStyle(VF.text3) }
                ForEach(recents) { PluginRow(info: $0) }
            }
        }
        .listStyle(.sidebar)
    }

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { !search.isEmpty || expanded.contains(key) }, set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    func categoryLabel(_ cat: PluginCategory, count: Int) -> some View {
        HStack {
            Image(systemName: cat.symbol).foregroundStyle(VF.color(for: cat)).frame(width: 16)
            Text(cat.displayName).font(VF.label)
            Spacer()
            Text("\(count)").font(VF.mono).foregroundStyle(VF.text3)
        }
    }
}

struct NativeRow: View {
    @Environment(AppState.self) private var app
    let title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String
    let kind: NodeKind
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(VF.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10)).foregroundStyle(VF.text3).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let id = app.engine.addNode(kind: kind, appendToChain: kind != .monitorOutput) { app.selectedNodes = [id] }
        }
        .draggable("native:\(kind.rawValue)")
        .help("Double-click to add, or drag onto the graph")
    }
}

struct NativeNodesStrip: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VoxFlowAir native nodes").font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.text3)
            HStack(spacing: 6) {
                chip("Gain", "dial.medium", .gain)
                chip("Analyzer", "waveform.badge.magnifyingglass", .analyzer)
                chip("Headphones", "headphones", .monitorOutput)
            }
        }
    }
    func chip(_ t: LocalizedStringKey, _ s: String, _ kind: NodeKind) -> some View {
        Button {
            let id = app.engine.addNode(kind: kind, appendToChain: kind != .monitorOutput)
            if let id { app.selectedNodes = [id] }
        } label: {
            Label(t, systemImage: s).font(.system(size: 11)).lineLimit(1).fixedSize().padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(VF.panel3))
        }
        .buttonStyle(.plain)
        .draggable("native:\(kind.rawValue)")
        .help(kind == .monitorOutput ? "Dedicated headphone output: the headphones play the point of the chain connected to this node." : "Add to the end of the chain (or drag)")
    }
}

struct PluginRow: View {
    @Environment(AppState.self) private var app
    let info: PluginInfo
    var body: some View {
        let fav = app.engine.settings.favoritePlugins.contains(info.id)
        HStack(spacing: 6) {
            Circle().fill(VF.color(for: info.category)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).font(.system(size: 12)).lineLimit(1)
                Text(info.manufacturer).font(.system(size: 10)).foregroundStyle(VF.text3)
            }
            Spacer(minLength: 2)
            if let ch = info.channelHint {
                Text(ch).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(VF.text3)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(VF.border))
            }
            Button { app.engine.toggleFavorite(info.reference) } label: {
                Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? VF.warn : VF.text3)
            }.buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { add() }
        .draggable("plugin:\(info.id)")
        .contextMenu {
            Button("Add to End of Chain") { add() }
            Button(fav ? "Remove from Favorites" : "Add to Favorites") { app.engine.toggleFavorite(info.reference) }
            Menu("Category") {
                let overridden = app.engine.settings.pluginFilter.categoryOverrides[info.id] != nil
                Toggle("Automatic", isOn: Binding(get: { !overridden },
                                                  set: { if $0 { app.engine.settings.pluginFilter.categoryOverrides[info.id] = nil } }))
                Divider()
                ForEach(PluginCategory.allCases) { cat in
                    Toggle(cat.displayName, isOn: Binding(get: { overridden && info.category == cat },
                                                          set: { if $0 { app.engine.settings.pluginFilter.categoryOverrides[info.id] = cat } }))
                }
            }
            Divider()
            Button("Hide from Library") { app.engine.settings.pluginFilter.setHidden(info.id, true) }
        }
        .help(Text(verbatim: "\(info.name) — \(info.manufacturer) \(info.versionString)\(info.isAUv3 ? " · AUv3" : " · AUv2")"))
    }
    func add() {
        if app.engine.settings.lockEditing { app.engine.post(.warning, String(localized: "Editing is locked.")); return }
        if let id = app.engine.addNode(kind: .audioUnit, plugin: info.reference, appendToChain: true) { app.selectedNodes = [id] }
    }
}
