import Testing
import Foundation
@testable import VoxFlowAirCore

/// Tests on real hardware. Disabled by default: `TEST_RUNNER_VOXFLOWAIR_HW=1 xcodebuild -project VoxFlowAir.xcodeproj -scheme VoxFlowAir test`.
/// Monitoring stays off: no sound is sent to the headphones.
@Suite("Real hardware", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXFLOWAIR_HW"] == "1"))
@MainActor
struct HardwareTests {
    @Test("Private aggregate + AUHAL: the engine runs and processes audio cycles")
    func engineRunsOnHardware() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vf-hw-\(UUID().uuidString)")
        let e = VoxFlowAirEngine(presetDirectory: tmp.appendingPathComponent("p"), settingsURL: tmp.appendingPathComponent("s.json"))
        e.settings.monitorEnabled = false
        e.launch()
        try await Task.sleep(for: .seconds(3))
        let m = e.processor.meters
        print("State:", e.state.label)
        print("Input:", e.activeInput?.name ?? "-", "| virtual:", e.activeVirtual?.name ?? "-", "| monitoring:", e.activeMonitor?.name ?? "-")
        print("Latency:", e.latency)
        let lvl = m.input.read()
        print("Cycles:", m.cycles.value, "frames/cycle:", m.lastFrames.value, "overloads:", m.deviceOverloads.value, "input errors:", m.inputErrors.value, "render:", m.renderErrors.value, "transition:", m.transitionCycles.value, "max load:", m.maxLoad.load())
        print("Input peak level:", lvl.maxPeak, "(", linearToDB(lvl.maxPeak), "dBFS)")
        #expect(e.state == .running)
        #expect(m.cycles.value > 100)
        #expect(m.inputErrors.value == 0)
        #expect(m.renderErrors.value == 0)
        e.shutdown()
        try? FileManager.default.removeItem(at: tmp)
    }
}
