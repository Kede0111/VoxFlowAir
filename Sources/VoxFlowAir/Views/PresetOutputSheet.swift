import SwiftUI
import AppKit
import VoxFlowAirCore

/// Creates a preset (new or “save as”) with its virtual output
/// (BlackHole or “VoxFlowAir Micro”) and the displayed name of the VoxFlowAir microphone.
struct PresetOutputSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let saveAs: Bool
    @Binding var name: String
    /// "" = current setting; otherwise the UID of the virtual output.
    @State private var target = ""
    @State private var micName = ""

    var body: some View {
        let e = app.engine
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder).onSubmit(commit)
            Picker("Virtual output", selection: $target) {
                Text("Current setting (\(e.activeVirtual.map(displayName) ?? String(localized: "automatic")))").tag("")
                if e.voxflowairAirDriverStatus.isAvailable {
                    Text("\(VoxFlowAirDriverSupport.micName) (VoxFlowAir driver)").tag(VoxFlowAirDriverSupport.feedUID)
                }
                ForEach(e.deviceManager.virtualDevices) { d in Text(d.name).tag(d.uid) }
            }
            if usesVoxFlowAirDriver {
                TextField("Microphone name in OBS, FaceTime…", text: $micName, prompt: Text(VoxFlowAirDriverSupport.micName))
                    .textFieldStyle(.roundedBorder)
                Text("Applied each time the preset loads. Apps find the microphone by its identifier: renaming it does not change their setting.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The name “BlackHole 2ch” is set by the BlackHole driver: VoxFlowAir cannot change it. For a custom name, choose “\(VoxFlowAirDriverSupport.micName)”.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { micName = e.settings.virtualDeviceName ?? "" }
    }

    private var usesVoxFlowAirDriver: Bool {
        let uid = target.isEmpty ? (app.engine.activeVirtual?.uid ?? app.engine.settings.virtualUID ?? "") : target
        return VoxFlowAirDriverSupport.isFeed(uid: uid)
    }

    private func displayName(_ d: AudioDevice) -> String {
        VoxFlowAirDriverSupport.isFeed(uid: d.uid) ? (VoxFlowAirDriverSupport.currentMicName() ?? VoxFlowAirDriverSupport.micName) : d.name
    }

    private func confirmReplace(_ p: Preset) -> Bool {
        let a = NSAlert()
        a.messageText = String(localized: "“\(p.name)” already exists. Replace it?")
        a.informativeText = app.engine.factoryVersion(of: p.id) != nil
            ? String(localized: "The current chain will replace this preset. Its original version can still be restored (preset menu › Restore Original Version).")
            : String(localized: "The current chain will replace this preset. The old version stays in the backup file (.bak).")
        a.addButton(withTitle: String(localized: "Replace"))
        a.addButton(withTitle: String(localized: "Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let e = app.engine
        let uid = target.isEmpty ? nil : target
        let label = usesVoxFlowAirDriver ? VoxFlowAirDriverSupport.sanitizedName(micName) : nil
        if saveAs {
            // A preset already has this name: offer to replace it rather than create a second one.
            let existing = e.presets.first { $0.name.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            if let existing, !confirmReplace(existing) { return }
            if let uid, uid != e.settings.virtualUID { e.selectVirtual(uid) }
            if usesVoxFlowAirDriver { e.setVirtualDeviceName(label) }
            if let existing { e.overwritePreset(existing.id) } else { e.saveAsNewPreset(name: n) }
        } else {
            e.newPreset(name: n, routing: PresetRouting(virtualUID: uid ?? e.settings.virtualUID,
                                                        virtualDeviceName: usesVoxFlowAirDriver ? (label ?? VoxFlowAirDriverSupport.micName) : nil))
        }
        dismiss()
    }
}
