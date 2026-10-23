import Foundation
import Testing
@testable import VoxFlowAirCore

@Suite("Other audio apps (calls, captures)")
struct CallAudioPolicyTests {
    let usb = "AppleUSBAudioEngine:Acme Audio:USB Interface:00000000001A:2,3"
    let mic = VoxFlowAirDriverSupport.micUID

    func proc(_ bundle: String, in ins: [String], out outs: [String], runIn: Bool = true, runOut: Bool = true) -> AudioClientProcess {
        AudioClientProcess(pid: pid_t(bundle.count), bundleID: bundle, name: CallAudioPolicy.callApps[bundle] ?? bundle,
                           inputUIDs: ins, outputUIDs: outs, runningInput: runIn, runningOutput: runOut)
    }

    @Test("FaceTime listens to VoxFlowAir Micro and plays on the monitoring headphones: monitoring must be suspended")
    func faceTimeOnMonitorDevice() {
        let ft = proc("com.apple.avconferenced", in: [mic], out: [usb])
        #expect(CallAudioPolicy.listenersOnMonitor([ft], loopbackUID: mic, monitorUID: usb) == [ft])
        // Call played on another output: nothing to suspend.
        let elsewhere = proc("com.apple.avconferenced", in: [mic], out: ["BuiltInSpeakerDevice"])
        #expect(CallAudioPolicy.listenersOnMonitor([elsewhere], loopbackUID: mic, monitorUID: usb).isEmpty)
        // OBS reads the mic without playing anything: nothing to suspend.
        let obs = proc("com.obsproject.obs-studio", in: [mic], out: [], runOut: false)
        #expect(CallAudioPolicy.listenersOnMonitor([obs], loopbackUID: mic, monitorUID: usb).isEmpty)
    }

    @Test("Call app on BlackHole is flagged, not on VoxFlowAir Micro")
    func callAppOnBlackHole() {
        let ft = proc("com.apple.avconferenced", in: ["BlackHole2ch_UID"], out: [usb])
        #expect(CallAudioPolicy.callAppsOnBlackHole([ft], loopbackUID: "BlackHole2ch_UID", loopbackName: "BlackHole 2ch") == [ft])
        let ftMic = proc("com.apple.avconferenced", in: [mic], out: [usb])
        #expect(CallAudioPolicy.callAppsOnBlackHole([ftMic], loopbackUID: mic, loopbackName: "VoxFlowAir Micro").isEmpty)
        let obs = proc("com.obsproject.obs-studio", in: ["BlackHole2ch_UID"], out: [])
        #expect(CallAudioPolicy.callAppsOnBlackHole([obs], loopbackUID: "BlackHole2ch_UID", loopbackName: "BlackHole 2ch").isEmpty)
    }

    @Test("An app recording without an input device captures other apps' audio (FineTune)")
    func interceptors() {
        let fineTune = proc("com.finetuneapp.FineTune", in: [], out: ["BuiltInHeadphoneOutputDevice"])
        let chrome = proc("com.google.Chrome.helper", in: [], out: ["BuiltInHeadphoneOutputDevice"], runIn: false)
        #expect(CallAudioPolicy.interceptors([fineTune, chrome]) == [fineTune])
        #expect(CallAudioPolicy.names([fineTune, fineTune]) == "“com.finetuneapp.FineTune”")
    }

    @Test("The Core Audio process list reads without error and does not include VoxFlowAir")
    func liveProcessList() {
        let me = ProcessInfo.processInfo.processIdentifier
        #expect(!AudioProcesses.running().contains { $0.pid == me })
    }
}
