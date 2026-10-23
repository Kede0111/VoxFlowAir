import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoxFlowAirCore

/// Node dimensions (graph coordinates, before zoom).
enum NodeMetrics {
    static let width: CGFloat = 184
    static let height: CGFloat = 150
    static let portRadius: CGFloat = 7
}

/// Graph ↔ screen conversion and connection geometry, shared by the editor's layers.
struct EditorGeometry {
    var offset: CGSize
    var zoom: CGFloat
    /// Positions shown instead of the saved position (move in progress).
    var overrides: [UUID: GraphPoint] = [:]

    func position(_ n: GraphNode) -> GraphPoint { overrides[n.id] ?? n.position }
    func screen(_ p: GraphPoint) -> CGPoint { CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height) }
    func world(_ p: CGPoint) -> GraphPoint { GraphPoint(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom) }
    func origin(_ n: GraphNode) -> CGPoint { screen(position(n)) }
    func inputPort(_ n: GraphNode) -> CGPoint { let s = origin(n); return CGPoint(x: s.x, y: s.y + NodeMetrics.height / 2 * zoom) }
    func outputPort(_ n: GraphNode) -> CGPoint { let s = origin(n); return CGPoint(x: s.x + NodeMetrics.width * zoom, y: s.y + NodeMetrics.height / 2 * zoom) }
    func rect(_ n: GraphNode) -> CGRect {
        let s = origin(n)
        return CGRect(x: s.x, y: s.y, width: NodeMetrics.width * zoom, height: NodeMetrics.height * zoom)
    }

    /// Control points of the a → b curve.
    func controls(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(abs(b.x - a.x) * 0.5, 50 * zoom)
        return (CGPoint(x: a.x + dx, y: a.y), CGPoint(x: b.x - dx, y: b.y))
    }

    func bezier(_ a: CGPoint, _ b: CGPoint) -> Path {
        let (c1, c2) = controls(a, b)
        return Path { p in p.move(to: a); p.addCurve(to: b, control1: c1, control2: c2) }
    }

    func ends(_ c: GraphConnection, in graph: ProcessingGraph) -> (CGPoint, CGPoint)? {
        guard let a = graph.node(c.from), let b = graph.node(c.to) else { return nil }
        return (outputPort(a), inputPort(b))
    }

    func point(_ a: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        let (c1, c2) = controls(a, b)
        let u = 1 - t
        let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
        return CGPoint(x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x, y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y)
    }

    func midpoint(_ c: GraphConnection, in graph: ProcessingGraph) -> CGPoint? {
        guard let (a, b) = ends(c, in: graph) else { return nil }
        return point(a, b, t: 0.5)
    }

    /// Connection closest to `p` (sampled distance to the curve), below `maxDistance`.
    func nearestConnection(to p: CGPoint, in graph: ProcessingGraph, maxDistance: CGFloat,
                           where include: (GraphConnection) -> Bool = { _ in true }) -> (connection: GraphConnection, point: CGPoint)? {
        var best: (GraphConnection, CGPoint, CGFloat)?
        for c in graph.connections where include(c) {
            guard let (a, b) = ends(c, in: graph) else { continue }
            for i in 1..<32 {
                let q = point(a, b, t: CGFloat(i) / 32)
                let d = hypot(q.x - p.x, q.y - p.y)
                if d < maxDistance && d < (best?.2 ?? .infinity) { best = (c, q, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }
}

/// Modular editor: what is drawn matches exactly the graph the engine runs.
///
/// When dragging a node, the drop location decides:
/// - on an empty area: visual move only (no effect on the sound);
/// - on a connection (⊕ marker shown on every target during the drag): the node is moved
///   *within the chain*. Before release, the targeted connection thickens, the node snaps to
///   it, the planned new connections and order numbers are shown, along with a
///   “Release to reorder the audio chain” preview. Applied on release, ⌘Z undoes.
/// The grip ≡ (or ⌥ + drag) is the explicit variant: released away from a connection,
/// nothing changes, and a refusal (branch, input / output) shows in red without changing anything.
struct NodeEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var offset: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var panStart: CGSize?
    @State private var magnifyStart: CGFloat?
    @State private var dragDelta: CGSize = .zero
    @State private var draggingNodes: Set<UUID> = []
    @State private var press: Press?
    @State private var reorder: ReorderDrag?
    @State private var wire: WireDrag?
    @State private var lasso: Lasso?
    @State private var libraryDrop: InsertionTarget?
    @State private var refusal: Refusal?
    @State private var spaceDown = false
    @State private var hoverLocation: CGPoint?
    @State private var scrollMonitor: Any?
    @State private var size: CGSize = .zero
    /// Drop targets of the dragged node, computed once at the start of the gesture (`chainDropTargets`).
    @State private var dropTargets: [UUID: Result<ProcessingGraph, ChainEditError>] = [:]
    @State private var dropTargetsNode: UUID?
    @AppStorage("editorReorderTipSeen") private var reorderTipSeen = false
    @FocusState private var focused: Bool

    /// Snapping to a connection (pointer distance to the curve, in screen points):
    /// engages below `snapIn`, the target stays acquired up to `snapOut` (no flicker).
    static let snapIn: CGFloat = 40
    static let snapOut: CGFloat = 60

    /// Drag in progress on a node; `reorder`: ⌥ was held at the start of the gesture;
    /// `ignored`: the gesture started on a node control (⏻ button), so it is not a move.
    struct Press { let node: UUID; let reorder: Bool; var ignored = false }
    struct WireDrag { let from: UUID; var to: CGPoint; var target: UUID?; var error: ProcessingGraph.EditError? }
    struct Lasso { let start: CGPoint; var current: CGPoint; let base: Set<UUID>
        var rect: CGRect { CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)) }
    }
    /// Targeted insertion spot (connection, point on the curve, validity, order preview).
    struct InsertionTarget: Equatable {
        let connection: UUID
        let point: CGPoint
        let error: ChainEditError?
        let preview: [String]
    }
    /// Move within the chain in progress. `strict`: grip ≡ or ⌥ (released off target = canceled);
    /// otherwise a plain drag, which only exists while a valid target is aimed at. `result`: planned
    /// graph (preview of connections and order numbers), the one applying it will produce.
    struct ReorderDrag { let node: UUID; var ghost: GraphPoint; var target: InsertionTarget?; var strict: Bool; var result: ProcessingGraph? }
    struct Refusal: Equatable { let point: CGPoint; let message: String; let id = UUID() }

    var locked: Bool { app.engine.settings.lockEditing }

    /// Connection geometry: includes a free move in progress, the “reordered” node at its place.
    var wireGeometry: EditorGeometry {
        var g = EditorGeometry(offset: offset, zoom: zoom)
        if !draggingNodes.isEmpty {
            for n in app.engine.graph.nodes where draggingNodes.contains(n.id) {
                g.overrides[n.id] = GraphPoint(x: n.position.x + dragDelta.width, y: n.position.y + dragDelta.height)
            }
        }
        return g
    }

    /// Node geometry: the reordered node follows the pointer (ghost).
    var nodeGeometry: EditorGeometry {
        var g = wireGeometry
        if let r = reorder { g.overrides[r.node] = r.ghost }
        return g
    }

    var body: some View {
        let e = app.engine
        let graph = e.graph
        let active = graph.activeNodeIDs()
        let chain = graph.reorderableMainChain()
        // Valid target aimed at: planned order numbers (the chain's numbers after the drop).
        let planned = reorder?.result?.reorderableMainChain() ?? chain
        let candidates = candidateTargets
        let geo = wireGeometry
        let ngeo = nodeGeometry
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(backgroundDrag)
                    .onTapGesture { app.selectedNodes = []; app.selectedConnection = nil; focused = true }

                groupsLayer(graph, geo: ngeo)

                // Level glow: separate layer, the only one redrawn at 30 Hz.
                ConnectionGlowLayer(graph: graph, active: active, geo: geo, hidden: reorder?.node)
                Canvas { ctx, _ in drawConnections(ctx, graph: graph, active: active, geo: geo, candidates: candidates) }
                    .allowsHitTesting(false)

                ForEach(graph.connections) { c in connectionHandle(c, graph: graph, geo: geo) }

                if let r = reorder, let n = graph.node(r.node) {
                    // Original spot during the move within the chain.
                    let o = geo.screen(n.position)
                    RoundedRectangle(cornerRadius: 10 * zoom)
                        .strokeBorder(VF.text3, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: NodeMetrics.width * zoom, height: NodeMetrics.height * zoom)
                        .offset(x: o.x, y: o.y)
                        .allowsHitTesting(false)
                }

                ForEach(graph.nodes) { node in
                    let o = ngeo.origin(node)
                    NodeView(node: node,
                             selected: app.selectedNodes.contains(node.id),
                             active: active.contains(node.id) || node.kind == .input,
                             orderIndex: planned.firstIndex(of: node.id).map { $0 + 1 },
                             orderChanged: planned.firstIndex(of: node.id) != chain.firstIndex(of: node.id),
                             wireTarget: wire?.target == node.id ? (wire?.error == nil ? .valid : .invalid) : .none,
                             lifted: reorder?.node == node.id,
                             canReorder: !locked && !node.kind.isUnique,
                             onWireChanged: { loc in wireChanged(from: node.id, to: loc) },
                             onWireEnded: { wireEnded() },
                             onGripChanged: { v in gripChanged(node, translation: v.translation, location: v.location) },
                             onGripEnded: { gripEnded() })
                        .frame(width: NodeMetrics.width, height: NodeMetrics.height)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .offset(x: o.x, y: o.y)
                        .zIndex(reorder?.node == node.id ? 10 : 0)
                        .gesture(nodeDrag(node))
                        .onTapGesture { nodeClicked(node) }
                }

                if let wire, let src = graph.node(wire.from) {
                    geo.bezier(geo.outputPort(src), wire.to)
                        .stroke(wire.error == nil ? VF.accent : VF.danger, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .allowsHitTesting(false)
                    if let err = wire.error, wire.target != nil {
                        RefusalBadge(message: err.description).offset(x: wire.to.x + 12, y: wire.to.y + 10).allowsHitTesting(false)
                    }
                }

                candidatesLayer(graph, geo: geo, candidates: candidates)
                insertionLayer(graph, geo: geo, ngeo: ngeo)

                if let lasso {
                    Rectangle().fill(VF.accent.opacity(0.10))
                        .overlay(Rectangle().strokeBorder(VF.accent.opacity(0.8), lineWidth: 1))
                        .frame(width: lasso.rect.width, height: lasso.rect.height)
                        .offset(x: lasso.rect.minX, y: lasso.rect.minY)
                        .allowsHitTesting(false)
                }

                if let refusal {
                    RefusalBadge(message: refusal.message)
                        .offset(x: refusal.point.x + 10, y: refusal.point.y + 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                overlayControls
            }
            .coordinateSpace(name: "editor")
            .clipped()
            .background {
                GridBackground(offset: offset, zoom: zoom).background(VF.canvas)
            }
            .onAppear { size = proxy.size; loadViewport(); installScrollMonitor() }
            .onChange(of: proxy.size) { _, s in size = s }
            .onDisappear { removeScrollMonitor() }
            .onChange(of: e.activePresetID) { _, _ in loadViewport() }
            .onChange(of: app.debugReorder?.node) { _, _ in
                // Control snapshots: puts the ghost on the requested connection.
                // Simulates a plain drag (no ⌥, no grip) of the node to the middle of the connection.
                guard let d = app.debugReorder, let n = e.graph.node(d.node), let c = e.graph.connections.first(where: { $0.id == d.connection }),
                      let m = wireGeometry.midpoint(c, in: e.graph) else { return }
                let o = wireGeometry.screen(n.position)
                let t = CGSize(width: m.x - o.x - 40 * zoom, height: m.y - o.y - 20 * zoom)
                app.selectedNodes = [n.id]
                draggingNodes = [n.id]
                ensureTargets(for: n)
                dragDelta = CGSize(width: t.width / zoom, height: t.height / zoom)
                updateReorder(n, translation: t, pointer: m, strict: false)
            }
            .onChange(of: app.debugDrag?.id) { _, _ in
                guard let d = app.debugDrag else { return }
                app.debugDrag = nil // handled only once
                Task { @MainActor in await playDebugDrag(d) }
            }
            .onChange(of: app.editorCommand) { _, cmd in
                guard let cmd else { return }
                switch cmd {
                case .zoomIn: setZoom(zoom * 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2))
                case .zoomOut: setZoom(zoom / 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2))
                case .fit: fitAll()
                case .resetZoom: setZoom(1, around: CGPoint(x: size.width / 2, y: size.height / 2))
                }
                app.editorCommand = nil
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { hoverLocation = p } else { hoverLocation = nil }
            }
            .gesture(MagnifyGesture()
                .onChanged { v in
                    if magnifyStart == nil { magnifyStart = zoom }
                    setZoom((magnifyStart ?? 1) * v.magnification, around: v.startLocation, persist: false)
                }
                .onEnded { _ in magnifyStart = nil; persistViewport() })
            .onDrop(of: LibraryDropDelegate.types, delegate: LibraryDropDelegate(
                onHover: { loc in libraryHover(at: loc) },
                onDrop: { item, loc in handleDrop(item, at: loc) }))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onDeleteCommand { if !locked { app.deleteSelection() } }
            .onKeyPress(.delete) { if !locked { app.deleteSelection() }; return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in
                for id in app.selectedNodes { if let n = e.graph.node(id) { e.setNodeBypass(id, !n.bypassed) } }
                return .handled
            }
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { k in
                let down = k.phase != .up
                if down != spaceDown {
                    spaceDown = down
                    if down { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                return .handled
            }
            .onKeyPress(.escape) {
                guard reorder != nil || wire != nil || lasso != nil || !draggingNodes.isEmpty else { return .ignored }
                cancelGestures()
                return .handled
            }
        }
    }

    // MARK: Drawing

    func drawConnections(_ context: GraphicsContext, graph: ProcessingGraph, active: Set<UUID>, geo: EditorGeometry, candidates: Set<UUID>) {
        var ctx = context
        let boost: CGFloat = contrast == .increased ? 1.5 : 0
        let reordering = reorder?.node
        let target = reorder?.target?.connection ?? libraryDrop?.connection
        for c in graph.connections {
            guard let (p0, p3) = geo.ends(c, in: graph), let a = graph.node(c.from), let b = graph.node(c.to) else { continue }
            let path = geo.bezier(p0, p3)
            let isActive = active.contains(c.from) && active.contains(c.to)
            let selected = app.selectedConnection == c.id
            let touchesMoving = reordering.map { c.from == $0 || c.to == $0 } ?? false
            // Drag in progress: possible spots thicken.
            let candidate = (candidates.contains(c.id) || libraryDrop != nil) && !touchesMoving
            let ca = VF.color(for: a, category: app.category(for: a)), cb = VF.color(for: b, category: app.category(for: b))
            let shading: GraphicsContext.Shading = selected ? .color(VF.accent)
                : (isActive ? .linearGradient(Gradient(colors: [ca, cb]), startPoint: p0, endPoint: p3) : .color(VF.wireInactive))
            var width: CGFloat = (selected ? 4 : 3) + boost
            if candidate { width += 1.5 }
            if target == c.id { continue } // drawn by the insertion layer
            ctx.opacity = touchesMoving ? 0.35 : 1
            ctx.stroke(path, with: shading,
                       style: StrokeStyle(lineWidth: width * max(zoom, 0.6), lineCap: .round, dash: isActive && !touchesMoving ? [] : [5, 4]))
            ctx.opacity = 1
        }
    }

    /// Insertion marker, targeted connection and preview of the new order (reorder or library).
    @ViewBuilder
    func insertionLayer(_ graph: ProcessingGraph, geo: EditorGeometry, ngeo: EditorGeometry) -> some View {
        let target = reorder?.target ?? libraryDrop
        if let t = target, let c = graph.connections.first(where: { $0.id == t.connection }), let (p0, p3) = geo.ends(c, in: graph) {
            let ok = t.error == nil
            let color = ok ? VF.accent : VF.danger
            ZStack(alignment: .topLeading) {
                geo.bezier(p0, p3).stroke(color, style: StrokeStyle(lineWidth: 5 * max(zoom, 0.6), lineCap: .round))
                // Preview of the new routing: X → ghost → Y, and A → B where the node was.
                if ok, let r = reorder, let n = graph.node(r.node) {
                    geo.bezier(p0, ngeo.inputPort(n)).stroke(VF.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    geo.bezier(ngeo.outputPort(n), p3).stroke(VF.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    if let planned = r.result {
                        let current = Set(graph.connections.map { [$0.from, $0.to] })
                        ForEach(planned.connections.filter { $0.from != r.node && $0.to != r.node && !current.contains([$0.from, $0.to]) }) { c in
                            if let (a, b) = geo.ends(c, in: graph) {
                                geo.bezier(a, b).stroke(VF.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            }
                        }
                    }
                }
                Circle().fill(color)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .overlay(Image(systemName: ok ? "plus" : "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white))
                    .frame(width: 20, height: 20)
                    .offset(x: t.point.x - 10, y: t.point.y - 10)
            }
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: t)
        }
    }

    /// ⊕ markers on every connection where the dragged node can be dropped (identifiable targets).
    @ViewBuilder
    func candidatesLayer(_ graph: ProcessingGraph, geo: EditorGeometry, candidates: Set<UUID>) -> some View {
        let active = reorder?.target?.connection
        ForEach(graph.connections.filter { candidates.contains($0.id) && $0.id != active }) { c in
            if let m = geo.midpoint(c, in: graph) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .heavy)).foregroundStyle(VF.accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(VF.panel))
                    .overlay(Circle().strokeBorder(VF.accent, lineWidth: 1.5))
                    .offset(x: m.x - 9, y: m.y - 9)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    func connectionHandle(_ c: GraphConnection, graph: ProcessingGraph, geo: EditorGeometry) -> some View {
        if let m = geo.midpoint(c, in: graph), reorder == nil, dropTargetsNode == nil {
            let sel = app.selectedConnection == c.id
            Circle()
                .fill(sel ? VF.accent : VF.panel3)
                .overlay(Circle().strokeBorder(sel ? VF.accent : VF.wire, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .contentShape(Circle().inset(by: -5))
                .offset(x: m.x - 5.5, y: m.y - 5.5)
                .onTapGesture { app.selectedConnection = c.id; app.selectedNodes = []; focused = true }
                .contextMenu {
                    Button("Insert Gain") { _ = app.engine.addNode(kind: .gain, at: geo.world(m), insertOn: c.id) }
                    Button("Insert Analyzer") { _ = app.engine.addNode(kind: .analyzer, at: geo.world(m), insertOn: c.id) }
                    Divider()
                    Button("Delete Connection", role: .destructive) { app.engine.disconnect(c.id) }
                }
                .help("Connection — click to select, Delete to remove, right-click to insert a node")
        }
    }

    @ViewBuilder
    func groupsLayer(_ graph: ProcessingGraph, geo: EditorGeometry) -> some View {
        ForEach(graph.groups) { g in
            let members = graph.nodes.filter { $0.groupID == g.id }
            if !members.isEmpty {
                let rect = members.map(geo.rect).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -16 * zoom, dy: -16 * zoom)
                let r = CGRect(x: rect.minX, y: rect.minY - 22 * zoom, width: rect.width, height: rect.height + 22 * zoom)
                let color = VF.groupColors[g.colorIndex % VF.groupColors.count]
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12 * zoom).fill(color.opacity(g.bypassed ? 0.03 : 0.07))
                    RoundedRectangle(cornerRadius: 12 * zoom).strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                    HStack(spacing: 6) {
                        Text(g.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                        Button { app.engine.setGroupBypass(g.id, !g.bypassed) } label: {
                            Image(systemName: "power").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(g.bypassed ? VF.text3 : color)
                        }
                        .buttonStyle(.plain)
                        .help(g.bypassed ? "Section bypassed — click to enable" : "Bypass the whole section")
                        if g.bypassed { Text("bypassed").font(.system(size: 10)).foregroundStyle(VF.warn) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contextMenu {
                        Button("Ungroup Section") { app.engine.removeGroup(g.id) }
                    }
                }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
        }
    }

    // MARK: Floating controls (native Liquid Glass)

    var overlayControls: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                if locked {
                    Button { app.engine.settings.lockEditing = false } label: { Label("Editing Locked", systemImage: "lock.fill") }
                        .buttonStyle(.glass)
                        .help("Click to unlock")
                }
                Spacer()
                if let hint = dragHint {
                    DragHintView(hint: hint).frame(maxWidth: 580)
                    Spacer()
                }
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Button { app.editorCommand = .zoomOut } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                                .help("Zoom out (⌘-)")
                            Button { app.editorCommand = .resetZoom } label: {
                                Text(verbatim: "\(Int(zoom * 100))%").font(VF.mono).frame(width: 48, height: 22)
                            }
                            .help("Zoom to 100%")
                            Button { app.editorCommand = .zoomIn } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                                .help("Zoom in (⌘+)")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button { app.editorCommand = .fit } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Zoom to fit (⌘0)")
                        Button { app.engine.arrangeGraph(rowWidth: max(Double((size.width - 120) / zoom), 600)); app.editorCommand = .fit } label: {
                            Image(systemName: "wand.and.stars")
                        }
                        .disabled(locked)
                        .help("Arrange nodes in chain order (positions only, the sound doesn't change; ⌘Z to undo)")
                        Button { app.engine.settings.lockEditing.toggle() } label: {
                            Image(systemName: locked ? "lock.fill" : "lock.open")
                        }
                        .help("Protects against accidental edits (⌥⌘L)")
                    }
                    .buttonStyle(.glass)
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                Menu {
                    Button("Gain") { add(.gain) }
                    Button("Analyzer") { add(.analyzer) }
                    Button("Dedicated Monitoring Output") { add(.monitorOutput) }
                } label: { Label("Add Native Node", systemImage: "plus.circle.fill") }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .disabled(locked)
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if !reorderTipSeen && !locked {
                        ReorderTip { reorderTipSeen = true }
                    }
                    EditorHelpBar()
                }
            }
        }
        .padding(10)
    }

    /// What will happen on release, shown at the top of the canvas during any drag.
    var dragHint: DragHint? {
        if let t = libraryDrop { return t.error.map { .refused($0.description) } ?? .insert(t.preview) }
        if let r = reorder {
            guard let t = r.target else { return .strictIdle }
            return t.error.map { .refused($0.description) } ?? .reorder(t.preview)
        }
        guard !draggingNodes.isEmpty, dragDelta != .zero else { return nil }
        if draggingNodes.count > 1 { return .moveMany(draggingNodes.count) }
        if !candidateTargets.isEmpty { return .move }
        let reason = dropTargets.values.lazy.compactMap { r -> ChainEditError? in if case .failure(let e) = r { e } else { nil } }.first
        return .moveOnly(reason?.description)
    }

    func add(_ kind: NodeKind) {
        let center = wireGeometry.world(CGPoint(x: size.width / 2 - NodeMetrics.width * zoom / 2, y: size.height / 2))
        if let id = app.engine.addNode(kind: kind, at: center) { app.selectedNodes = [id] }
    }

    // MARK: Interaction: nodes

    /// Click on a node: immediate selection (the single gesture no longer depends on a competing
    /// double gesture, so no waiting for the double-click delay). Double-click is read from the event.
    func nodeClicked(_ node: GraphNode) {
        focused = true
        app.selectedConnection = nil
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { app.openPluginUI(node.id); return }
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) || mods.contains(.command) {
            if app.selectedNodes.contains(node.id) { app.selectedNodes.remove(node.id) } else { app.selectedNodes.insert(node.id) }
        } else {
            app.selectedNodes = [node.id]
        }
    }

    func nodeDrag(_ node: GraphNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("editor"))
            .onChanged { v in nodeDragChanged(node, translation: v.translation, location: v.location, start: v.startLocation) }
            .onEnded { _ in nodeDragEnded() }
    }

    func nodeDragChanged(_ node: GraphNode, translation: CGSize, location: CGPoint, start: CGPoint) {
        // A wire or a grip ≡ (subview gestures) is already in control.
        guard wire == nil, !locked else { return }
        if press?.node != node.id {
            let p = Press(node: node.id, reorder: NSEvent.modifierFlags.contains(.option),
                          ignored: startsOnControl(node, at: start))
            press = p
            if p.ignored { return }
            focused = true
            app.selectedConnection = nil
        }
        guard let p = press, !p.ignored else { return }
        if let r = reorder, r.strict, !p.reorder { return }
        if p.reorder && !node.kind.isUnique {
            // ⌥ + drag: same gesture as the grip ≡.
            ensureTargets(for: node)
            updateReorder(node, translation: translation, pointer: location, strict: true)
            return
        }
        if draggingNodes.isEmpty {
            if !app.selectedNodes.contains(node.id) { app.selectedNodes = [node.id] }
            draggingNodes = app.selectedNodes
            // A single dragged node: it can be dropped on a connection to change the order.
            if draggingNodes == [node.id] { ensureTargets(for: node) }
        }
        dragDelta = CGSize(width: translation.width / zoom, height: translation.height / zoom)
        if dropTargetsNode == node.id {
            updateReorder(node, translation: translation, pointer: location, strict: false)
        }
    }

    func nodeDragEnded() {
        defer { press = nil }
        if reorder != nil { reorderEnded(); return }
        finishFreeMove()
    }

    /// Replays a drag (gesture test): same functions, same steps as the mouse.
    func playDebugDrag(_ d: EditorDebugDrag) async {
        guard let node = app.engine.graph.node(d.node) else { return }
        persistViewport() // the test reads back the view actually displayed
        let geo = wireGeometry
        let from = geo.screen(GraphPoint(x: d.from.x, y: d.from.y)), to = geo.screen(GraphPoint(x: d.to.x, y: d.to.y))
        for i in 1...24 {
            let t = CGFloat(i) / 24
            let loc = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            let tr = CGSize(width: loc.x - from.x, height: loc.y - from.y)
            if d.grip {
                gripChanged(node, translation: tr, location: loc)
            } else {
                nodeDragChanged(node, translation: tr, location: loc, start: from)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(700))
        d.beforeRelease?()
        if d.grip { gripEnded() } else { nodeDragEnded() }
        d.finished()
    }

    /// True if `p` (editor coordinate space) falls on the node's ⏻ button: a click or a slight
    /// drag on a control is never interpreted as a move.
    func startsOnControl(_ node: GraphNode, at p: CGPoint) -> Bool {
        guard !node.kind.isUnique && node.kind != .analyzer else { return false }
        let o = nodeGeometry.origin(node)
        let x = (p.x - o.x) / zoom, y = (p.y - o.y) / zoom
        return x > NodeMetrics.width - 36 && x < NodeMetrics.width - 4 && y > 2 && y < 34
    }

    /// End of a free move: positions only, 10 pt snapping, no audio effect.
    func finishFreeMove() {
        defer { clearTargets() }
        guard !draggingNodes.isEmpty else { return }
        var moves: [UUID: GraphPoint] = [:]
        for id in draggingNodes {
            if let n = app.engine.graph.node(id) {
                moves[id] = GraphPoint(x: ((n.position.x + dragDelta.width) / 10).rounded() * 10,
                                       y: ((n.position.y + dragDelta.height) / 10).rounded() * 10)
            }
        }
        app.engine.moveNodes(moves, registerUndo: true)
        draggingNodes = []
        dragDelta = .zero
    }

    // MARK: Interaction: move within the chain

    /// Connections where the dragged node can be dropped (⊕ markers).
    var candidateTargets: Set<UUID> {
        guard dropTargetsNode != nil else { return [] }
        return Set(dropTargets.compactMap { id, r in if case .success = r { id } else { nil } })
    }

    /// Computes once, at the start of the gesture, where the node can be dropped (same operation as applying it).
    func ensureTargets(for node: GraphNode) {
        guard dropTargetsNode != node.id else { return }
        dropTargetsNode = node.id
        dropTargets = node.kind.isUnique || locked ? [:] : app.engine.graph.chainDropTargets(for: node.id)
    }

    func clearTargets() {
        dropTargets = [:]
        dropTargetsNode = nil
    }

    /// Connection aimed at by the pointer. `validOnly` (plain drag): only valid targets snap,
    /// elsewhere it is a visual move. An acquired target stays acquired up to `snapOut`.
    func hitTarget(at p: CGPoint, validOnly: Bool) -> (connection: UUID, point: CGPoint, result: Result<ProcessingGraph, ChainEditError>)? {
        let graph = app.engine.graph
        let geo = wireGeometry
        if let cur = reorder?.target?.connection, let r = dropTargets[cur],
           let hit = geo.nearestConnection(to: p, in: graph, maxDistance: Self.snapOut, where: { $0.id == cur }) {
            return (cur, hit.point, r)
        }
        guard let hit = geo.nearestConnection(to: p, in: graph, maxDistance: Self.snapIn, where: { c in
            guard let r = dropTargets[c.id] else { return false }
            if validOnly, case .failure = r { return false }
            return true
        }), let r = dropTargets[hit.connection.id] else { return nil }
        return (hit.connection.id, hit.point, r)
    }

    /// Follows the pointer during a drag: targeted connection, node snapping, preview of the new order.
    func updateReorder(_ node: GraphNode, translation: CGSize, pointer: CGPoint, strict: Bool) {
        guard !locked, !node.kind.isUnique else { return }
        var ghost = GraphPoint(x: node.position.x + translation.width / zoom, y: node.position.y + translation.height / zoom)
        var target: InsertionTarget?
        var result: ProcessingGraph?
        if let hit = hitTarget(at: pointer, validOnly: !strict) {
            switch hit.result {
            case .success(let g):
                target = InsertionTarget(connection: hit.connection, point: hit.point, error: nil, preview: Self.preview(g, around: node.id))
                result = g
                // Snapping: the node sits on the insertion marker, or at the nearest free spot if it
                // would overlap its neighbors. That is where it will land on release.
                let w = wireGeometry.world(hit.point)
                ghost = freeSpot(near: GraphPoint(x: w.x - NodeMetrics.width / 2, y: w.y - NodeMetrics.height / 2), for: node.id)
            case .failure(let e):
                target = InsertionTarget(connection: hit.connection, point: hit.point, error: e, preview: [])
            }
        }
        // Plain drag without a target: visual move, no “chain” state.
        guard strict || target != nil else {
            if reorder != nil { animateSnap { reorder = nil } }
            return
        }
        if reorder == nil { app.selectedNodes = [node.id] }
        let next = ReorderDrag(node: node.id, ghost: ghost, target: target, strict: strict, result: result)
        if reorder?.target?.connection != target?.connection { animateSnap { reorder = next } } else { reorder = next }
    }

    /// Nearest free spot to `p` (top-left corner, graph coordinates), visible on screen, where
    /// node `id` overlaps no other node. The other nodes never move.
    func freeSpot(near p: GraphPoint, for id: UUID) -> GraphPoint {
        let w = NodeMetrics.width, h = NodeMetrics.height
        let others = app.engine.graph.nodes.filter { $0.id != id }
            .map { CGRect(x: $0.position.x, y: $0.position.y, width: w, height: h).insetBy(dx: -16, dy: -26) }
        let o = wireGeometry.world(.zero)
        let visible = CGRect(x: o.x, y: o.y, width: size.width / zoom, height: size.height / zoom).insetBy(dx: 8, dy: 8)
        func fits(_ x: Double, _ y: Double) -> Bool {
            let r = CGRect(x: x, y: y, width: w, height: h)
            return !others.contains { $0.intersects(r) } && (visible.isEmpty || visible.contains(r))
        }
        if fits(p.x, p.y) { return p }
        var best: (GraphPoint, Double)?
        for dy in stride(from: -420.0, through: 420, by: 10) {
            for dx in stride(from: -420.0, through: 420, by: 10) {
                let d = dx * dx + dy * dy
                if d < (best?.1 ?? .infinity), fits(p.x + dx, p.y + dy) { best = (GraphPoint(x: p.x + dx, y: p.y + dy), d) }
            }
        }
        return best?.0 ?? p
    }

    func animateSnap(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.snappy(duration: 0.15)) { change() } }
    }

    func gripChanged(_ node: GraphNode, translation: CGSize, location: CGPoint) {
        guard !locked else { return }
        ensureTargets(for: node)
        updateReorder(node, translation: translation, pointer: location, strict: true)
    }

    func gripEnded() {
        if reorder != nil { reorderEnded() } else { clearTargets() }
    }

    func reorderEnded() {
        guard let r = reorder else { return }
        defer {
            draggingNodes = []
            dragDelta = .zero
            clearTargets()
            if reduceMotion { reorder = nil } else { withAnimation(.snappy(duration: 0.2)) { reorder = nil } }
        }
        guard let t = r.target else { return } // grip released away from a connection: nothing changes
        if let err = t.error {
            showRefusal(err.description, at: t.point)
            app.engine.post(.warning, String(localized: "Move refused: \(String(describing: err))"))
            return
        }
        let snapped = GraphPoint(x: (r.ghost.x / 10).rounded() * 10, y: (r.ghost.y / 10).rounded() * 10)
        if let err = app.engine.moveInChain(r.node, onto: t.connection, position: snapped) {
            if err != .noChange { showRefusal(err.description, at: t.point) }
        } else {
            reorderTipSeen = true
        }
    }

    /// Readable preview of the order around the moved node: “… → CLA-76 → [F6] → Sibilance → …”.
    static func preview(_ g: ProcessingGraph, around id: UUID) -> [String] {
        let chain = g.mainChain()
        guard let i = chain.firstIndex(of: id) else { return [] }
        let lo = max(0, i - 2), hi = min(chain.count - 1, i + 2)
        var out: [String] = lo > 0 ? ["…"] : []
        for k in lo...hi {
            guard let n = g.node(chain[k]) else { continue }
            let name = n.kind == .input ? String(localized: "Input") : (n.kind == .output ? String(localized: "Output") : n.title)
            out.append(k == i ? "[\(name)]" : name)
        }
        if hi < chain.count - 1 { out.append("…") }
        return out
    }

    func showRefusal(_ message: String, at point: CGPoint) {
        let r = Refusal(point: point, message: message)
        refusal = r
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if refusal == r { refusal = nil }
        }
    }

    func cancelGestures() {
        reorder = nil; wire = nil; lasso = nil
        // The current gesture keeps sending events until release: it is ignored.
        press = press.map { Press(node: $0.node, reorder: $0.reorder, ignored: true) }
        draggingNodes = []; dragDelta = .zero
        clearTargets()
    }

    // MARK: Interaction: connections

    func wireChanged(from: UUID, to loc: CGPoint) {
        guard !locked else { return }
        let graph = app.engine.graph
        var target: UUID?
        for n in graph.nodes where n.id != from && n.kind.hasInputPort {
            if nodeGeometry.rect(n).insetBy(dx: -14, dy: -10).contains(loc) { target = n.id; break }
        }
        wire = WireDrag(from: from, to: loc, target: target, error: target.flatMap { graph.connectionError(from: from, to: $0) })
    }

    func wireEnded() {
        defer { wire = nil }
        guard let w = wire, let t = w.target else { return }
        if let err = w.error {
            // Visible refusal, nothing is modified (neither the graph nor the sound).
            showRefusal(err.description, at: w.to)
            app.engine.post(.warning, String(localized: "Connection refused: \(String(describing: err))"))
        } else {
            app.engine.connect(from: w.from, to: t)
        }
    }

    // MARK: Interaction: background (lasso / view)

    var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("editor"))
            .onChanged { v in
                if spaceDown || panStart != nil {
                    if panStart == nil { panStart = offset }
                    offset = CGSize(width: (panStart?.width ?? 0) + v.translation.width, height: (panStart?.height ?? 0) + v.translation.height)
                    return
                }
                if lasso == nil {
                    let mods = NSEvent.modifierFlags
                    let additive = mods.contains(.shift) || mods.contains(.command)
                    lasso = Lasso(start: v.startLocation, current: v.location, base: additive ? app.selectedNodes : [])
                    app.selectedConnection = nil
                    focused = true
                }
                lasso?.current = v.location
                if let l = lasso {
                    let geo = nodeGeometry
                    let hit = Set(app.engine.graph.nodes.filter { geo.rect($0).intersects(l.rect) }.map(\.id))
                    app.selectedNodes = l.base.union(hit)
                }
            }
            .onEnded { _ in
                if panStart != nil { panStart = nil; persistViewport() }
                lasso = nil
            }
    }

    // MARK: Drag and drop from the library

    func libraryHover(at loc: CGPoint?) {
        guard let loc, !locked else { libraryDrop = nil; return }
        let graph = app.engine.graph
        guard let hit = wireGeometry.nearestConnection(to: loc, in: graph, maxDistance: 40) else { libraryDrop = nil; return }
        // Preview computed by the same operation as the real insertion (temporary node).
        let probe = GraphNode(kind: .gain, title: String(localized: "New"), position: .init(x: 0, y: 0))
        let result = Result { try graph.inserting(probe, on: hit.connection.id) }
        let t: InsertionTarget
        switch result {
        case .success(let g): t = InsertionTarget(connection: hit.connection.id, point: hit.point, error: nil, preview: Self.preview(g, around: probe.id))
        case .failure(let err): t = InsertionTarget(connection: hit.connection.id, point: hit.point, error: err as? ChainEditError ?? .unknownNode, preview: [])
        }
        if t != libraryDrop { libraryDrop = t }
    }

    func handleDrop(_ item: String, at loc: CGPoint) -> Bool {
        defer { libraryDrop = nil }
        guard !locked else { app.engine.post(.warning, String(localized: "Editing is locked.")); return false }
        let geo = wireGeometry
        let pos = geo.world(CGPoint(x: loc.x - NodeMetrics.width * zoom / 2, y: loc.y - NodeMetrics.height * zoom / 2))
        let snapped = GraphPoint(x: (pos.x / 10).rounded() * 10, y: (pos.y / 10).rounded() * 10)
        // Drop near a connection: insert at that exact spot; otherwise a free, unconnected node.
        let target = libraryDrop?.error == nil ? libraryDrop?.connection : nil
        var newID: UUID?
        if item.hasPrefix("plugin:") {
            let id = String(item.dropFirst(7))
            guard let info = app.engine.plugins.first(where: { $0.id == id }) else { return false }
            newID = app.engine.addNode(kind: .audioUnit, plugin: info.reference, at: snapped, insertOn: target)
        } else if item.hasPrefix("native:"), let kind = NodeKind(rawValue: String(item.dropFirst(7))) {
            newID = app.engine.addNode(kind: kind, at: snapped, insertOn: kind == .monitorOutput ? nil : target)
        }
        if let newID { app.selectedNodes = [newID] }
        return newID != nil
    }

    // MARK: View (zoom / pan)

    func setZoom(_ z: CGFloat, around p: CGPoint, persist: Bool = true) {
        let nz = min(max(z, 0.3), 2.5)
        let w = wireGeometry.world(p)
        zoom = nz
        offset = CGSize(width: p.x - w.x * nz, height: p.y - w.y * nz)
        if persist { persistViewport() }
    }

    func fitAll() {
        let nodes = app.engine.graph.nodes
        guard !nodes.isEmpty, size.width > 0 else { return }
        let minX = nodes.map(\.position.x).min()!, maxX = nodes.map(\.position.x).max()! + NodeMetrics.width
        let minY = nodes.map(\.position.y).min()!, maxY = nodes.map(\.position.y).max()! + NodeMetrics.height
        let pad: CGFloat = 80
        let z = min((size.width - pad * 2) / max(maxX - minX, 1), (size.height - pad * 2) / max(maxY - minY, 1))
        zoom = min(max(z, 0.3), 1.4)
        offset = CGSize(width: (size.width - (maxX - minX) * zoom) / 2 - minX * zoom,
                        height: (size.height - (maxY - minY) * zoom) / 2 - minY * zoom)
        persistViewport()
    }

    func loadViewport() {
        let v = app.engine.graph.viewport
        zoom = CGFloat(v.zoom)
        offset = CGSize(width: v.offsetX, height: v.offsetY)
        if v == GraphViewport() { DispatchQueue.main.async { fitAll() } }
    }

    func persistViewport() {
        app.engine.setViewport(GraphViewport(offsetX: offset.width, offsetY: offset.height, zoom: zoom))
    }

    func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let p = hoverLocation, event.window?.isKeyWindow == true || event.window != nil else { return event }
            if event.modifierFlags.contains(.command) {
                let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)
                setZoom(zoom * factor, around: p, persist: false)
            } else {
                offset.width += event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 8)
                offset.height += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
            }
            if event.phase == .ended || event.momentumPhase == .ended || !event.hasPreciseScrollingDeltas { persistViewport() }
            return nil
        }
    }

    func removeScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }
}

/// Drag replayed by the gesture test (`EditorUITest`), in graph coordinates (independent of the view).
struct EditorDebugDrag {
    let id = UUID()
    let node: UUID
    let from: CGPoint
    let to: CGPoint
    var grip = false
    var beforeRelease: (() -> Void)?
    var finished: () -> Void = {}
}

/// Receives drag and drop from the library, tracking the pointer while hovering
/// (insertion marker) — `DropDelegate` provides the location, unlike `dropDestination`.
struct LibraryDropDelegate: DropDelegate {
    static let types: [UTType] = [.utf8PlainText, .plainText, .text]
    let onHover: (CGPoint?) -> Void
    let onDrop: (String, CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }
    func dropEntered(info: DropInfo) { onHover(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? { onHover(info.location); return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { onHover(nil) }
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: Self.types).first else { onHover(nil); return false }
        let loc = info.location
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? NSString else { return }
            let item = String(s)
            DispatchQueue.main.async { _ = onDrop(item, loc) }
        }
        return true
    }
}

/// Level glow on connections: the only layer that reads the meters (30 Hz), so that the
/// editor and its gestures are not re-evaluated on every reading.
struct ConnectionGlowLayer: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let graph: ProcessingGraph
    let active: Set<UUID>
    let geo: EditorGeometry
    let hidden: UUID?

    var body: some View {
        let levels = app.meters.nodes
        Canvas { ctx, _ in
            guard !reduceMotion else { return }
            for c in graph.connections where active.contains(c.from) && active.contains(c.to) && c.from != hidden && c.to != hidden {
                let level = levels[c.from]?.maxPeak ?? 0
                guard level > 0.001, let (a, b) = geo.ends(c, in: graph) else { continue }
                let glow = CGFloat(meterFraction(level))
                ctx.stroke(geo.bezier(a, b), with: .color(VF.wire.opacity(0.10 + 0.25 * glow)), lineWidth: (3 + 7 * glow) * max(geo.zoom, 0.5))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Operation performed on release (visual move, reorder, insertion, refusal).
enum DragHint: Equatable {
    case move, moveMany(Int), moveOnly(String?), strictIdle
    case reorder([String]), insert([String]), refused(String)
}

/// Preview of the operation during a drag (glass capsule). The icon and the text state the
/// operation: color is never the only cue.
struct DragHintView: View {
    let hint: DragHint
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                if let parts { Text(Self.attributed(parts)).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    var symbol: String {
        switch hint {
        case .move, .moveMany, .moveOnly: "arrow.up.and.down.and.arrow.left.and.right"
        case .strictIdle: "line.3.horizontal"
        case .reorder: "arrow.trianglehead.branch"
        case .insert: "plus.circle.fill"
        case .refused: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch hint {
        case .refused: VF.danger
        case .reorder, .insert, .strictIdle: VF.accent
        default: .secondary
        }
    }

    var title: String {
        switch hint {
        case .move: String(localized: "Visual move: the sound doesn't change")
        case .moveMany(let n): String(localized: "Moving \(n) nodes: the sound doesn't change")
        case .moveOnly: String(localized: "Visual move only")
        case .strictIdle: String(localized: "Reorder the audio chain")
        case .reorder: String(localized: "Release to reorder the audio chain")
        case .insert: String(localized: "Release to insert here")
        case .refused: String(localized: "Not possible here: the order won't change")
        }
    }

    var detail: String? {
        switch hint {
        case .move: String(localized: "Drop the node on a ⊕ marker to change the processing order.")
        case .moveOnly(let reason): reason
        case .strictIdle: String(localized: "Aim for a ⊕ connection. Released elsewhere, nothing changes.")
        case .refused(let message): message
        default: nil
        }
    }

    var parts: [String]? {
        switch hint {
        case .reorder(let p), .insert(let p): p
        default: nil
        }
    }

    static func attributed(_ parts: [String]) -> AttributedString {
        var out = AttributedString()
        for (i, p) in parts.enumerated() {
            if i > 0 { out += AttributedString(" → ") }
            if p.hasPrefix("["), p.hasSuffix("]") {
                var s = AttributedString(String(p.dropFirst().dropLast()))
                s.font = .system(size: 11, weight: .heavy)
                s.foregroundColor = VF.accent
                s.underlineStyle = .single
                out += s
            } else {
                out += AttributedString(p)
            }
        }
        return out
    }
}

/// Canvas help bar: the two main gestures spelled out, the rest under “Other Gestures”.
/// Opaque background and contrasted text (dense text, never placed on glass).
struct EditorHelpBar: View {
    @State private var showAll = false

    var body: some View {
        HStack(spacing: 0) {
            item("arrow.up.and.down.and.arrow.left.and.right", action: "Move", gesture: "Drag a node",
                 help: "Moves the node on the canvas. Position only: the sound and the processing order don't change.")
            Divider().frame(height: 26)
            item("plus.circle", action: "Reorder the audio chain", gesture: "Drop the node on a ⊕ connection",
                 help: "While dragging, every connection the node can go to shows a ⊕ marker. Dropped on one, the node changes place in the processing: a preview of the new order appears before you release. ⌘Z undoes.")
            Divider().frame(height: 26)
            Button { showAll.toggle() } label: {
                Label("Other Gestures", systemImage: "questionmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VF.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("All canvas gestures and shortcuts")
            .popover(isPresented: $showAll, arrowEdge: .top) { EditorGestureList() }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(VF.panel.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(VF.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas help")
    }

    func item(_ symbol: String, action: LocalizedStringKey, gesture: LocalizedStringKey, help: LocalizedStringKey) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(VF.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(action).font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.text)
                Text(gesture).font(.system(size: 10)).foregroundStyle(VF.text2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }
}

/// Full list of gestures (“Other Gestures” popover), grouped from most to least common.
struct EditorGestureList: View {
    static let sections: [(String, [(String, String)])] = [
        (String(localized: "Main gestures"), [
            (String(localized: "Drag a node"), String(localized: "Move (the sound doesn't change)")),
            (String(localized: "Drop a node on a ⊕ connection"), String(localized: "Reorder the audio chain")),
            (String(localized: "Grip ≡ or ⌥ + drag"), String(localized: "Reorder only (released elsewhere: canceled)")),
            (String(localized: "Drag from the output port"), String(localized: "Connect two nodes")),
        ]),
        (String(localized: "Nodes"), [
            (String(localized: "Click · ⇧ or ⌘ + click"), String(localized: "Select · add to selection")),
            (String(localized: "Double-click"), String(localized: "Open the plugin interface")),
            (String(localized: "⏻ button · B key"), String(localized: "Bypass")),
            ("⌥⌘↑ · ⌥⌘↓", String(localized: "Move up · down in the chain")),
            (String(localized: "Delete · ⌘D · ⌘G"), String(localized: "Delete · duplicate · group")),
        ]),
        (String(localized: "View"), [
            (String(localized: "Drag on the background"), String(localized: "Lasso selection")),
            (String(localized: "Space + drag · scroll wheel"), String(localized: "Pan the view")),
            (String(localized: "⌘ + scroll wheel · pinch · ⌘0"), String(localized: "Zoom · zoom to fit")),
            (String(localized: "Esc · ⌘Z"), String(localized: "Cancel the current gesture · undo")),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.sections, id: \.0) { title, rows in
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(VF.text2)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(rows, id: \.0) { gesture, action in
                            GridRow {
                                Text(gesture).font(.system(size: 11, weight: .semibold)).foregroundStyle(VF.text)
                                Text(action).font(.system(size: 11)).foregroundStyle(VF.text2)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 470, alignment: .leading)
    }
}

/// Tip shown on first use, until “Got It” or the first successful reorder.
struct ReorderTip: View {
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lightbulb.fill").foregroundStyle(VF.warn)
            VStack(alignment: .leading, spacing: 6) {
                Text("Change the processing order").font(.system(size: 12, weight: .semibold)).foregroundStyle(VF.text)
                Text("Drag a node to a connection: a ⊕ marker and a preview of the new order appear before you release. Anywhere else on the canvas, the node is only moved.")
                    .font(.system(size: 11)).foregroundStyle(VF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Got It", action: dismiss).controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(VF.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(VF.accent.opacity(0.7), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Refusal badge: solid color and white text, never placed on glass.
struct RefusalBadge: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(VF.danger))
            .accessibilityLabel("Refused: \(message)")
    }
}

struct GridBackground: View {
    let offset: CGSize
    let zoom: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let step = 24 * zoom
            guard step > 4 else { return }
            let ox = offset.width.truncatingRemainder(dividingBy: step)
            let oy = offset.height.truncatingRemainder(dividingBy: step)
            var dots = Path()
            var x = ox
            while x < size.width {
                var y = oy
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                    y += step
                }
                x += step
            }
            ctx.fill(dots, with: .color(VF.grid))
        }
    }
}

// MARK: - Node

enum WireTargetState { case none, valid, invalid }

/// Reorder grip ≡: visible pill, “hand” cursor, highlighted on hover.
/// Explicit variant of the drag: released away from a connection, nothing changes.
struct ReorderGrip: View {
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: () -> Void
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        let on = hover || dragging
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(on ? VF.accent : VF.text2)
            .frame(width: 18, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? VF.accent.opacity(0.18) : VF.panel3))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? VF.accent.opacity(0.8) : VF.border, lineWidth: 1))
            .contentShape(Rectangle())
            .pointerStyle(dragging ? .grabActive : .grabIdle)
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("editor"))
                .onChanged { v in dragging = true; onChanged(v) }
                .onEnded { _ in dragging = false; onEnded() })
            .help("Reorder the audio chain: drag to a ⊕ connection (released elsewhere, nothing changes)")
            .accessibilityHidden(true) // from the keyboard: ⌥⌘↑ / ⌥⌘↓ or the context menu
    }
}

struct NodeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorSchemeContrast) private var contrast
    let node: GraphNode
    let selected: Bool
    let active: Bool
    let orderIndex: Int?
    /// Planned number differs from the current one (preview of a reorder before release).
    let orderChanged: Bool
    let wireTarget: WireTargetState
    let lifted: Bool
    let canReorder: Bool
    let onWireChanged: (CGPoint) -> Void
    let onWireEnded: () -> Void
    let onGripChanged: (DragGesture.Value) -> Void
    let onGripEnded: () -> Void

    var body: some View {
        let e = app.engine
        let cat = app.category(for: node)
        let color = VF.color(for: node, category: cat)
        let status = e.nodeStatus[node.id] ?? .ok
        let bypassed = e.graph.isEffectivelyBypassed(node)
        let isIO = node.kind == .input || node.kind == .output || node.kind == .monitorOutput
        let strong = contrast == .increased
        let border: Color = switch wireTarget {
        case .valid: VF.ok
        case .invalid: VF.danger
        case .none: color.opacity(bypassed ? (strong ? 0.7 : 0.35) : 0.9)
        }

        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                // Header: reorder grip, icon, name, status / enable button.
                HStack(spacing: 7) {
                    if canReorder {
                        ReorderGrip(onChanged: onGripChanged, onEnded: onGripEnded)
                    }
                    Image(systemName: VF.symbol(for: node, category: cat))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    Text(node.kind == .input ? String(localized: "Input") : node.kind == .output ? String(localized: "Output") : isIO ? node.kind.displayName : node.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    statusBadge(status, bypassed: bypassed)
                    if !node.kind.isUnique && node.kind != .analyzer {
                        Button { e.setNodeBypass(node.id, !node.bypassed) } label: {
                            Image(systemName: "power").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(node.bypassed ? VF.text3 : VF.onTint(color))
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 5).fill(node.bypassed ? VF.panel3 : color))
                        }
                        .buttonStyle(.plain).help(node.bypassed ? "Enable" : "Bypass")
                        .accessibilityLabel(node.bypassed ? "Enable \(node.title)" : "Bypass \(node.title)")
                    }
                }
                .padding(.leading, canReorder ? 6 : 10).padding(.trailing, 10).padding(.top, 9).padding(.bottom, 7)

                // Visualization: real signal at the node's output.
                Group {
                    if isIO {
                        HStack(spacing: 8) {
                            Image(systemName: node.kind == .input ? "mic.fill" : (node.kind == .output ? "dot.radiowaves.left.and.right" : "headphones"))
                                .font(.system(size: 24)).foregroundStyle(color)
                                .frame(width: 58, height: 58)
                                .background(RoundedRectangle(cornerRadius: 10).fill(VF.panel3))
                            Spacer()
                            NodeLevelMeter(nodeID: node.id).frame(width: 12)
                        }
                        .padding(.horizontal, 10)
                    } else {
                        NodeMiniView(nodeID: node.id, color: color, spectrum: cat == .eq || cat == .filter || node.kind == .analyzer)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28)))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 9)
                    }
                }
                .frame(height: 64)

                // Footer: name and type.
                VStack(alignment: .leading, spacing: 1) {
                    Text(footerTitle(cat)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(subtitle(cat)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(detail).font(.system(size: 9, design: .monospaced)).lineLimit(1)
                    }
                    .font(.system(size: 10)).foregroundStyle(strong ? VF.text : VF.text2)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .frame(width: NodeMetrics.width, height: NodeMetrics.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(VF.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(border, lineWidth: (selected || wireTarget != .none ? 2.5 : 1.6) + (strong ? 1 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VF.accent.opacity(selected ? 0.9 : 0), lineWidth: 1.5).padding(-4))
            .shadow(color: lifted ? .black.opacity(0.35) : color.opacity(selected ? 0.45 : 0.18), radius: lifted ? 18 : (selected ? 12 : 6), y: lifted ? 8 : 0)
            .opacity(bypassed || !active ? (strong ? 0.75 : 0.55) : 1)

            // Ports.
            if node.kind.hasInputPort {
                Circle().fill(VF.panel).overlay(Circle().strokeBorder(color, lineWidth: 2.5))
                    .frame(width: NodeMetrics.portRadius * 2, height: NodeMetrics.portRadius * 2)
                    .position(x: 0, y: NodeMetrics.height / 2)
                    .help("Input")
            }
            if node.kind.hasOutputPort {
                Circle().fill(VF.panel).overlay(Circle().strokeBorder(color, lineWidth: 2.5))
                    .overlay(Circle().fill(color).padding(4))
                    .frame(width: NodeMetrics.portRadius * 2 + 2, height: NodeMetrics.portRadius * 2 + 2)
                    .contentShape(Circle().inset(by: -6))
                    .position(x: NodeMetrics.width, y: NodeMetrics.height / 2)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("editor"))
                        .onChanged { v in onWireChanged(v.location) }
                        .onEnded { _ in onWireEnded() })
                    .help("Output — drag to another node's input (multiple connections = branches)")
            }

            // Order number in the main chain (order actually executed).
            if let orderIndex {
                Text(verbatim: "\(orderIndex)")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(orderChanged ? Color.white : VF.text)
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(orderChanged ? VF.accent : VF.panel3))
                    .overlay(Capsule().strokeBorder(orderChanged ? Color.white.opacity(0.9) : color.opacity(0.8), lineWidth: 1))
                    .scaleEffect(orderChanged ? 1.15 : 1)
                    .position(x: 6, y: -6)
                    .help("Position in the main chain (processing order)")
            }
        }
        .contextMenu { menu(status) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(node.title)
        .accessibilityValue(orderIndex.map { String(localized: "position \($0) in the chain") } ?? String(localized: "not in the main chain"))
    }

    func footerTitle(_ cat: PluginCategory?) -> String {
        let e = app.engine
        switch node.kind {
        case .input: return e.activeInput?.name ?? String(localized: "No microphone")
        case .output: return e.activeVirtual?.name ?? String(localized: "Virtual output missing")
        case .monitorOutput: return e.activeMonitor?.name ?? String(localized: "Headphones")
        case .audioUnit:
            let n = node.plugin?.name ?? node.title
            return n == node.title ? (cat?.displayName ?? String(localized: "Plugin")) : n
        default: return node.kind.displayName
        }
    }

    func subtitle(_ cat: PluginCategory?) -> String {
        switch node.kind {
        case .input: return String(localized: "Microphone")
        case .output: return String(localized: "Virtual microphone")
        case .monitorOutput: return String(localized: "Monitoring")
        case .gain: return String(localized: "VoxFlowAir native")
        case .analyzer: return String(localized: "VoxFlowAir native")
        case .audioUnit: return node.plugin?.manufacturerName ?? ""
        }
    }

    var detail: String {
        switch node.kind {
        case .gain: return formatDB(node.parameters["gain"] ?? 0)
        case .input:
            let ch = app.engine.settings.inputChannels
            return ch.count == 1 ? String(localized: "mono ch\(ch[0] + 1)") : String(localized: "stereo")
        case .output: return app.engine.settings.muteVirtual ? "MUTE" : formatDB(app.engine.settings.virtualGainDB)
        case .monitorOutput: return app.engine.settings.monitorEnabled ? formatDB(app.engine.settings.monitorGainDB) : String(localized: "off")
        case .analyzer: return "FFT · scope · LUFS"
        case .audioUnit:
            if let u = app.engine.pluginUnit(for: node.id) {
                let lat = u.auAudioUnit.latency
                return lat > 0 ? String(format: "%.1f ms", lat * 1000) : (u.auAudioUnit.isLoadedInProcess ? String(localized: "in app") : String(localized: "isolated"))
            }
            return ""
        }
    }

    @ViewBuilder
    func statusBadge(_ s: NodeRuntimeStatus, bypassed: Bool) -> some View {
        switch s {
        case .ok:
            StatusDot(color: bypassed ? VF.warn : VF.ok, size: 7).help(bypassed ? "Bypassed" : "Active")
        case .loading:
            ProgressView().controlSize(.mini)
        case .missing:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(VF.warn).help(s.label)
        case .failed, .crashed:
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(VF.danger).help(s.label)
        }
    }

    @ViewBuilder
    func menu(_ status: NodeRuntimeStatus) -> some View {
        let e = app.engine
        if node.kind == .audioUnit {
            Button("Open Interface") { app.openPluginUI(node.id) }.disabled(e.pluginUnit(for: node.id) == nil)
            if !status.isHealthy { Button("Reload Plugin") { e.reloadPlugin(node.id) } }
        }
        if !node.kind.isUnique && node.kind != .analyzer {
            Button(node.bypassed ? "Enable" : "Bypass") { e.setNodeBypass(node.id, !node.bypassed) }
        }
        if node.kind == .analyzer {
            Button("Analyze This Point") { app.analysisSource = .node(node.id); if app.bottomTab == .levels { app.bottomTab = .spectrum } }
        }
        if orderIndex != nil && !e.settings.lockEditing {
            Divider()
            Button("Move Up in Chain (⌥⌘↑)") { app.selectedNodes = [node.id]; app.moveSelection(by: -1) }
            Button("Move Down in Chain (⌥⌘↓)") { app.selectedNodes = [node.id]; app.moveSelection(by: 1) }
        }
        if !node.kind.isUnique {
            Button("Duplicate") { e.duplicateNode(node.id) }
        }
        if node.groupID != nil {
            Button("Remove from Section") { e.ungroupNode(node.id) }
        }
        if node.kind != .input && node.kind != .output {
            Divider()
            Button("Delete", role: .destructive) {
                app.selectedNodes = [node.id]
                app.deleteSelection()
            }
        }
    }
}

/// Meter of an input / output node: the only node view that tracks levels at 30 Hz.
struct NodeLevelMeter: View {
    @Environment(AppState.self) private var app
    let nodeID: UUID
    var body: some View { NodeVerticalMeter(level: app.meters.nodes[nodeID] ?? MeterHub.Level()) }
}

/// Compact vertical meter for input / output nodes.
struct NodeVerticalMeter: View {
    let level: MeterHub.Level
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach([level.peakL, level.peakR], id: \.self) { v in
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(VF.panel3)
                        MeterGradient.fillV.mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * meterFraction(v)) }
                    }.clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
    }
}

/// A node's mini visualization: waveform or spectrum of the real signal at its output.
struct NodeMiniView: View {
    @Environment(AppState.self) private var app
    let nodeID: UUID
    let color: Color
    let spectrum: Bool
    @State private var analyzer = SpectrumAnalyzer(size: 1024)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
            // Reading the date is required: otherwise SwiftUI doesn't redraw the Canvas on every tick.
            let now = timeline.date
            Canvas { ctx, size in
                _ = now
                // Subtle grid.
                for f in [0.25, 0.5, 0.75] {
                    ctx.stroke(Path { $0.move(to: .init(x: size.width * f, y: 0)); $0.addLine(to: .init(x: size.width * f, y: size.height)) },
                               with: .color(VF.grid.opacity(0.6)), lineWidth: 0.5)
                }
                guard let tap = app.engine.nodeTap(for: nodeID) else { return }
                if spectrum {
                    let db = analyzer.update(from: tap.left, smoothing: 0.7)
                    let sr = max(app.engine.latency.sampleRate, 44100)
                    var p = Path(); var started = false
                    for i in 1..<db.count {
                        let f = analyzer.frequency(bin: i, sampleRate: sr)
                        guard f >= 30, f <= 18000 else { continue }
                        let x = CGFloat(log10(f / 30) / log10(18000 / 30)) * size.width
                        let y = size.height * CGFloat(1 - (min(max(db[i], -90), -10) + 90) / 80)
                        if started { p.addLine(to: .init(x: x, y: y)) } else { p.move(to: .init(x: x, y: y)); started = true }
                    }
                    var fill = p
                    fill.addLine(to: .init(x: size.width, y: size.height)); fill.addLine(to: .init(x: 0, y: size.height))
                    ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.45), color.opacity(0.03)]), startPoint: .zero, endPoint: .init(x: 0, y: size.height)))
                    ctx.stroke(p, with: .color(color), lineWidth: 1.3)
                } else {
                    // Waveform envelope (peaks per column).
                    let n = 2048
                    var buf = [Float](repeating: 0, count: n)
                    buf.withUnsafeMutableBufferPointer { _ = tap.left.readLatest(into: $0.baseAddress!, count: n) }
                    let cols = max(Int(size.width / 2), 1)
                    let per = n / cols
                    let mid = size.height / 2
                    var p = Path()
                    for c in 0..<cols {
                        var pk: Float = 0
                        for k in 0..<per { pk = max(pk, abs(buf[c * per + k])) }
                        let h = CGFloat(min(pk * 1.6, 1)) * mid * 0.95
                        let x = CGFloat(c) * 2 + 1
                        p.move(to: .init(x: x, y: mid - h)); p.addLine(to: .init(x: x, y: mid + h))
                    }
                    ctx.stroke(p, with: .color(color.opacity(0.85)), lineWidth: 1.2)
                }
            }
        }
    }
}
