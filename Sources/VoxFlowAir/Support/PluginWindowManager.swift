import SwiftUI
import AppKit
import AVFoundation
import VoxFlowAirCore

/// Windows for the plugins' native interfaces.
@MainActor
final class PluginWindowManager {
    private var windows: [UUID: NSWindow] = [:]
    private var delegates: [UUID: WindowCloseDelegate] = [:]

    func open(nodeID: UUID, title: String, unit: AVAudioUnit) {
        if let w = windows[nodeID] { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        Task { @MainActor in
            let native = await PluginHost.loadView(for: unit)
            let content: NSView
            var generic = false
            if let native {
                content = native
            } else {
                // Fallback: generic interface built from the exposed parameters.
                generic = true
                let host = NSHostingView(rootView: GenericParameterView(unit: unit.auAudioUnit))
                host.setFrameSize(NSSize(width: 460, height: 520))
                content = host
            }
            let size = content.frame.size == .zero ? NSSize(width: 600, height: 400) : content.frame.size
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: generic ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = generic ? String(localized: "\(title) — Generic Parameters") : title
            w.contentView = content
            w.isReleasedWhenClosed = false
            w.level = .floating
            // Position remembered per plugin (top-left corner only: the size stays the
            // plugin interface's own, never altered).
            let key = "VoxFlowAirPluginWindow.\(unit.auAudioUnit.componentName ?? title)"
            if let saved = UserDefaults.standard.string(forKey: key), NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPointFromString(saved)) }) {
                w.setFrameTopLeftPoint(NSPointFromString(saved))
            } else {
                w.center()
            }
            let d = WindowCloseDelegate(onMove: { [weak w] in
                if let w { UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: w.frame.minX, y: w.frame.maxY)), forKey: key) }
            }) { [weak self] in self?.windows[nodeID] = nil; self?.delegates[nodeID] = nil }
            w.delegate = d
            delegates[nodeID] = d
            windows[nodeID] = w
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func close(nodeID: UUID) {
        windows[nodeID]?.close()
        windows[nodeID] = nil
        delegates[nodeID] = nil
    }

    func closeAll() { for id in Array(windows.keys) { close(nodeID: id) } }
    func isOpen(_ id: UUID) -> Bool { windows[id] != nil }
}

final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onMove: () -> Void
    let onClose: () -> Void
    init(onMove: @escaping () -> Void = {}, onClose: @escaping () -> Void) { self.onMove = onMove; self.onClose = onClose }
    func windowDidMove(_ notification: Notification) { onMove() }
    func windowWillClose(_ notification: Notification) { onMove(); onClose() }
}

/// Fallback interface: one slider per parameter published by the plugin.
struct GenericParameterView: View {
    let unit: AUAudioUnit
    @State private var values: [AUParameterAddress: AUValue] = [:]
    @State private var filter = ""

    var params: [AUParameter] {
        let all = unit.parameterTree?.allParameters ?? []
        return filter.isEmpty ? all : all.filter { $0.displayName.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("This plugin has no usable graphical interface; showing its exposed parameters.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
            TextField("Search parameters", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
            if params.isEmpty {
                ContentUnavailableView("No Parameters", systemImage: "questionmark.circle",
                                       description: Text("The plugin exposes no automatable parameters."))
            } else {
                List(params, id: \.address) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.displayName).font(.system(size: 12))
                            Spacer()
                            Text(p.currentValueString).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { Double(values[p.address] ?? p.value) },
                                              set: { p.setValue(AUValue($0), originator: nil); values[p.address] = AUValue($0) }),
                               in: Double(p.minValue)...Double(max(p.maxValue, p.minValue + 0.0001)))
                            .disabled(!p.flags.contains(.flag_IsWritable))
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}
