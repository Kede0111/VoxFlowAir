import SwiftUI
import AppKit
import VoxFlowAirCore

@main
struct VoxFlowAirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppDelegate.sharedState

    var body: some Scene {
        Window("VoxFlowAir", id: "main") {
            MainWindow()
                .environment(app)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .defaultSize(width: 1480, height: 900)
        .windowToolbarStyle(.unified)
        .commands { VoxFlowAirCommands(app: app) }

        Window("Meter Monitors", id: MeterMonitorPanel.windowID) {
            MeterMonitorPanel()
                .environment(app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(app)
                .frame(width: 620, height: 520)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(app)
        } label: {
            MenuBarIcon(app: app)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    let app: AppState
    var body: some View {
        // Logo only (the “waveform” symbol from the app icon), slashed when the engine
        // is stopped or the virtual output is muted. The active preset is still shown
        // in the panel.
        let e = app.engine
        let active = e.state.isRunning && !e.settings.muteVirtual
        Image(systemName: active ? "waveform" : "waveform.slash")
            .accessibilityLabel(Text(verbatim: "VoxFlowAir"))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let sharedState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = Self.sharedState
        if let path = ProcessInfo.processInfo.environment["VOXFLOWAIR_SNAPSHOT"] {
            SnapshotRenderer.run(app: app, path: path)
            return
        }
        if let dir = ProcessInfo.processInfo.environment["VOXFLOWAIR_UITEST_EDITOR"] {
            EditorUITest.run(app: app, dir: dir)
            return
        }
        let safe = NSEvent.modifierFlags.contains(.option)
        app.engine.launch(safeMode: safe)
        if safe { app.engine.post(.warning, String(localized: "Safe mode (Option key): plugins are not loaded.")) }
        if app.engine.previousSessionCrashed {
            app.engine.post(.warning, String(localized: "The last VoxFlowAir session did not end normally. If a plugin is to blame, relaunch VoxFlowAir while holding Option (safe mode) or switch that plugin to “Isolated Process”."))
        }
        app.meters.start()
        app.meterMonitors.restore()
        app.applyAppearance()
        app.localControl.start()
        if !app.engine.settings.showWindowAtLaunch {
            DispatchQueue.main.async {
                for w in NSApp.windows where w.identifier?.rawValue.contains("main") == true { w.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow, w.identifier?.rawValue.contains("main") == true else { return }
            // Main window closed: VoxFlowAir stays active in the menu bar.
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Self.sharedState.pluginWindows.closeAll()
        Self.sharedState.meterMonitors.saveAll()
        Self.sharedState.engine.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

struct VoxFlowAirCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { app.engine.undo() }.keyboardShortcut("z").disabled(!app.engine.canUndo)
            Button("Redo") { app.engine.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!app.engine.canRedo)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Preset") { app.engine.saveActivePreset() }.keyboardShortcut("s")
            Button("Revert to Saved Preset") { app.engine.revertPreset() }.disabled(!app.engine.isDirty)
        }
        CommandMenu("Audio") {
            Button(app.engine.settings.monitorEnabled ? "Turn Monitoring Off" : "Turn Monitoring On") {
                app.engine.settings.monitorEnabled.toggle()
            }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button(app.engine.settings.muteVirtual ? "Unmute Virtual Output" : "Mute Virtual Output") {
                app.engine.settings.muteVirtual.toggle()
            }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button(app.engine.bypassProcessing ? "Resume Processing" : "Bypass Processing") {
                app.engine.bypassProcessing.toggle()
            }.keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Restart Audio Engine") { app.engine.restart(reason: String(localized: "user request"), userRequested: true) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button(app.engine.settings.engineEnabled ? "Stop Engine" : "Start Engine") {
                app.engine.setEngineEnabled(!app.engine.settings.engineEnabled)
            }
        }
        CommandMenu("Graph") {
            Button("Zoom In") { app.editorCommand = .zoomIn }.keyboardShortcut("+")
            Button("Zoom Out") { app.editorCommand = .zoomOut }.keyboardShortcut("-")
            Button("Zoom to Fit") { app.editorCommand = .fit }.keyboardShortcut("0")
            Divider()
            Button("Duplicate Node") { if let id = app.primarySelection { app.engine.duplicateNode(id) } }
                .keyboardShortcut("d").disabled(app.primarySelection == nil)
            Button("Group Selection") { app.engine.createGroup(name: "Section", nodes: app.selectedNodes) }
                .keyboardShortcut("g").disabled(app.selectedNodes.count < 1)
            Button("Move Up in Chain") { app.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(!app.canMoveSelection)
            Button("Move Down in Chain") { app.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(!app.canMoveSelection)
            Divider()
            Button(app.engine.settings.lockEditing ? "Unlock Editing" : "Lock Editing") {
                app.engine.settings.lockEditing.toggle()
            }.keyboardShortcut("l", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button(app.showInspector ? "Hide Inspector" : "Show Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(after: .windowArrangement) {
            Button("VoxFlowAir Main Window") { openWindow(id: "main"); NSApp.activate() }.keyboardShortcut("1")
            MeterPanelToggle(app: app, asMenuItem: true).keyboardShortcut("2")
        }
    }
}
