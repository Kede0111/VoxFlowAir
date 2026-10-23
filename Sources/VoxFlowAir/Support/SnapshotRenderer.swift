import SwiftUI
import AppKit
import VoxFlowAirCore

/// Captures the interface without starting audio (visual check during development):
/// VOXFLOWAIR_SNAPSHOT=/path/capture.png VoxFlowAir.app/Contents/MacOS/VoxFlowAir
@MainActor
enum SnapshotRenderer {
    static let isActive = ProcessInfo.processInfo.environment["VOXFLOWAIR_SNAPSHOT"] != nil

    static func run(app: AppState, path: String) {
        app.engine.launch(safeMode: false, startAudio: false)
        app.meters.start()
        let appearance = ProcessInfo.processInfo.environment["VOXFLOWAIR_SNAPSHOT_LIGHT"] == "1" ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
        NSApp.appearance = appearance
        let size = NSSize(width: 1480, height: 900)
        // Real titled window: the SwiftUI toolbar becomes a native NSToolbar.
        let host = NSHostingView(rootView: MainWindow().environment(app).frame(width: size.width, height: size.height))
        host.sceneBridgingOptions = [.toolbars, .title]
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.appearance = appearance
        win.toolbarStyle = .unified
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        win.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["VOXFLOWAIR_SNAPSHOT_DEMO"] == "1" {
            // Demo chain with actually installed plugins.
            let names = ["AUHipass", "AUNBandEQ", "AUDynamicsProcessor", "AUPeakLimiter"]
            for n in names { if let p = app.engine.plugins.first(where: { $0.name == n }) { _ = app.engine.addNode(kind: .audioUnit, plugin: p.reference, appendToChain: true) } }
            app.engine.arrangeGraph(rowWidth: 1000)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let sel = app.engine.graph.nodes.first(where: { $0.kind == .audioUnit }) ?? app.engine.graph.nodes.first(where: { $0.kind == .gain }) { app.selectedNodes = [sel.id] }
            // VOXFLOWAIR_SNAPSHOT_REORDER=1: freezes a “move in chain” (last effect onto the first
            // connection) to check the insertion marker and preview without a mouse.
            if ProcessInfo.processInfo.environment["VOXFLOWAIR_SNAPSHOT_REORDER"] == "1" {
                let chain = app.engine.graph.reorderableMainChain()
                if let last = chain.last, let first = chain.first, let c = app.engine.graph.mainChainConnection(into: first) {
                    app.debugReorder = (last, c.id)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // Captures the whole window (frame + toolbar), not just the content.
            let frameView = win.contentView?.superview ?? host
            frameView.layoutSubtreeIfNeeded()
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(2) }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            // Captures the menu bar panel.
            let menuHost = NSHostingView(rootView: MenuBarPanel().environment(app).background(VF.panel))
            menuHost.frame = NSRect(x: 0, y: 0, width: 340, height: 520)
            let w2 = NSWindow(contentRect: menuHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w2.appearance = appearance
            w2.contentView = menuHost
            w2.setFrameOrigin(NSPoint(x: -3000, y: -3000))
            w2.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let fit = menuHost.fittingSize
                menuHost.setFrameSize(fit)
                if let rep2 = menuHost.bitmapImageRepForCachingDisplay(in: menuHost.bounds) {
                    menuHost.cacheDisplay(in: menuHost.bounds, to: rep2)
                    if let d2 = rep2.representation(using: .png, properties: [:]) {
                        try? d2.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-menubar.png")))
                    }
                }
                CrashSentinel.markCleanExit()
                exit(0)
            }
        }
    }
}
