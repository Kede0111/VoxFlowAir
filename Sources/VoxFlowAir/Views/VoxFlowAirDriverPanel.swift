import SwiftUI
import AppKit
import VoxFlowAirCore

/// VoxFlowAir's own virtual microphone (VoxFlowAirDriver, an AudioServerPlugIn).
/// Installation goes through Terminal and the administrator password: nothing happens silently.
struct VoxFlowAirDriverPanel: View {
    @Environment(AppState.self) private var app
    @State private var state: [String: Any]?

    var body: some View {
        let e = app.engine
        VStack(alignment: .leading, spacing: 10) {
            Text("VoxFlowAir Virtual Microphone").font(.headline)
            GroupBox {
                HStack(spacing: 10) {
                    switch e.voxflowairAirDriverStatus {
                    case .available(let v):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(VF.ok)
                        VStack(alignment: .leading, spacing: 2) {
                            if let v {
                                Text("“\(VoxFlowAirDriverSupport.micName)” is available (driver \(v)).")
                            } else {
                                Text("“\(VoxFlowAirDriverSupport.micName)” is available.")
                            }
                            Text(e.activeVirtual.map { VoxFlowAirDriverSupport.isFeed(uid: $0.uid) } == true
                                 ? "VoxFlowAir is feeding it. In OBS, FaceTime… choose the “\(VoxFlowAirDriverSupport.micName)” microphone."
                                 : "To use it, choose “\(VoxFlowAirDriverSupport.micName) (VoxFlowAir driver)” as the virtual output in Settings › Audio.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let s = state {
                                Text("Driver: \(num(s["micClients"])) reader(s), \(num(s["feedClients"])) writer(s), \(num(s["sampleRate"])) Hz, \(num(s["gaps"])) gap(s) filled")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    case .installedNotLoaded(let v):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VF.warn)
                        Text("VoxFlowAir driver \(v) is installed but not yet loaded by macOS. Restart the Mac or run the installation again.")
                    case .notInstalled:
                        Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                        Text("Not installed. Optional: BlackHole is still supported.")
                    }
                    Spacer()
                    Button("Check") {
                        e.deviceManager.refresh(); e.refreshVirtualStatus()
                        state = VoxFlowAirDriverSupport.driverState()
                    }
                }.padding(4)
            }
            HStack {
                if VoxFlowAirDriverSupport.embeddedURL != nil {
                    Button { runScript("install-voxflowair-driver", withDriver: true) } label: {
                        Label(e.voxflowairAirDriverStatus == .notInstalled ? "Install in Terminal" : "Reinstall", systemImage: "terminal")
                    }
                } else {
                    Text("This build of VoxFlowAir does not include the driver (build the VoxFlowAirDriver target).").font(.caption).foregroundStyle(.secondary)
                }
                if e.voxflowairAirDriverStatus != .notInstalled {
                    Button("Uninstall…") { runScript("uninstall-voxflowair-driver", withDriver: false) }
                }
            }
            Text("The driver is copied to /Library/Audio/Plug-Ins/HAL (macOS asks for an administrator password), then the audio service restarts: the Mac’s sound cuts out for a few seconds. No macOS protection is changed. Local signature only (not notarized): for use on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { state = VoxFlowAirDriverSupport.driverState() }
    }

    private func num(_ v: Any?) -> String { (v as? NSNumber).map { "\($0.intValue)" } ?? "?" }

    /// Runs a script bundled with the app in Terminal, at the user's request.
    private func runScript(_ name: String, withDriver: Bool) {
        guard let script = Bundle.main.url(forResource: name, withExtension: "command") else {
            app.engine.post(.error, String(localized: "Script \(name) not found in the app.")); return
        }
        var line = "\"\(script.path)\""
        if withDriver, let d = VoxFlowAirDriverSupport.embeddedURL { line += " \"\(d.path)\"" }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("VoxFlowAir-\(name).command")
        try? "#!/bin/bash\n\(line)\necho; read -r -p \"Press Return to close.\" _\n".write(to: tmp, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        NSWorkspace.shared.open([tmp], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
