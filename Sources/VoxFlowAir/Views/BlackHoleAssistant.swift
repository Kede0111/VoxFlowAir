import SwiftUI
import AppKit
import VoxFlowAirCore

/// Setup assistant for the virtual output (BlackHole, Existential Audio, GPL-3.0).
/// VoxFlowAir installs nothing silently: installation goes through Terminal and
/// your administrator password, using an official, signed and verified package.
struct BlackHoleAssistant: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var copied = false

    var body: some View {
        let e = app.engine
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 24)).foregroundStyle(VF.accent)
                VStack(alignment: .leading) {
                    Text("Virtual Output").font(.title3.bold())
                    Text("Lets you choose VoxFlowAir as the microphone in OBS, FaceTime, Skype…").font(.caption).foregroundStyle(.secondary)
                }
            }
            GroupBox {
                HStack(spacing: 10) {
                    switch e.virtualStatus {
                    case .available(let name, let v):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(VF.ok)
                        VStack(alignment: .leading) {
                            if let v {
                                Text("“\(name)” is available (driver \(v)).")
                            } else {
                                Text("“\(name)” is available.")
                            }
                            Text("In your apps, choose “\(name)” as the microphone.").font(.caption).foregroundStyle(.secondary)
                        }
                    case .installedNotLoaded(let v):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VF.warn)
                        Text("BlackHole \(v) is installed but not yet loaded by macOS. Restart the Mac (or run “sudo killall coreaudiod” in Terminal).")
                    case .notInstalled:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(VF.danger)
                        Text("No virtual output is installed.")
                    }
                    Spacer()
                    Button("Check") { e.deviceManager.refresh(); e.refreshVirtualStatus(); e.restart(reason: String(localized: "virtual output check"), userRequested: true) }
                }.padding(4)
            }

            if case .available = e.virtualStatus {} else {
                Text("Recommended installation: BlackHole 2ch").font(.headline)
                Text("""
                1. Click “Install in Terminal”. The script checks for Homebrew, downloads the official signed package from Existential Audio (checksum verified by Homebrew) and installs it.
                2. Enter your administrator password when Terminal asks for it (VoxFlowAir never sees it).
                3. Come back here and click “Check”. If the device does not appear, restart the Mac.
                """).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { runInstaller() } label: { Label("Install in Terminal", systemImage: "terminal") }
                        .buttonStyle(.borderedProminent)
                    Button(copied ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(VirtualDeviceSupport.brewCommand, forType: .string)
                        copied = true
                    }
                    Button("Official Page") { NSWorkspace.shared.open(VirtualDeviceSupport.officialURL) }
                }
                Text("Without Homebrew: download “BlackHole 2ch” from the official page and open the .pkg. Both methods install the same signed and notarized driver in /Library/Audio/Plug-Ins/HAL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("License and uninstallation").font(.subheadline.bold())
            Text("BlackHole is free software (GPL-3.0), independent of VoxFlowAir, which only uses it as an audio device. Other apps may depend on it too: uninstalling VoxFlowAir does not remove it. To remove it: “\(VirtualDeviceSupport.brewUninstallCommand)”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !embedded {
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            Spacer(minLength: 0)
        }
        .padding(embedded ? 4 : 20)
    }

    func runInstaller() {
        // Script bundled with the app; Terminal runs it at the user's request.
        guard let url = Bundle.main.url(forResource: "install-blackhole", withExtension: "command") else {
            app.engine.post(.error, String(localized: "Installation script not found in the app. Manual command: \(VirtualDeviceSupport.brewCommand)"))
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("VoxFlowAir-install-blackhole.command")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: url, to: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        NSWorkspace.shared.open([tmp], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
    }
}
