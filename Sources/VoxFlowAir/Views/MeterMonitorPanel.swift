import SwiftUI
import AppKit
import VoxFlowAirCore

/// Standalone panel: one meter plugin on the input, another on the output.
/// Closing it disconnects nothing: the plugins keep measuring in the background.
struct MeterMonitorPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MonitorColumn(point: .input)
            Divider().overlay(VF.border)
            MonitorColumn(point: .output)
        }
        .fixedSize()
        .background(VF.bg)
        .foregroundStyle(VF.text)
        .onAppear { app.meterMonitors.panelVisible = true; app.meterPanelShown = true }
        .onDisappear { app.meterMonitors.panelVisible = false; app.meterPanelShown = false }
    }
}

private struct MonitorColumn: View {
    @Environment(AppState.self) private var app
    let point: MonitorPoint

    var body: some View {
        let m = app.meterMonitors
        let slot = m.slots[point]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(point.displayName.uppercased()).font(VF.title).tracking(0.6)
                Picker("Meter", selection: Binding(
                    get: { m.selectedID(point) ?? "" },
                    set: { id in m.select(m.available.first { $0.id == id }?.reference, at: point) })) {
                    Text("None").tag("")
                    Divider()
                    ForEach(m.available) { p in Text(p.name).tag(p.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Meter plugin connected to this measurement point")
                Spacer(minLength: 12)
                if slot != nil { SignalBadge(db: m.receivedDB[point]) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.signalDescription)
                if let summary = slot.flatMap({ MeterPlugins.summary(for: $0.plugin) }) { Text(summary).foregroundStyle(VF.text3) }
            }
            .font(VF.small).foregroundStyle(VF.text2).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider().overlay(VF.border)
            Group {
                if m.loading.contains(point) {
                    placeholder { ProgressView().controlSize(.small); Text("Loading plugin…").font(VF.small).foregroundStyle(VF.text2) }
                } else if let err = m.errors[point] {
                    placeholder {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(VF.warn)
                        Text(err).font(VF.small).foregroundStyle(VF.text2).multilineTextAlignment(.center)
                    }
                } else if let slot {
                    NativeMonitorView(point: point, unitID: ObjectIdentifier(slot.unit))
                } else if m.available.isEmpty {
                    placeholder {
                        Image(systemName: "gauge.with.dots.needle.0percent").font(.title2).foregroundStyle(VF.text3)
                        Text("No meter plugin is installed.").font(VF.small).foregroundStyle(VF.text2)
                    }
                } else {
                    placeholder {
                        Image(systemName: "gauge.with.dots.needle.33percent").font(.title2).foregroundStyle(VF.text3)
                        Text("Choose a meter from the menu.").font(VF.small).foregroundStyle(VF.text2)
                    }
                }
            }
            .background(VF.panel)
        }
        // Width set by the plugin interface: the texts adapt to it instead of widening the panel.
        .frame(width: max(340, m.contentWidth(point)), alignment: .leading)
    }

    private func placeholder<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 8) { c() }.padding(20).frame(width: 340, height: 220)
    }
}

/// Peak read at the plugin output: shows the plugin actually receives the signal of the measured point.
private struct SignalBadge: View {
    let db: Float?
    var body: some View {
        let live = (db ?? -120) > -90
        HStack(spacing: 5) {
            Circle().fill(live ? VF.ok : VF.text3).frame(width: 7, height: 7)
            Text(live ? String(format: "%.0f dBFS", db ?? -120) : String(localized: "no signal"))
                .font(VF.mono).foregroundStyle(live ? VF.text : VF.text3)
                .frame(minWidth: 70, alignment: .leading)
        }
        .help("Peak of the signal the plugin actually receives (read at its output)")
    }
}

/// Native plugin interface, reused from one opening of the panel to the next.
private struct NativeMonitorView: View {
    @Environment(AppState.self) private var app
    let point: MonitorPoint
    let unitID: ObjectIdentifier
    @State private var view: NSView?
    @State private var size = CGSize(width: 340, height: 220)

    var body: some View {
        Group {
            if let view {
                HostedNSView(view: view, size: $size).frame(width: size.width, height: size.height)
                    .onChange(of: size, initial: true) { _, new in app.meterMonitors.noteViewSize(new, at: point) }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening interface…").font(VF.small).foregroundStyle(VF.text2)
                }
                .frame(width: 340, height: 220)
            }
        }
        .task(id: unitID) {
            view = nil
            if let v = await app.meterMonitors.nativeView(point) {
                size = v.frame.size == .zero ? CGSize(width: 600, height: 400) : v.frame.size
                view = v
            }
        }
    }
}

/// Hosts an existing AppKit view in SwiftUI and follows its size changes
/// (some plugins, such as Waves, offer several interface sizes).
private struct HostedNSView: NSViewRepresentable {
    let view: NSView
    @Binding var size: CGSize

    final class Container: NSView {
        var observer: NSObjectProtocol?
        override var isFlipped: Bool { true }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        attach(view, to: c)
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        if view.superview !== c { attach(view, to: c) }
    }

    static func dismantleNSView(_ c: Container, coordinator: ()) {
        if let o = c.observer { NotificationCenter.default.removeObserver(o); c.observer = nil }
        // The view is kept by the monitor manager for the next opening.
        for v in c.subviews { v.removeFromSuperview() }
    }

    private func attach(_ v: NSView, to c: Container) {
        v.removeFromSuperview()
        v.setFrameOrigin(.zero)
        c.addSubview(v)
        v.postsFrameChangedNotifications = true
        if let o = c.observer { NotificationCenter.default.removeObserver(o) }
        let binding = $size
        c.observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: .main) { [weak v] _ in
            MainActor.assumeIsolated {
                guard let v, v.frame.size != .zero, v.frame.size != binding.wrappedValue else { return }
                binding.wrappedValue = v.frame.size
                v.setFrameOrigin(.zero)
            }
        }
    }
}

extension MeterMonitorPanel {
    static let windowID = "meter-monitors"
}

/// Shows or hides the Meter Monitors panel (toolbar and Window menu).
struct MeterPanelToggle: View {
    let app: AppState
    var asMenuItem = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button {
            if app.meterPanelShown { dismissWindow(id: MeterMonitorPanel.windowID) }
            else { openWindow(id: MeterMonitorPanel.windowID) }
        } label: {
            if asMenuItem {
                Text(app.meterPanelShown ? "Hide Meter Monitors" : "Show Meter Monitors")
            } else {
                Label("Meter Monitors", systemImage: app.meterPanelShown ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent")
            }
        }
        .onAppear { app.openWindowAction = openWindow; app.dismissWindowAction = dismissWindow }
        .help(app.meterPanelShown ? "Hide meter monitors (⌘2). They keep measuring." : "Show input and output meter monitors (⌘2)")
    }
}
