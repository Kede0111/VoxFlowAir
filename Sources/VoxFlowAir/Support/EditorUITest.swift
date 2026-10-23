import SwiftUI
import AppKit
import AVFoundation
import VoxFlowAirCore

/// End-to-end test of the node editor gestures, without audio, with real AppKit mouse events
/// sent to the window (same path as the mouse: `NSWindow.sendEvent` → SwiftUI):
///
///     VOXFLOWAIR_SUPPORT_DIR=/copy VOXFLOWAIR_UITEST_EDITOR=/folder/report VoxFlowAir.app/Contents/MacOS/VoxFlowAir
///
/// Works on the active preset of the given data folder (always a copy). Writes `report.txt`
/// and canvas captures into the folder, then quits (exit code 0 if everything passes).
@MainActor
enum EditorUITest {
    static var lines: [String] = []
    static var failures = 0

    static func log(_ s: String) { lines.append(s); print(s) }
    static func check(_ ok: Bool, _ label: String) {
        if !ok { failures += 1 }
        log((ok ? "✔ " : "✘ ") + label)
    }

    static func run(app: AppState, dir: String) {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        app.engine.launch(safeMode: false, startAudio: false)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let size = NSSize(width: 1400, height: 820)
        let host = NSHostingView(rootView: NodeEditor().environment(app).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        win.orderFrontRegardless()
        win.makeKey()
        Task { @MainActor in
            await scenario(app: app, win: win, host: host, out: out)
            log(failures == 0 ? "RESULT: all checks pass" : "RESULT: \(failures) check(s) failed")
            try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            CrashSentinel.markCleanExit()
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: Scenario

    static func scenario(app: AppState, win: NSWindow, host: NSView, out: URL) async {
        let e = app.engine
        // A single editor: the main window opened by the scene is closed.
        try? await Task.sleep(for: .seconds(1))
        for w in NSApp.windows where w !== win && w.isVisible { w.close() }
        // Plugins loaded (real instances, settings restored from the preset).
        for _ in 0..<40 where e.nodeStatus.values.contains(.loading) || e.graph.nodes.contains(where: { $0.kind == .audioUnit && e.pluginUnit(for: $0.id) == nil }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        app.editorCommand = .fit
        try? await Task.sleep(for: .seconds(1))
        log("Preset: \(e.activePreset?.name ?? "?")")
        let chain0 = e.graph.reorderableMainChain()
        log("Initial order: " + titles(e.graph, chain0).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " → "))
        guard chain0.count >= 7 else { check(false, "at least 7 effects in the chain"); return }
        snapshot(host, out, "1-before.png")

        // 1. Plain drag of node 7 onto the connection that enters node 1.
        let n7 = chain0[6], n1 = chain0[0]
        let full0 = e.graph.mainChain()
        let i7 = full0.firstIndex(of: n7)!
        let prev7 = full0[i7 - 1], next7 = full0[i7 + 1]
        let title7 = e.graph.node(n7)!.title
        let unit7 = e.pluginUnit(for: n7)
        let params7 = parameters(unit7)
        log("Node 7: \(title7) — \(params7.count) parameters captured")
        let target = e.graph.mainChainConnection(into: n1)!
        let geo = geometry(e)
        let grab = point(e, n7, dx: 92, dy: 40, geo: geo)   // node title (not the grip, ⏻ or a port)
        let drop = geo.midpoint(target, in: e.graph)!
        let routing0 = routing(e.graph)
        log("  view: zoom \(geo.zoom), offset \(geo.offset); Input on screen \(geo.origin(e.graph.inputNode!)); grab \(grab) → drop \(drop)")
        await drag(app, node: n7, from: grab, to: drop) {
            snapshot(host, out, "2-during-drag.png")
            // Before release: nothing is modified yet.
            check(routing(e.graph) == routing0, "during the drag, routing has not changed yet")
        }
        try? await Task.sleep(for: .milliseconds(600))
        let chain1 = e.graph.reorderableMainChain()
        log("Order after drop: " + titles(e.graph, chain1).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " → "))
        check(chain1.first == n7, "\"\(title7)\" (node 7) is now node 1")
        check(Array(chain1.dropFirst()) == chain0.filter { $0 != n7 }, "the other nodes keep their relative order")
        check(e.graph.connections.contains { $0.from == e.graph.inputNode!.id && $0.to == n7 }
              && e.graph.connections.contains { $0.from == n7 && $0.to == n1 }, "connections recomputed: Input → \(title7) → former node 1")
        check(e.graph.connections.contains { $0.from == prev7 && $0.to == next7 }, "node 7's former neighbors are connected to each other")
        check(e.graph.connections.count == routing0.count, "no connection lost or added")
        check(e.pluginUnit(for: n7) === unit7 && unit7 != nil, "same plugin instance (no reload)")
        check(parameters(e.pluginUnit(for: n7)) == params7, "plugin parameters unchanged")
        check(e.nodeStatus[n7] == .ok, "plugin active after the move")
        snapshot(host, out, "3-after-drop.png")

        // 2. Move onto an empty area: position only.
        let routing1 = routing(e.graph)
        let mover = chain1[3]
        let p0 = e.graph.node(mover)!.position
        let geo2 = geometry(e)
        let empty = emptyPoint(e, geo: geo2)
        await drag(app, node: mover, from: point(e, mover, dx: 92, dy: 40, geo: geo2), to: empty)
        try? await Task.sleep(for: .milliseconds(400))
        check(e.graph.node(mover)!.position != p0, "empty area: the node moved on screen")
        check(routing(e.graph) == routing1 && e.graph.reorderableMainChain() == chain1, "empty area: audio order and connections unchanged")
        snapshot(host, out, "4-free-move.png")

        // 3. Grip ≡ released away from a connection: nothing changes.
        let gripNode = chain1[2]
        let g0 = e.graph.node(gripNode)!.position
        let geo3 = geometry(e)
        await drag(app, node: gripNode, from: point(e, gripNode, dx: 15, dy: 20, geo: geo3), to: emptyPoint(e, geo: geo3), grip: true)
        try? await Task.sleep(for: .milliseconds(400))
        check(routing(e.graph) == routing1 && e.graph.node(gripNode)!.position == g0, "grip released off target: nothing changes")

        // 4. Click with slight drag on the ⏻ button: bypass, never a move.
        let bp = chain1[1]
        let b0 = e.graph.node(bp)!
        let geo4 = geometry(e)
        let button = point(e, bp, dx: NodeMetrics.width - 20, dy: 19, geo: geo4)
        // Drag that starts on ⏻: never a move.
        await drag(app, node: bp, from: button, to: CGPoint(x: button.x + 40, y: button.y + 30))
        try? await Task.sleep(for: .milliseconds(300))
        check(e.graph.node(bp)!.position == b0.position && routing(e.graph) == routing1, "drag started on ⏻: no move and no order change")
        log("  (⏻ \"\(b0.title)\": position \(b0.position) → \(e.graph.node(bp)!.position), point \(button))")
        // Real mouse click (with 2 pt of drag) on ⏻: bypasses the node, doesn't move it.
        let v = e.graph.viewport // displayed view, saved by the editor on the last drag
        let onScreen = CGPoint(x: button.x * v.zoom + v.offsetX, y: button.y * v.zoom + v.offsetY)
        await click(win, at: onScreen, jitter: 2)
        try? await Task.sleep(for: .milliseconds(400))
        let b1 = e.graph.node(bp)!
        check(b1.bypassed != b0.bypassed, "click on ⏻: the node is bypassed")
        check(b1.position == b0.position && routing(e.graph) == routing1, "click on ⏻: no move and no order change")
        if b1.bypassed != b0.bypassed { e.setNodeBypass(bp, b0.bypassed) }

        // 5. ⌘Z undoes the reorder.
        while e.reorderableMainChainChanged(from: chain0) && e.canUndo { e.undo() }
        check(e.graph.reorderableMainChain() == chain0, "⌘Z restores the original order")
    }

    // MARK: Helpers

    static func titles(_ g: ProcessingGraph, _ ids: [UUID]) -> [String] { ids.map { g.node($0)?.title ?? "?" } }
    static func routing(_ g: ProcessingGraph) -> Set<[UUID]> { Set(g.connections.map { [$0.from, $0.to] }) }

    static func parameters(_ u: AVAudioUnit?) -> [String] {
        (u?.auAudioUnit.parameterTree?.allParameters ?? []).map { "\($0.identifier)=\($0.value)" }
    }

    /// Graph coordinates (zoom 1, no offset): the editor converts them with its own view.
    static func geometry(_ e: VoxFlowAirEngine) -> EditorGeometry { EditorGeometry(offset: .zero, zoom: 1) }

    /// Point on node `id` (offset in node coordinates, before zoom), in the editor's coordinate space.
    static func point(_ e: VoxFlowAirEngine, _ id: UUID, dx: CGFloat, dy: CGFloat, geo: EditorGeometry) -> CGPoint {
        let o = geo.origin(e.graph.node(id)!)
        return CGPoint(x: o.x + dx * geo.zoom, y: o.y + dy * geo.zoom)
    }

    /// Canvas point far from every node and connection.
    static func emptyPoint(_ e: VoxFlowAirEngine, geo: EditorGeometry) -> CGPoint {
        let nodes = e.graph.nodes.map(\.position)
        let minX = nodes.map(\.x).min() ?? 0, maxX = (nodes.map(\.x).max() ?? 0) + NodeMetrics.width
        let maxY = (nodes.map(\.y).max() ?? 0) + NodeMetrics.height
        // Below the graph, within its width (empty area visible on screen after “zoom to fit”).
        for y in stride(from: maxY + 40, to: maxY + 400, by: 20) {
            for x in stride(from: minX, to: maxX, by: 40) {
                let p = CGPoint(x: x, y: y)
                let farFromNodes = e.graph.nodes.allSatisfy { !geo.rect($0).insetBy(dx: -40, dy: -40).contains(p) }
                if farFromNodes && geo.nearestConnection(to: p, in: e.graph, maxDistance: 100) == nil { return p }
            }
        }
        return CGPoint(x: minX, y: maxY + 300)
    }

    /// Drag replayed by the editor with its own gesture functions (editor coordinate space).
    /// Synthetic mouse events don't trigger `DragGesture` (physical button released), hence
    /// this path: only SwiftUI's mouse → gesture routing is not covered.
    static func drag(_ app: AppState, node: UUID, from a: CGPoint, to b: CGPoint, grip: Bool = false,
                     beforeRelease: (() -> Void)? = nil) async {
        final class Flag { var done = false }
        let flag = Flag()
        app.debugDrag = EditorDebugDrag(node: node, from: a, to: b, grip: grip, beforeRelease: beforeRelease, finished: { flag.done = true })
        for _ in 0..<300 where !flag.done { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Real mouse click (AppKit events sent to the window), with a slight drag.
    static func click(_ win: NSWindow, at p: CGPoint, jitter: CGFloat) async {
        let h = win.contentView!.bounds.height
        for (type, q) in [(NSEvent.EventType.leftMouseDown, p), (.leftMouseDragged, CGPoint(x: p.x + jitter, y: p.y)), (.leftMouseUp, CGPoint(x: p.x + jitter, y: p.y))] {
            let ev = NSEvent.mouseEvent(with: type, location: NSPoint(x: q.x, y: h - q.y), modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            win.sendEvent(ev)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    static func snapshot(_ view: NSView, _ out: URL, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
    }
}

private extension VoxFlowAirEngine {
    func reorderableMainChainChanged(from chain: [UUID]) -> Bool { graph.reorderableMainChain() != chain }
}
